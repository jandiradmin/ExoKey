import AppKit
import Carbon
import ApplicationServices

/// Decides when the current word was typed in the wrong layout and fixes it.
final class Engine {
    static let shared = Engine()

    private let layouts = LayoutManager.shared
    private let store = UserStore.shared
    private let settings = Settings.shared
    private(set) var dicts: [Lang: WordDictionary] = [:]

    var excludedApp = false
    /// Language assigned to the frontmost app: automatic corrections may only switch to it.
    var lockedLang: Lang?
    /// The last key the user pressed (letters, ⌃Space…): ExoKey's own layout choices never override it.
    var lastUserInput = Date.distantPast
    /// The layout assigned to the current app ("Layout per app"): mid-word switches away from it wait for the word end.
    var preferredLang: Lang?
    var recordingHotkey = false
    var onStateChange: (() -> Void)?

    // Tunables
    private let minAltPrefix = 20        // ppb: alternative prefix must be at least this common
    /// Switching the layout in the middle of a word is a visible action the user didn't ask for: the other
    /// language's beginning must be a common one (тысячи употреблений: "ghbd" → "прив" has ~10⁶),
    /// not merely possible ("reqe" → "куйу" had 33).
    private let minMidPrefix = 2000
    private let midRatio = 100           // alternative must beat original prefix by this factor
    private let finalRatio = 1000        // ...and an existing original word by this factor
    private let ambiguityRatio = 4       // best vs second-best alternative
    private let userWordBonus = 1_000_000

    // Current word
    private var keys: [KeyStroke] = []
    private var screenLang: Lang?
    private var disabled = false
    /// The user fought a correction (switched layout by hand, erased the fixed word, undid it):
    /// no automatic fixes until space / Return / Tab.
    var holdUntilSpace = false
    var typingWord: Bool { !keys.isEmpty }
    /// After an accepted suggestion: we know exactly what is before the caret now.
    private func afterInsert() {
        if let c = Predictor.shared.lastInsertedChar, c == " " || c == "\n" { lastBoundary = c }
    }

    /// The last word-ending character the user typed (nil = unknown: after a click, arrows, backspace, insertion).
    private var lastBoundary: Character?
    /// Text was just inserted that ends inside a word (accepted suggestion / typo fix): the next letters continue it.
    var continuesWord = false

    /// Up to `n` characters before the caret (Accessibility; nil if the app doesn't tell).
    /// The whole word before the caret, if the app's text really ends with what ExoKey saw typed (Electron apps
    /// report the caret a few characters off — then nil).
    static func wordBeforeCaret(endingWith typed: String) -> String? {
        guard !typed.isEmpty, let before = textBeforeCaret(40) else { return nil }
        let w = String(before.reversed().prefix { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }.reversed())
        guard w.count > typed.count, w.hasSuffix(typed), w.first?.isLetter == true else { return nil }
        return w
    }

