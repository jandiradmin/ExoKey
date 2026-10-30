import AppKit
import Carbon

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
    var recordingHotkey = false
    var onStateChange: (() -> Void)?

    // Tunables
    private let minAltPrefix = 20        // ppb: alternative prefix must be at least this common
    private let midRatio = 100           // alternative must beat original prefix by this factor
    private let finalRatio = 1000        // ...and an existing original word by this factor
    private let ambiguityRatio = 4       // best vs second-best alternative
    private let userWordBonus = 1_000_000

    // Current word
    private var keys: [KeyStroke] = []
    private var screenLang: Lang?
    private var disabled = false
    private var corrections = 0
    private var visited: Set<Lang> = []
    private var correction: Correction?

    struct Correction { let from: Lang; let to: Lang; let manual: Bool }

    // Last finished word (only when it ended with a space)
    private struct Finished { var keys: [KeyStroke]; var lang: Lang; var correction: Correction? }
    private var last: Finished?
    private var convertCycle: [Lang] = []

    private var prevWordLang: Lang?
    private var keyCount = 0
    private var calcBuf = ""
    private var correctionKeys: [KeyStroke] = []

    private init() {
        loadDictionaries()
        layouts.onChange = { [weak self] external in
            guard let self = self else { return }
            Predictor.shared.hide()
            if external, !self.keys.isEmpty {
                // user switched layout by hand in the middle of a word — leave it alone
                self.disabled = true
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
        sentenceStart = true
        calcBuf = ""
        sentence = []
        resetWord()
        last = nil
        convertCycle = []
    }

    private func resetWord() {
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

    func keyDown(_ event: CGEvent) -> Result {
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        if recordingHotkey { return .pass }
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
        // Autocomplete keys (TZ §13.3)
        let pred = Predictor.shared
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
            if settings.hkAcceptAll.matches(code: code, flags: flags) { pred.accept(all: true); reset(); return .swallow }
            if settings.hkAcceptWord.matches(code: code, flags: flags) { pred.accept(all: false); reset(); return .swallow }
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
        if keyCount <= 3 || keyCount % 200 == 0 {
            Log.write("key #\(keyCount) enabled=\(settings.enabled) excluded=\(excludedApp) secure=\(IsSecureEventInputEnabled()) layout=\(layouts.currentID) lang=\(layouts.currentLang?.rawValue ?? "nil")")
        }
        guard settings.enabled, !excludedApp, !IsSecureEventInputEnabled() else { reset(); return .pass }
        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty { reset(); return .pass }
        if code == 51 { backspace(); return .pass }
        if Self.navKeys.contains(code) || code >= 96 && code <= 122 && KeyNames.special[code] != nil {
            reset(); return .pass
        }
        guard let cur = layouts.current, settings.activeLangs.contains(cur.lang) else { reset(); return .pass }

        let ks = KeyStroke(code: code, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift))

        // Inline calculator
        if settings.calculator, let ch = cur.char(ks), ch.count == 1, let c = ch.first {
            if c == "=" {
                if let r = Calculator.evaluate(calcBuf) {
                    calcBuf = ""
                    resetWord(); last = nil
                    Injector.type("=" + r)
                    Log.write("calc")
                    return .swallow
                }
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

    private func appendLetter(_ ks: KeyStroke) -> Result {
        keys.append(ks)
        convertCycle = []
        if keys.count > 40 { disabled = true }
        guard !disabled, corrections < 2, keys.count >= settings.minLetters else { return .pass }
        if let d = decideMidWord() {
            apply(to: d, typedSoFarExcludingLast: true, manual: false)
            Log.write("mid fix len=\(keys.count) -> \(d.rawValue)")
            return .swallow
        }
        return .pass
    }

    private func backspace() {
        if !calcBuf.isEmpty { calcBuf.removeLast() }
        if keys.isEmpty {
            last = nil
        } else {
            if keys.count == 1, settings.implicitUndo, let c = correction, !c.manual,
               let fromL = layouts.layouts[c.from], !correctionKeys.isEmpty {
                // user erased the word we corrected — treat as undo
                recordUndo(c, original: TextNorm.normalize(fromL.text(correctionKeys), c.from))
                Log.write("implicit undo")
            }
            keys.removeLast()
            if keys.isEmpty { resetWord() }
        }
        convertCycle = []
    }

    // MARK: - Word end

    private enum BoundaryKind { case space, control, symbol }

    private func boundary(event: CGEvent, ks: KeyStroke, cur: KeyLayout, kind: BoundaryKind) -> Result {
        defer { convertCycle = [] }
        guard !keys.isEmpty, let screen = screenLang else {
            resetWord(); last = nil
            return .pass
        }
        var result = Result.pass
        if let ch = cur.char(ks), ".!?\r\n".contains(ch) || code(ks) == 36 { pendingSentenceEnd = true }
        if !disabled, let target = decideFinal() {
            let boundaryChar = cur.char(ks) ?? ""
            apply(to: target, typedSoFarExcludingLast: false, manual: false, capitalize: shouldCapitalize(target))
            Log.write("final fix len=\(keys.count) -> \(target.rawValue)")
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
            }
        }
        finishWord(endedWithSpace: kind == .space)
        sentenceStart = pendingSentenceEnd
        if pendingSentenceEnd { sentence = []; pendingSentenceEnd = false }
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

    private func decideMidWord() -> Lang? {
        guard let o = screenLang, !untouchableCase(keys, final: false) else { return nil }
        let oText = core(keys, o)
        guard keys.count >= settings.minLetters, !store.isException(oText, o) else { return nil }
        let pO = prefixScore(oText, o)
        let alts = alternatives(keys, excluding: o, score: prefixScore, minScore: minAltPrefix)
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
        if keys.count < settings.minLetters {
            // short words ("yf" → "на"): the alternative must be a very common word and the original junk,
            // or the previous word must be in the same script
            let strong = best.score >= 2000 && best.score >= max(fO, pO / 10) * 1000
            let ctx = prevWordLang.map { $0 == best.lang || $0.isCyrillic == best.lang.isCyrillic } ?? false
            guard keys.count >= 2, strong || (ctx && fO == 0 && best.score >= 500) else { return nil }
        }
        return pick(alts)
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

    func undo() {
        if SpellFix.shared.undoLast() { reset(); return }
        if !keys.isEmpty, let c = correction, let cur = screenLang,
           let curL = layouts.layouts[cur], let fromL = layouts.layouts[c.from] {
            layouts.select(c.from)
            Injector.backspaces(curL.text(keys).count)
            Injector.type(fromL.text(keys))
            screenLang = c.from
            disabled = true
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

    func convert() {
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
        guard settings.learning, !disabled || correction != nil, let l = layouts.layouts[lang] else { return }
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