    static func textBeforeCaret(_ n: Int) -> String? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.05)
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success,
              let v = f, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let e = v as! AXUIElement
        var rr: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, &rr) == .success,
              let r = rr, CFGetTypeID(r) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        AXValueGetValue(r as! AXValue, .cfRange, &range)
        guard range.length == 0, range.location > 0 else { return range.location == 0 ? "" : nil }
        let len = min(n, range.location)
        var part = CFRange(location: range.location - len, length: len)
        guard let pr = AXValueCreate(.cfRange, &part) else { return nil }
        var s: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXStringForRangeParameterizedAttribute as CFString, pr, &s) == .success
        else { return nil }
        return s as? String
    }

    static func letterBeforeCaret() -> Bool { textBeforeCaret(1)?.last?.isLetter ?? false }

    /// Inside an e-mail address or a link ("name@gmail", "https://site", "www.site"): never change the layout there.
    static func inAddress(_ before: String) -> Bool {
        let tail = before.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        return tail.contains("@") || tail.contains("://") || tail.lowercased().hasPrefix("www.")
    }
    private var erasedSinceSpace = false
    private var corrections = 0
    private var visited: Set<Lang> = []
    private var correction: Correction?

    struct Correction { let from: Lang; let to: Lang; let manual: Bool }

    // Last finished word (only when it ended with a space)
    private struct Finished { var keys: [KeyStroke]; var lang: Lang; var correction: Correction? }
    private var last: Finished?
    private var convertCycle: [Lang] = []

    private var prevWordLang: Lang?
    private var prevTyped: (word: String, lang: Lang)?
    private var keyCount = 0
    private var calcBuf = ""
    private var correctionKeys: [KeyStroke] = []

    private init() {
        loadDictionaries()
        layouts.onChange = { [weak self] external in
            guard let self = self else { return }
            Predictor.shared.hide()
            // switched by hand: the user knows which layout they want — no auto-fix until the next space
            if external, self.correction != nil || self.last?.correction != nil || self.erasedSinceSpace {
                self.holdUntilSpace = true
            }
            Log.write("layout -> \(self.layouts.currentLang?.rawValue ?? self.layouts.currentID) \(external ? "by the user/system" : "by ExoKey") midWord=\(!self.keys.isEmpty)")
            if external, !self.keys.isEmpty {
                // switched in the middle of a word (by hand, Caps Lock, a system shortcut): stop guessing this word,
                // but remember where — letters of one word in two scripts ("прите" + "ypbb") get put back (see appendLetter)
                if self.switchAt == nil, let from = self.screenLang {
                    self.switchAt = self.keys.count
                    self.switchFrom = from
                    self.disabledBeforeSwitch = self.disabled
                }
                self.disabled = true
                self.continuation = false
                self.correction = nil
            }
            self.onStateChange?()
        }
    }

    func loadDictionaries() {
        guard let res = Bundle.main.resourceURL else { return }
        for l in Lang.allCases {
            let candidates = [res.appendingPathComponent("\(l.rawValue).exd"),
                              res.appendingPathComponent("dict/\(l.rawValue).exd")]
            for u in candidates where FileManager.default.fileExists(atPath: u.path) {
                if let d = WordDictionary(url: u, lang: l) { dicts[l] = d; break }
            }
        }
        Log.write("dictionaries: \(dicts.mapValues(\.count)) layouts: \(LayoutManager.shared.all.map { "\($0.lang.rawValue)=\($0.id)" }) current=\(LayoutManager.shared.currentID)")
    }

    private var active: [KeyLayout] {
        Lang.allCases.compactMap { settings.activeLangs.contains($0) ? layouts.layouts[$0] : nil }
    }

    // MARK: - Reset

    private var pendingSentenceEnd = false
    private var sentenceStart = true
    private func code(_ k: KeyStroke) -> UInt16 { k.code }

    func reset() {
        lastBoundary = nil
        contactAt = false
        prevTyped = nil
        ContactPicker.shared.close()
        sentenceStart = true
        calcBuf = ""
        sentence = []
        resetWord()
        last = nil
        convertCycle = []
        erasedSinceSpace = false      // a click / another field / app: earlier backspaces say nothing about the next word
        continuesWord = false
    }

    /// Layout switched outside ExoKey in the middle of the current word: key index and the layout before it.
    private var switchAt: Int?
    private var switchFrom: Lang?
    private var disabledBeforeSwitch = false
    /// The word continues text ExoKey didn't see typed (layout fixes are off for it, spelling checks the whole word).
    private var continuation = false
    /// The word started right after backspaces: a short piece ("ть", "ие") is not judged as a word of its own.
    private var startedAfterErase = false
    private var shortPieceAfterErase: Bool { startedAfterErase && keys.count < 4 }

    private func resetWord() {
        switchAt = nil
        switchFrom = nil
        continuation = false
        startedAfterErase = false
        keys = []
        screenLang = nil
        disabled = false
        corrections = 0
        visited = []
        correction = nil
    }

    // MARK: - Event entry point

    enum Result { case pass, swallow }

    private static let navKeys: Set<UInt16> = [53, 115, 116, 117, 119, 121, 123, 124, 125, 126, 114, 71]
    private static let boundaryKeys: Set<UInt16> = [49, 36, 76, 48] // space, return, enter, tab

    /// "@" typed at the start of a word: the following word is a contact search (ContactPicker).
    private var contactAt = false

    func keyDown(_ event: CGEvent) -> Result {
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        if recordingHotkey { return .pass }
        let picker = ContactPicker.shared
        if picker.handleKey(code: code, flags: flags) {
            if !picker.isVisible { contactAt = false }
            return .swallow
        }
        let plain = flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        let ks = KeyStroke(code: code, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift))
        let atStart = settings.contactsEnabled && settings.enabled && !excludedApp && plain && keys.isEmpty
            && layouts.current?.char(ks) == "@"
            && !(Self.textBeforeCaret(1)?.last.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" } ?? false)
        if contactAt && code == 51 && keys.isEmpty { contactAt = false; picker.close() }   // erased the "@"
        let r = keyDownCore(event)
        if atStart {
            contactAt = true
            picker.ensureLoaded()
        } else if contactAt {
            if keys.isEmpty {
                if code != 51 { contactAt = false }
                picker.close()
            } else {
                var qs: [String] = []
                for l in active { let t = l.text(keys); if !qs.contains(t) { qs.append(t) } }
                picker.update(queries: qs, typed: keys.count)
            }
        }
        return r
    }

    private func keyDownCore(_ event: CGEvent) -> Result {
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let spellChar = layouts.current?.char(KeyStroke(code: code, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift)))
        if SpellFix.shared.keyDown(code: code, flags: flags, char: spellChar) { reset(); return .swallow }
        if !flags.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty {
            Log.write("combo code=\(code) mods=\(flags.intersection(Hotkey.relevant).rawValue) convert=\(settings.hkConvert.keyCode)/\(settings.hkConvert.mods)")
        }

        if settings.hkPause.matches(code: code, flags: flags) {
            settings.enabled.toggle()
            reset()
            Notifier.show(L.t(settings.enabled ? "notif.resumed" : "notif.paused"))
            onStateChange?()
            return .swallow
        }
        if settings.hkUndo.matches(code: code, flags: flags) {
            if settings.enabled { undo() }
            return .swallow
        }
        // ⌘Z right after an automatic fix undoes the fix (what people press first)
        if code == 6, flags.intersection(Hotkey.relevant) == .maskCommand, settings.enabled, canUndoAutoFix {
            undo()
            return .swallow
        }
        if settings.hkCase.matches(code: code, flags: flags) {
            if settings.enabled { Selection.changeCase() }
            return .swallow
        }
        // Autocomplete keys (TZ §13.3)
        let pred = Predictor.shared
        if code == 48, UserDefaults.standard.bool(forKey: "aiDebug") {
            Log.write("tab: ghost=\(pred.isVisible) mods=\(flags.intersection(Hotkey.relevant).rawValue) acceptWord=\(settings.hkAcceptWord.keyCode)/\(settings.hkAcceptWord.mods) spellOffer=\(SpellFix.shared.isOffering)")
        }
        if settings.hkToggleAI.matches(code: code, flags: flags) {
            settings.aiEnabled.toggle()
            if settings.aiEnabled { AIModel.shared.start() } else { AIModel.shared.stop(); pred.hide() }
            Notifier.show(L.t(settings.aiEnabled ? "notif.aiOn" : "notif.aiOff"))
            return .swallow
        }
        if settings.hkUndoInsert.matches(code: code, flags: flags) {
            pred.undoInsert()
            reset()
            return .swallow
        }
        if pred.isVisible {
            if settings.hkAcceptAll.matches(code: code, flags: flags) { pred.accept(all: true); reset(); afterInsert(); return .swallow }
            if settings.hkAcceptWord.matches(code: code, flags: flags) { pred.accept(all: false); reset(); afterInsert(); return .swallow }
            if settings.hkHide.matches(code: code, flags: flags) { pred.dismiss(); return .swallow }
        }
        if settings.hkSpell.matches(code: code, flags: flags) {
            if settings.enabled, !excludedApp { spellHotkey() }
            return .swallow
        }
        if settings.hkConvert.matches(code: code, flags: flags) {
            if settings.enabled, !excludedApp { convert() }
            return .swallow
        }

        keyCount += 1
        lastUserInput = Date()
        if keyCount <= 3 || keyCount % 200 == 0 {
            Log.write("key #\(keyCount) enabled=\(settings.enabled) excluded=\(excludedApp) secure=\(IsSecureEventInputEnabled()) layout=\(layouts.currentID) lang=\(layouts.currentLang?.rawValue ?? "nil")")
        }
        guard settings.enabled, !excludedApp, !IsSecureEventInputEnabled() else { reset(); return .pass }
        // the system's layout switch shortcut (⌃Space…) doesn't edit text: keep the word — the switch itself is
        // handled when macOS reports it (in the middle of a word: no more guessing for it)
        if layouts.isSwitchShortcut(code: Int64(code), flags: flags) { return .pass }
        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            // ⌥⌫ / ⌘⌫ right after a fix: the user erased our word — don't fix the retyped word again until a space
            if code == 51, (correction.map { !$0.manual } ?? false) || (keys.isEmpty && (last?.correction.map { !$0.manual } ?? false)) {
                holdUntilSpace = true
                Log.write("word erased after a fix: hold until space")
            }
            reset(); return .pass
        }
        if code == 51 { backspace(); return .pass }
        if Self.navKeys.contains(code) || code >= 96 && code <= 122 && KeyNames.special[code] != nil {
            reset(); return .pass
        }
        guard let cur = layouts.current, settings.activeLangs.contains(cur.lang) else { reset(); return .pass }

        let ks = KeyStroke(code: code, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift))

        // Inline calculator
        if settings.calculator, let ch = cur.char(ks), ch.count == 1, let c = ch.first {
            if c == "=" {
                // "=" goes to the app as usual; the result is added once the app has shown everything typed
                // (at this point the last keys may still be on their way to the app)
                scheduleCalc(typed: calcBuf, attempt: 0)
                calcBuf = ""
            } else if Calculator.allowed.contains(c) {
                calcBuf.append(c)
                if calcBuf.count > 80 { calcBuf.removeFirst(calcBuf.count - 80) }
            } else {
                calcBuf = ""
            }
        }

        if Self.boundaryKeys.contains(code) {
            return boundary(event: event, ks: ks, cur: cur, kind: code == 49 ? .space : .control)
        }

        if keys.isEmpty {
            // first key of a word: skip password-like fields (checked once per field)
            if FieldGuard.focusedIsSensitive() { return .pass }
            screenLang = cur.lang; visited = [cur.lang]
            // Continuing a word ExoKey didn't see from the start ("калькулятор" + "ом" after a suggestion, after
            // backspace or a click): the piece alone looks like a word in another layout ("jv") — leave it as typed.
            // The previous key typed a space / Return: a fresh word for sure — don't ask the app (Electron apps report
            // the caret a few characters off, and a "letter before the caret" there disabled fixing real words).
            // After "@", ".", "/", ":" — maybe an address; after a click, arrows, backspace or an inserted suggestion —
            // maybe the middle of a word: then look at the text before the caret.
            let fresh = lastBoundary.map { $0 == " " || $0 == "\n" || $0 == "\t" } ?? false
            // backspace erased the word (and maybe more) — the next letters are often the rest of a word still on screen
            startedAfterErase = lastBoundary == nil && erasedSinceSpace
            if continuesWord {
                disabled = true
                continuation = true
            } else if !fresh {
                let before = Self.textBeforeCaret(60)
                let addressish = lastBoundary.map { "@./:".contains($0) } ?? true
                // trust the app's caret only if the text before it ends with what was just typed
                // (Electron apps like Claude report the caret a few characters off — then: unknown, fix as usual)
                let probe = String(Predictor.shared.recentTypedTail.suffix(3))
                let verified = probe.count >= 2 && (before?.hasSuffix(probe) ?? false)
                // erased back to a space / the start of the field: a really new word, not the rest of an old one
                if startedAfterErase, let b = before, b.last.map({ $0.isWhitespace }) ?? true { startedAfterErase = false }
                if (lastBoundary == nil && verified && (before?.last?.isLetter ?? false))
                    || (addressish && before.map(Self.inAddress) == true) {
                    disabled = true
                    continuation = !(addressish && before.map(Self.inAddress) == true)
                    Log.write("word continues existing text or an address: no layout fix" + Log.words(String((before ?? "").suffix(20))))
                }
            }
            continuesWord = false
        }
        let screen = screenLang ?? cur.lang

        // Is this key part of a word?
        if cur.isWordChar(ks) {
            if keys.isEmpty, !cur.isLetter(ks) {
                // leading ' in English is "э"/"є" in Cyrillic layouts — keep it as a possible letter
                if active.contains(where: { $0.lang != cur.lang && $0.isLetter(ks) }) { return appendLetter(ks) }
                return .pass
            }
            return appendLetter(ks)
        }
        let letterElsewhere = active.contains { $0.lang != cur.lang && $0.isLetter(ks) }
        if letterElsewhere {
            // Punctuation here, a letter in another layout (";" = "ж", "," = "б", "[" = "х"...).
            // Compare: "the word is finished" vs "the word continues in the other language".
            if !keys.isEmpty {
                let finished = wordScore(core(keys, screen), screen)
                var continued = 0
                for l in active where l.lang != screen {
                    if let t = candidate(keys + [ks], l) { continued = max(continued, prefixScore(t, l.lang)) }
                }
                if finished > 0 && continued < finished * 10 {
                    return boundary(event: event, ks: ks, cur: cur, kind: .symbol)
                }
                if finished == 0 && continued == 0 {
                    return boundary(event: event, ks: ks, cur: cur, kind: .symbol)
                }
            }
            return appendLetter(ks)
        }
        // digits and symbols that are letters nowhere
        if let ch = cur.char(ks), ch.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
            // words with digits are never corrected
            if keys.isEmpty { screenLang = cur.lang }
            disabled = true
            keys.append(ks)
            return .pass
        }
        return boundary(event: event, ks: ks, cur: cur, kind: .symbol)
    }

    /// Inline calculator: reads the line before the caret (it ends with "="), evaluates what precedes it.
    /// Without Accessibility falls back to the typed keys.
    private func scheduleCalc(typed: String, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self = self else { return }
            var result: String?
            var lineText: String?
            if let line = Calculator.lineBeforeCaret() {
                guard line.hasSuffix("=") else {
                    if attempt < 4 { self.scheduleCalc(typed: typed, attempt: attempt + 1) }   // app not caught up yet
                    return
                }
                lineText = String(line.dropLast())
                result = Calculator.evaluate(Calculator.tail(lineText!))
            } else {
                result = Calculator.evaluate(typed)
            }
            if let r = result {
                Injector.type(r)
                self.calcBuf = r                         // chains: 600*2=1200+200=
                Log.write("calc")
                return
            }
            // units and currencies: "1 pound in kg =", "25 usd/uah ="
            guard let lt = lineText else { return }
            Converter.evaluate(lt) { conv in
                guard let c = conv, Calculator.lineBeforeCaret()?.hasSuffix("=") == true else { return }
                Injector.type((lt.hasSuffix(" ") ? " " : "") + c)   // "kg = 0.45 kg" / "kg=0.45 kg"
                Log.write("calc: conversion")
            }
        }
    }

    private func appendLetter(_ ks: KeyStroke) -> Result {
        keys.append(ks)
        convertCycle = []
        if keys.count > 40 { disabled = true }
        if restoreMixedScript() { return .swallow }
        // After backspaces into existing text the letters are usually the rest of a word still on screen: what ExoKey
        // remembers typing no longer matches the screen (its own fixes, Electron/WeChat carets), so the piece can't be
        // judged while typing ("прив" + "ет" flipped to EN). The finished word is still checked at the space.
        guard !disabled, !holdUntilSpace, corrections < 2, keys.count >= settings.minLetters, !startedAfterErase else { return .pass }
        if let d = decideMidWord() {
            let was = screenLang.flatMap { layouts.layouts[$0]?.text(keys) } ?? ""
            apply(to: d, typedSoFarExcludingLast: true, manual: false)
            Log.write("mid fix len=\(keys.count) -> \(d.rawValue)" + Log.words("\(was) → \(layouts.layouts[d]?.text(keys) ?? "")"))
            return .swallow
        }
        return .pass
    }

    private func backspace() {
        erasedSinceSpace = true
        if keys.isEmpty { lastBoundary = nil }
        if !calcBuf.isEmpty { calcBuf.removeLast() }
        if keys.isEmpty {
            if last?.correction.map({ !$0.manual }) == true { holdUntilSpace = true }   // erasing a fixed word
            last = nil
        } else {
            if correction.map({ !$0.manual }) == true { holdUntilSpace = true }
            if keys.count == 1, settings.implicitUndo, let c = correction, !c.manual,
               let fromL = layouts.layouts[c.from], !correctionKeys.isEmpty {
                // user erased the word we corrected — treat as undo
                recordUndo(c, original: TextNorm.normalize(fromL.text(correctionKeys), c.from))
                Log.write("implicit undo" + Log.words(fromL.text(correctionKeys)))
            }
            keys.removeLast()
            if let a = switchAt, keys.count <= a { switchAt = nil; switchFrom = nil }   // the switched part is erased
            if keys.isEmpty { resetWord() }
        }
        convertCycle = []
    }

    // MARK: - Word end

    private enum BoundaryKind { case space, control, symbol }

    private func boundary(event: CGEvent, ks: KeyStroke, cur: KeyLayout, kind: BoundaryKind) -> Result {
        switch kind {
        case .space: lastBoundary = " "
        case .control: lastBoundary = code(ks) == 48 ? "\t" : "\n"
        case .symbol: lastBoundary = cur.char(ks)?.first
        }
        defer {
            convertCycle = []
            if kind != .symbol { holdUntilSpace = false; erasedSinceSpace = false; continuesWord = false }
        }
        guard !keys.isEmpty, let screen = screenLang else {
            resetWord(); last = nil
            return .pass
        }
        var result = Result.pass
        if let ch = cur.char(ks), ".!?\r\n".contains(ch) || code(ks) == 36 { pendingSentenceEnd = true }
        // debug: a word that looks like the wrong layout but was left as typed — and why ("lkz" stayed for "для")
        if disabled || holdUntilSpace || shortPieceAfterErase, !keys.isEmpty, let would = decideFinal() {
            Log.write("final skip len=\(keys.count) \(screenLang?.rawValue ?? "-")->\(would.rawValue)" + Log.words(screenLang.flatMap { layouts.layouts[$0]?.text(keys) } ?? "") + " disabled=\(disabled) continuation=\(continuation) hold=\(holdUntilSpace) afterErase=\(startedAfterErase) corrections=\(corrections) app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
        }
        if !disabled, !holdUntilSpace, !shortPieceAfterErase, let target = decideFinal() {
            let boundaryChar = cur.char(ks) ?? ""
            let was = screenLang.flatMap { layouts.layouts[$0]?.text(keys) } ?? ""
            apply(to: target, typedSoFarExcludingLast: false, manual: false, capitalize: shouldCapitalize(target))
            Log.write("final fix len=\(keys.count) -> \(target.rawValue)" + Log.words("\(was) → \(layouts.layouts[target]?.text(keys) ?? "")"))
            switch kind {
            case .space, .control: Injector.repost(event)
            case .symbol: Injector.type(boundaryChar)
            }
            result = .swallow
        } else if shouldCapitalize(screen), let l = layouts.layouts[screen] {
            let t = l.text(keys)
            Injector.backspaces(t.count)
            Injector.type(NameCase.capitalize(t))
            switch kind {
            case .space, .control: Injector.repost(event)
            case .symbol: Injector.type(cur.char(ks) ?? "")
            }
            result = .swallow
        } else {
            learnUnknown(screen)
            if kind != .control, !disabled, let l = layouts.layouts[screen], !untouchableCase(keys, final: true) {
                SpellFix.shared.wordFinished(l.text(keys), lang: screen, boundary: cur.char(ks) ?? "")
            } else if kind != .control, continuation, let l = layouts.layouts[screen], !untouchableCase(keys, final: true),
                      let w = Self.wordBeforeCaret(endingWith: l.text(keys)) {
                // the word continues text typed earlier (after a suggestion, backspace, a click): check the whole word
                SpellFix.shared.wordFinished(w, lang: screen, boundary: cur.char(ks) ?? "")
            }
        }
        finishWord(endedWithSpace: kind == .space)
        sentenceStart = pendingSentenceEnd
        if pendingSentenceEnd { sentence = []; pendingSentenceEnd = false; prevTyped = nil }
        return result
    }

    // Recent words of the current sentence, for learning frequent phrases (TZ §13.5). Not persisted.
    private var sentence: [String] = []
    private var sentenceLang: Lang?

    private func learnPhrase(word: String, lang: Lang, sentenceEnd: Bool) {
        guard settings.learnPhrases, settings.aiPersonalization else { sentence = []; return }
        if sentenceLang != lang { sentence = []; sentenceLang = lang }
        if !word.isEmpty { sentence.append(word) }
        if sentence.count > 4 { sentence.removeFirst() }
        for n in [3, 4] where sentence.count >= n {
            let phrase = sentence.suffix(n).joined(separator: " ")
            let c = store.bump("p:\(lang.rawValue):\(phrase)")
            if c == 3, store.find(.phrase, lang, phrase) == nil {
                store.upsert(UserEntry(word: phrase, lang: lang, kind: .phrase, uses: c, source: .learned))
            }
        }
        if sentenceEnd { sentence = [] }
    }

    /// The word typed so far is not valid in the current layout and not decided yet — don't suggest.
    var wordUncertain: Bool {
        guard !keys.isEmpty, !disabled, let o = screenLang else { return false }
        let t = core(keys, o)
        return !t.isEmpty && prefixScore(t, o) == 0
    }

    /// Should this all-lowercase word be written as a name ("марина" → "Марина")?
    private func shouldCapitalize(_ lang: Lang) -> Bool {
        guard settings.fixNameCase, !disabled, keys.count >= 2, let l = layouts.layouts[lang] else { return false }
        if keys.contains(where: { $0.shift != $0.caps }) { return false }
        let w = core(keys, lang)
        guard w.count == l.text(keys).count else { return false }   // letters only
        return NameCase.shared.isName(w, lang)
    }

    private func finishWord(endedWithSpace: Bool) {
        // learn how the user writes names (only mid-sentence, where a capital letter means a name)
        if settings.learning, !sentenceStart, let lang = screenLang, keys.count >= 3, !disabled || correction != nil,
           let l = layouts.layouts[lang] {
            let w = core(keys, lang)
            let ups = keys.map { $0.shift != $0.caps }
            if w.count == l.text(keys).count {
                if ups.first == true && !ups.dropFirst().contains(true) { NameCase.shared.learn(lower: w, capitalized: true, lang) }
                else if !ups.contains(true) { NameCase.shared.learn(lower: w, capitalized: false, lang) }
            }
        }
        if let lang = screenLang, !disabled || correction != nil {
            learnPhrase(word: core(keys, lang), lang: lang, sentenceEnd: false)
            // the user's own vocabulary (word counts only) — completes their words first ("земсн" → "земснаряд")
            let w = core(keys, lang)
            if settings.learning, w.count >= 3, w.count <= 32, w.allSatisfy({ TextNorm.isLetter($0, lang) || $0 == "-" || $0 == "'" }) {
                _ = store.bump("uw:\(lang.rawValue):\(w)")
                // word pairs within a sentence: after "external" this user writes "power"
                if let p = prevTyped, p.lang == lang, !sentenceStart || p.word != w { _ = store.bump("ub:\(lang.rawValue):\(p.word) \(w)") }
                prevTyped = (w, lang)
            } else {
                prevTyped = nil
            }
        }
        if let lang = screenLang {
            if let c = correction, !c.manual, let fromL = layouts.layouts[c.from] {
                // correction was not undone — weak positive signal
                let orig = TextNorm.normalize(fromL.text(keys), c.from)
                if settings.learning { _ = store.touch(.rule, c.from, orig, uses: 1, targetLang: c.to) }
            }
            prevWordLang = lang
            last = endedWithSpace ? Finished(keys: keys, lang: lang, correction: correction) : nil
        }
        resetWord()
    }

    // MARK: - Decisions

    /// Normalized text of keys in a layout, nil if it contains non-word characters.
    private func candidate(_ keys: [KeyStroke], _ l: KeyLayout) -> String? {
        let t = l.text(keys)
        guard let f = t.first, let e = t.last else { return nil }
        for c in t where !(TextNorm.isLetter(c, l.lang) || TextNorm.isInner(c, l.lang)) { return nil }
        if !TextNorm.isLetter(f, l.lang) || !TextNorm.isLetter(e, l.lang) && keys.count > 1 && !TextNorm.isInner(e, l.lang) {
            return nil
        }
        return TextNorm.normalize(t, l.lang)
    }

    /// Text of keys in a layout, normalized, with non-letter characters trimmed at the edges.
    private func core(_ keys: [KeyStroke], _ lang: Lang) -> String {
        guard let l = layouts.layouts[lang] else { return "" }
        let t = TextNorm.normalize(l.text(keys), lang)
        let chars = Array(t)
        var a = 0, b = chars.count
        while a < b, !TextNorm.isLetter(chars[a], lang) { a += 1 }
        while b > a, !TextNorm.isLetter(chars[b - 1], lang) { b -= 1 }
        return String(chars[a..<b])
    }

    private func prefixScore(_ s: String, _ l: Lang) -> Int {
        guard !s.isEmpty else { return 0 }
        return (dicts[l]?.prefixFreq(s) ?? 0) + (store.hasPrefix(s, l) ? userWordBonus : 0)
    }

    private func wordScore(_ s: String, _ l: Lang) -> Int {
        guard !s.isEmpty else { return 0 }
        return (dicts[l]?.freq(s) ?? 0) + (store.isWord(s, l) ? userWordBonus : 0)
    }

    /// Case pattern we never touch: CamelCase like "iPhone", short all-caps abbreviations.
    private func untouchableCase(_ keys: [KeyStroke], final: Bool) -> Bool {
        let ups = keys.map { $0.shift != $0.caps }
        if settings.skipAllCaps, keys.count >= 2, ups.allSatisfy({ $0 }) { return true }
        if ups.dropFirst().contains(true) {
            if ups.allSatisfy({ $0 }) { return final && keys.count <= 4 }
            return true
        }
        return false
    }

    private struct Alt { let lang: Lang; let text: String; let score: Int }

    private func alternatives(_ keys: [KeyStroke], excluding o: Lang, score: (String, Lang) -> Int, minScore: Int,
                              manual: Bool = false) -> [Alt] {
        var out: [Alt] = []
        for l in active where l.lang != o && !visited.contains(l.lang) {
            if !manual, let lock = lockedLang, l.lang != lock { continue }
            guard let t = candidate(keys, l) else { continue }
            let s = score(t, l.lang)
            if s >= minScore { out.append(Alt(lang: l.lang, text: t, score: s)) }
        }
        return out.sorted { $0.score > $1.score }
    }

    /// Picks between alternatives; nil if ambiguous.
    private func pick(_ alts: [Alt]) -> Lang? {
        guard let best = alts.first else { return nil }
        guard alts.count > 1 else { return best.lang }
        let second = alts[1]
        if second.text == best.text {
            // same text in Russian and Ukrainian — choose the layout by context
            let pair = Set([best.lang, second.lang])
            if let p = prevWordLang, pair.contains(p) { return p }
            if let cur = screenLang, pair.contains(cur) { return cur }
            return best.lang
        }
        return best.score >= second.score * ambiguityRatio ? best.lang : nil
    }

    /// Only punctuation on screen ("..", ",,,", "...."): an ellipsis or a separator, not a word in another layout
    /// ("..." is "ююю" in the Russian layout — never convert while typing; at the end only into a common word).
    private func onlyPunctuation(_ o: Lang) -> Bool {
        guard let l = layouts.layouts[o] else { return false }
        return !l.text(keys).contains { $0.isLetter }
    }

    private func decideMidWord() -> Lang? {
        guard let o = screenLang, !untouchableCase(keys, final: false), !onlyPunctuation(o) else { return nil }
        // A capital first letter is usually a name or a place ("Uk|raine" looked like "Гл|авный" after two letters):
        // decide only from the third letter on
        if let f = keys.first, f.shift != f.caps, keys.count < 3 { return nil }
        let oText = core(keys, o)
        guard keys.count >= settings.minLetters, !store.isException(oText, o) else { return nil }
        let pO = prefixScore(oText, o)
        // The user is writing in this language (the previous word is in it, or the app is assigned to it):
        // a few letters are no evidence against it — even an impossible beginning is usually a typo
        // ("new" typed "nre", "reque…" typed "reqe" became "тку", "куйу"). Decide at the end of the word.
        if let p = prevWordLang, p == o { return nil }
        if preferredLang == o { return nil }
        let alts = alternatives(keys, excluding: o, score: prefixScore, minScore: minMidPrefix)
        guard let best = alts.first else { return nil }
        if pO > 0 && best.score < pO * midRatio { return nil }
        return pick(alts)
    }

    private func decideFinal() -> Lang? {
        guard let o = screenLang, !untouchableCase(keys, final: true) else { return nil }
        let oText = core(keys, o)
        guard !oText.isEmpty, !store.isException(oText, o) else { return nil }
        // explicit user rule
        if let r = store.find(.rule, o, oText), r.source == .manual, let tl = r.targetLang, !visited.contains(tl) || tl == o {
            if tl != o && (lockedLang == nil || lockedLang == tl) { return tl }
        }
        let fO = wordScore(oText, o)
        let pO = prefixScore(oText, o)
        let minScore = (fO == 0 && pO == 0) ? 1 : 50
        let alts = alternatives(keys, excluding: o, score: wordScore, minScore: minScore)
        guard let best = alts.first else { return nil }
        if fO > 0 && best.score < fO * finalRatio { return nil }
        if onlyPunctuation(o) {
            // ",tp" → "без" is fine (letters follow), but "..." / ",," stay: same key repeated, or a rare word
            if Set(keys.map(\.code)).count == 1 || best.score < 1000 { return nil }
        }
        if keys.count < settings.minLetters {
            // short words ("yf" → "на"): the alternative must be a very common word and the original junk,
            // or the previous word must be in the same script
            let strong = best.score >= 2000 && best.score >= max(fO, pO / 10) * 1000
            let ctx = prevWordLang.map { $0 == best.lang || $0.isCyrillic == best.lang.isCyrillic } ?? false
            guard keys.count >= 2, strong || (ctx && fO == 0 && best.score >= 500) else { return nil }
        }
        return pick(alts)
    }

    /// One word typed in two scripts because the layout changed in the middle of it ("прите" + "ypbb" after
    /// Caps Lock / a system shortcut): nobody means that — type the rest in the word's layout and switch back.
    /// The last key has not reached the app yet (the caller swallows it), so it is typed here too.
    private func restoreMixedScript() -> Bool {
        guard let at = switchAt, let from = switchFrom, !holdUntilSpace, keys.count - at >= 2,
              let cur = layouts.current, cur.lang.isCyrillic != from.isCyrillic, let fromL = layouts.layouts[from] else { return false }
        let head = Array(keys[..<at]), tail = Array(keys[at...])
        let headText = fromL.text(head), tailCur = cur.text(tail)
        guard headText.count >= 2, headText.allSatisfy({ TextNorm.isLetter($0, from) }),
              tailCur.allSatisfy({ TextNorm.isLetter($0, cur.lang) }) else { return false }
        layouts.select(from)
        Injector.backspaces(tailCur.count - 1)           // the last letter was not delivered yet
        Injector.type(fromL.text(tail))
        screenLang = from
        switchAt = nil
        switchFrom = nil
        disabled = disabledBeforeSwitch
        correction = Correction(from: cur.lang, to: from, manual: false)
        correctionKeys = keys
        Log.write("mixed scripts in one word: rest retyped in \(from.rawValue) len=\(tail.count)" + Log.words("\(headText)+\(tailCur) → \(fromL.text(keys))"))
        onStateChange?()
        return true
    }

    // MARK: - Applying

    private func apply(to target: Lang, typedSoFarExcludingLast: Bool, manual: Bool, capitalize: Bool = false) {
        guard let from = screenLang, let fromL = layouts.layouts[from], let toL = layouts.layouts[target] else { return }
        let onScreen = typedSoFarExcludingLast ? Array(keys.dropLast()) : keys
        let eraseCount = fromL.text(onScreen).count
        layouts.select(target)
        Injector.backspaces(eraseCount)
        let t = toL.text(keys)
        Injector.type(capitalize ? NameCase.capitalize(t) : t)
        correctionKeys = keys
        if !manual { Stats.add(.layoutFixed) }
        let originalFrom = correction?.from ?? from
        correction = Correction(from: originalFrom, to: target, manual: manual)
        screenLang = target
        visited.insert(target)
        corrections += 1
        onStateChange?()
    }

    // MARK: - Undo

    private var canUndoAutoFix: Bool {
        if !keys.isEmpty { return correction.map { !$0.manual } ?? false }
        return last?.correction.map { !$0.manual } ?? false
    }

    func undo() {
        if SpellFix.shared.undoLast() { reset(); return }
        if !keys.isEmpty, let c = correction, let cur = screenLang,
           let curL = layouts.layouts[cur], let fromL = layouts.layouts[c.from] {
            layouts.select(c.from)
            Injector.backspaces(curL.text(keys).count)
            Injector.type(fromL.text(keys))
            screenLang = c.from
            disabled = true
            holdUntilSpace = true
            correction = nil
            recordUndo(c, original: TextNorm.normalize(fromL.text(keys), c.from))
            return
        }
        if keys.isEmpty, let l = last, let c = l.correction,
           let curL = layouts.layouts[l.lang], let fromL = layouts.layouts[c.from] {
            layouts.select(c.from)
            Injector.backspaces(curL.text(l.keys).count + 1)
            Injector.type(fromL.text(l.keys) + " ")
            prevWordLang = c.from
            last = Finished(keys: l.keys, lang: c.from, correction: nil)
            recordUndo(c, original: TextNorm.normalize(fromL.text(l.keys), c.from))
            return
        }
        Notifier.show(L.t("notif.undoUnavailable"))
    }

    private func recordUndo(_ c: Correction, original: String) {
        if !c.manual { Stats.add(.layoutUndone) }
        guard settings.learning, !c.manual, !original.isEmpty else { return }
        let e = store.touch(.rule, c.from, original, undos: 1, targetLang: c.to)
        if e.undos >= settings.undosToException {
            if let r = store.find(.rule, c.from, original) { store.delete(r) }
            _ = store.touch(.exception, c.from, original)
            Notifier.show(L.t("notif.exception", original))
        }
    }

    // MARK: - Typo fix by hotkey

    private func spellHotkey() {
        if !keys.isEmpty, let lang = screenLang, let l = layouts.layouts[lang] {
            SpellFix.shared.fixNow(l.text(keys), lang: lang, boundary: "")
            reset()
        } else if let lst = last, let l = layouts.layouts[lst.lang] {
            SpellFix.shared.fixNow(l.text(lst.keys), lang: lst.lang, boundary: " ")
            last = nil
        }
    }

    // MARK: - Manual conversion

    func spellFix() { if settings.enabled, !excludedApp { spellHotkey() } }

    func convert() {
        Selection.read { [weak self] sel in
            guard let self = self else { return }
            // some apps (Electron) report a "selection" that is only whitespace or stale: real selected text has letters
            Log.write("convert: selection=\(sel.map { "\($0.count) chars" } ?? "n/a")")
            if let s = sel, s.contains(where: { $0.isLetter }), Selection.convertLayout(s) {
                self.reset()
            } else {
                self.convertWord()
            }
        }
    }

    private func convertWord() {
        Log.write("convert: word=\(keys.count) last=\(last?.keys.count ?? -1)")
        if !keys.isEmpty, let from = screenLang {
            guard let target = chooseTarget(keys, from: from) else { return }
            disabled = true
            visited = []
            apply(to: target, typedSoFarExcludingLast: false, manual: true)
            learnManual(keys, from: correction?.from ?? from, to: target)
            return
        }
        if let l = last, let curL = layouts.layouts[l.lang] {
            guard let target = chooseTarget(l.keys, from: l.lang), let toL = layouts.layouts[target] else {
                Log.write("convert: no target"); return
            }
            layouts.select(target)
            Injector.backspaces(curL.text(l.keys).count + 1)
            Injector.type(toL.text(l.keys) + " ")
            let orig = l.correction?.from ?? l.lang
            last = Finished(keys: l.keys, lang: target, correction: Correction(from: orig, to: target, manual: true))
            prevWordLang = target
            learnManual(l.keys, from: orig, to: target)
            onStateChange?()
        }
    }

    private func chooseTarget(_ keys: [KeyStroke], from: Lang) -> Lang? {
        let langs = active.map(\.lang)
        guard langs.count > 1 else { return nil }
        if convertCycle.isEmpty {
            let saved = visited
            visited = []
            var alts = alternatives(keys, excluding: from, score: wordScore, minScore: 1, manual: true)
            if alts.isEmpty { alts = alternatives(keys, excluding: from, score: prefixScore, minScore: 1, manual: true) }
            visited = saved
            var order = alts.map(\.lang)
            for l in langs where l != from && !order.contains(l) { order.append(l) }
            order.append(from)
            convertCycle = order
        }
        let t = convertCycle.removeFirst()
        convertCycle.append(t)
        return t == from && convertCycle.count > 1 ? convertCycle.first : t
    }

    private func learnManual(_ keys: [KeyStroke], from: Lang, to: Lang) {
        guard settings.learning, from != to, let fromL = layouts.layouts[from], let toL = layouts.layouts[to] else { return }
        let orig = TextNorm.normalize(fromL.text(keys), from)
        let word = TextNorm.normalize(toL.text(keys), to)
        if let ex = store.find(.exception, from, orig) { store.delete(ex) }
        _ = store.touch(.rule, from, orig, uses: 1, target: word, targetLang: to)
        if wordScore(word, to) == 0, isLearnable(word, to) {
            _ = store.touch(.word, to, word, uses: 1)
        }
    }

    // MARK: - Learning new words

    private func isLearnable(_ w: String, _ l: Lang) -> Bool {
        guard w.count >= 2, w.count <= 32 else { return false }
        return w.allSatisfy { TextNorm.isLetter($0, l) || TextNorm.isInner($0, l) }
    }

    private func learnUnknown(_ lang: Lang) {
        // an unknown word produced by OUR automatic fix ("Ukraine" → "Глкфшту") is not the user's word — never learn it
        guard settings.learning, correction.map({ $0.manual }) ?? !disabled, let l = layouts.layouts[lang] else { return }
        guard let w = candidate(keys, l), isLearnable(w, lang), wordScore(w, lang) == 0 else { return }
        if store.isException(w, lang) { return }
        // Names, places (Capitalized) and abbreviations (ALL CAPS) are learned faster
        let ups = keys.map { $0.shift != $0.caps }
        let isName = ups.first == true && !ups.dropFirst().contains(true)
        let isAbbr = ups.count >= 2 && ups.count <= 6 && ups.allSatisfy { $0 }
        let threshold = settings.learnNames && (isName || isAbbr) ? min(2, settings.repeatCount) : settings.repeatCount
        switch settings.addMode {
        case .immediate:
            _ = store.touch(.word, lang, w, uses: 1)
        case .confirm:
            _ = store.touch(.candidate, lang, w, uses: 1)
        case .repeated:
            let e = store.touch(.candidate, lang, w, uses: 1)
            if e.uses >= threshold {
                if let c = store.find(.candidate, lang, w) { store.delete(c) }
                _ = store.touch(.word, lang, w, uses: e.uses)
                Notifier.show(L.t("notif.learned", w))
            }
        }
    }

    // MARK: - Status

    var statusLang: Lang? { layouts.currentLang }
    var sleeping: Bool {
        guard let l = layouts.currentLang else { return true }
        return !settings.activeLangs.contains(l)
    }
}
