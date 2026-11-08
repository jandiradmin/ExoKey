import AppKit
import ApplicationServices
import Carbon

/// Autocomplete (TZ §13): ghost text after the caret (or a small panel if the caret can't be located).
/// Sources in priority order: saved phrases → local model → dictionary (light mode).
final class Predictor {
    static let shared = Predictor()

    private var timer: Timer?
    private var generation = 0
    private var streamTask: Task<Void, Never>?
    private var consumed = ""
    private var namePartial = ""       // lowercase start of a name typed by the user; capitalized on accept          // characters of the current suggestion the user already typed
    private(set) var suggestion = ""
    private var suggestionLang: Lang = .en
    private let panel: NSPanel
    private let label: NSTextField
    private let bg: NSVisualEffectView
    private var anchor: CGRect = .zero          // AX coordinates (top-left origin)
    private var anchorKind: AnchorKind = .char
    private var lastReason = ""
    private var enabledPids: Set<pid_t> = []
    private var lastFieldText = ""       // field text from the latest read (for style learning on Return)

    // last insertion (for undo and learning)
    private var lastInsert = ""
    private(set) var lastInsertedChar: Character?
    private var lastInsertLang: Lang = .en
    private var keysSinceInsert = 0

    enum AnchorKind { case char, caret, field }

    var isVisible: Bool { panel.isVisible && !suggestion.isEmpty }

    private init() {
        label = NSTextField(labelWithString: "")
        label.backgroundColor = .clear
        label.drawsBackground = false
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .darkAqua)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let root = NSView()
        root.addSubview(bg)
        root.addSubview(label)
        panel.contentView = root
    }

    // MARK: Availability

    private var available: Bool {
        let s = Settings.shared
        guard s.aiEnabled, !Engine.shared.excludedApp, !IsSecureEventInputEnabled(), !FieldGuard.focusedIsSensitive() else { return false }
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, s.isAIExcluded(id) { return false }
        guard let l = LayoutManager.shared.currentLang, s.aiLangs.contains(l) else { return false }
        return true
    }

    private var useModel: Bool { Settings.shared.aiMode == .model && AIModel.shared.state == .ready }

    // MARK: Key flow

    /// Called after a key event was delivered to the app. `typed` — produced character (nil for non-text).
    /// Characters typed since the last click / navigation (the real caret follows them).
    private var recentTyped = ""
    var recentTypedTail: String { recentTyped }

    func keyTyped(code: Int64, typed: String?) {
        if let t = typed, t.count == 1 { recentTyped = String((recentTyped + t).suffix(40)) }
        else if code == 51 { if !recentTyped.isEmpty { recentTyped.removeLast() } }
        else if code >= 0 { recentTyped = "" }
        if ContactPicker.shared.isVisible { hide(); return }
        if code < 0 && suppressed { return }      // our own swallowed key (e.g. Esc) — stay hidden
        suppressed = false
        keysSinceInsert += 1
        if keysSinceInsert == 1, code == 51, !lastInsert.isEmpty {
            recordRejection()                      // erased right after accepting
        }
        if Settings.shared.aiLearnStyle, let t = typed, t.count == 1, ".!?…".contains(t) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self = self, let ctx = self.readContext() else { return }
                StyleMemory.shared.capture(fieldText: ctx.text, app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
            }
        }
        guard available else { hide(); return }
        if isVisible, let t = typed, t.count == 1, suggestion.hasPrefix(t) {
            // typed a whole suggested word by hand (space after letters) — the guess was right
            if t == " ", let l = consumed.last, l.isLetter { Stats.add(.aiHitWords) }
            suggestion.removeFirst()               // user types what we suggested — keep the rest
            consumed += t
            if suggestion.trimmingCharacters(in: .whitespaces).isEmpty { hide(); schedule(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.reposition() }
            return
        }
        hide()
        schedule()
    }

    func schedule(extraDelay: Double = 0) {
        WindowContext.shared.refresh()
        timer?.invalidate()
        generation += 1
        let delay = Double(max(50, Settings.shared.aiDelay)) / 1000 + extraDelay
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.request() }
    }

    func hide(file: String = #fileID, line: Int = #line) {
        // debug: who removes a suggestion that is on screen ("after Tab the suggestion disappears")
        if isVisible, UserDefaults.standard.bool(forKey: "aiDebug") {
            Log.write("ai: hidden by \(file.split(separator: "/").last ?? ""):\(line) len=\(suggestion.count)" + Log.words(suggestion))
        }
        timer?.invalidate()
        streamTask?.cancel()
        streamTask = nil
        consumed = ""
        namePartial = ""
        generation += 1
        suggestion = ""
        panel.orderOut(nil)
    }

    /// Esc: hide and don't suggest again until the user types something.
    private var suppressed = false
    func dismiss() { hide(); suppressed = true }

    func accept(all: Bool) {
        guard !suggestion.isEmpty else { return }
        var part = suggestion
        if !all {
            var out = ""
            var seenWord = false
            for ch in suggestion {
                if ch == " " && seenWord { break }
                if ch.isLetter || ch.isNumber { seenWord = true }
                out.append(ch)
            }
            part = out
        }
        Injector.lastWasAccept = true
        StyleMemory.shared.lastShown?.accepted = true
        Stats.add(.aiAccepted)
        Stats.add(.aiHitWords, max(1, part.split(whereSeparator: { $0 == " " }).count))
        if !namePartial.isEmpty {
            // "мар" + "ина" → "Марина"
            let onScreen = namePartial + consumed.prefix { $0.isLetter || $0 == "-" || $0 == "'" }
            Injector.backspaces(onScreen.count)
            Injector.type(NameCase.capitalize(onScreen))
            noteInserted(NameCase.capitalize(onScreen), erased: onScreen.count)
            namePartial = ""
        }
        Injector.type(part)
        noteInserted(part)
        lastInsertedChar = part.last
        if let last = part.last, last.isLetter { Engine.shared.continuesWord = true }   // "калькулятор|" + "ом"
        lastInsert = part
        lastInsertLang = suggestionLang
        keysSinceInsert = 0
        recordAccept(part)
        Log.write("ai: accepted \(all ? "all" : "word")" + Log.words(part))
        if part == suggestion {
            hide()
            // the app needs a moment to show the inserted text: asking right away read the old caret position
            // and the next suggestion never came ("suggestions disappear after Tab")
            schedule(extraDelay: 0.3)
        } else {
            suggestion.removeFirst(part.count)
            consumed += part        // the stream keeps coming: don't bring the accepted word back
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.reposition() }
        }
    }

    /// Text we inserted is "just typed" too: readContext finds the caret by it (Electron reports the caret off),
    /// otherwise the accepted word looked like text after the caret and the rest of the suggestion vanished.
    private func noteInserted(_ s: String, erased: Int = 0) {
        recentTyped = String((String(recentTyped.dropLast(erased)) + s).suffix(40))
    }

    /// Removes the text inserted by the last acceptance, only if nothing was typed after it.
    func undoInsert() {
        guard !lastInsert.isEmpty, keysSinceInsert == 0 else {
            Notifier.show(L.t("notif.undoUnavailable"))
            return
        }
        hide()
        Injector.backspaces(lastInsert.count)
        recordRejection()
        keysSinceInsert = 1
    }

    // MARK: Learning

    private func phraseKey(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?…"))
    }

    private func recordAccept(_ part: String) {
        guard Settings.shared.aiPersonalization else { return }
        let k = phraseKey(part)
        guard k.split(separator: " ").count >= 2 else { return }
        let n = UserStore.shared.bump("acc:\(lastInsertLang.rawValue):\(k)")
        if n >= 2, UserStore.shared.find(.phrase, suggestionLang, k) == nil {
            UserStore.shared.upsert(UserEntry(word: k, lang: suggestionLang, kind: .phrase, uses: n, source: .accepted))
        }
    }

    private func recordRejection() {
        defer { lastInsert = "" }
        guard Settings.shared.aiPersonalization else { return }
        let k = phraseKey(lastInsert)
        guard !k.isEmpty else { return }
        let n = UserStore.shared.bump("rej:\(lastInsertLang.rawValue):\(k)")
        if let p = UserStore.shared.find(.phrase, lastInsertLang, k), p.source != .manual { UserStore.shared.delete(p) }
        _ = n
        // No automatic bans: erasing a suggestion says nothing reliable about it, and learned bans ("т", "и", "the")
        // cut almost every suggestion. Only words the user bans by hand in the Dictionary window are removed.
    }

    // MARK: Accessibility

    /// Chrome/Electron expose their text to accessibility only on request.
    func enableAccessibility(for app: NSRunningApplication?) {
        guard let pid = app?.processIdentifier, !enabledPids.contains(pid) else { return }
        enabledPids.insert(pid)
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    private struct Ctx { let text: String; let anchor: CGRect; let kind: AnchorKind }

    /// Diagnostics (aiDebug only): what the autocomplete sees in the frontmost app, written to a local log file.
    func debugDump() {
        guard UserDefaults.standard.bool(forKey: "aiDebug"), let app = NSWorkspace.shared.frontmostApplication else { return }
        enableAccessibility(for: app)
        lastReason = ""
        let ctx = readContext()
        let win = WindowContext.collect(pid: app.processIdentifier)
        var out = "app: \(app.bundleIdentifier ?? "-")\nwindow: \(win.title)\n"
        out += "field: " + (ctx.map { "ok, \($0.text.count) chars before caret, anchor=\($0.kind) rect=\($0.anchor)" } ?? "FAIL \(lastReason)") + "\n"
        out += "screens: " + NSScreen.screens.map { "\($0.frame)" }.joined(separator: " ") + "\n"
        // focused element details (why the caret can't be found)
        let sys = AXUIElementCreateSystemWide()
        var fv: CFTypeRef?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &fv) == .success, let f = fv {
            let e = f as! AXUIElement
            var names: CFArray?
            AXUIElementCopyAttributeNames(e, &names)
            var pnames: CFArray?
            AXUIElementCopyParameterizedAttributeNames(e, &pnames)
            var role: CFTypeRef?, sr: CFTypeRef?, rr: CFTypeRef?, tm: CFTypeRef?
            AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(e, kAXSubroleAttribute as CFString, &sr)
            let rangeOK = AXUIElementCopyAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, &rr) == .success
            let tmOK = AXUIElementCopyAttributeValue(e, "AXSelectedTextMarkerRange" as CFString, &tm) == .success
            var bOK = "-"
            if let t = tm {
                var b: CFTypeRef?
                bOK = "\(AXUIElementCopyParameterizedAttributeValue(e, "AXBoundsForTextMarkerRange" as CFString, t, &b).rawValue) \(b.map { "\($0)" } ?? "nil")"
            }
            out += "focused: role=\(role as? String ?? "-") sub=\(sr as? String ?? "-") range=\(rangeOK) markers=\(tmOK) markerBounds=\(bOK)\n"
            out += "attrs: \((names as? [String] ?? []).joined(separator: ","))\n"
            out += "param: \((pnames as? [String] ?? []).joined(separator: ","))\n"
        }
        out += "screen (\(win.text.count) chars, ocr=\(WindowContext.lastWasOCR), screenAllowed=\(ScreenText.allowed)):\n" + win.text + "\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ExoKey-context-\(app.bundleIdentifier ?? "app").txt")
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }

    private var lastAnchor: (rect: CGRect, count: Int, pid: pid_t, at: Date)?
    private func rememberAnchor(_ r: CGRect, count: Int) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        lastAnchor = (r, count, pid, Date())
    }

    private func fail(_ r0: String) -> Ctx? {
        let r = r0 + " app=" + (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")
        if r != lastReason {
            Log.write("ai: skip \(r)")
        }
        lastReason = r
        return nil
    }

    /// What may follow the caret on the line and still count as "typing at the end": spaces, invisible marks,
    /// and closing characters — a quote or bracket the editor auto-closed, a placeholder line "____", final punctuation.
    private static let invisible = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{FFFC}\u{00A0}"))
        .union(CharacterSet(charactersIn: "\"')]}»”’›_.,;:!?…"))

    private static func rect(_ v: CFTypeRef?) -> CGRect? {
        guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &r), r.height > 2, r.height < 200 else { return nil }
        return r
    }

    private func readContext() -> Ctx? {
        enableAccessibility(for: NSWorkspace.shared.frontmostApplication)
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return fail("no-focus") }
        let e = el as! AXUIElement
        var sub: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, kAXSubroleAttribute as CFString, &sub) == .success,
           (sub as? String) == (kAXSecureTextFieldSubrole as String) { return nil }
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &val) == .success,
              let full = val as? String else { return fail("no-value") }
        let ns = full as NSString
        var range = CFRange(location: ns.length, length: 0)
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() {
            AXValueGetValue(rv as! AXValue, .cfRange, &range)
        }
        guard range.length == 0 else { return fail("selection") }
        var loc = min(max(0, range.location), ns.length)
        // some Electron editors report the caret at 0 — assume typing at the end
        if loc == 0, ns.length > 0 { loc = ns.length }
        var after = ns.substring(from: loc)
        var restOfLine = after.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if !restOfLine.unicodeScalars.allSatisfy({ Self.invisible.contains($0) }) {
            // Electron/Chromium editors sometimes report the caret a few characters off: find what was just typed
            let probe = String(recentTyped.suffix(12))
            let fixed = probe.count >= 4 ? ns.range(of: probe, options: .backwards) : NSRange(location: NSNotFound, length: 0)
            if fixed.location != NSNotFound {
                loc = fixed.location + fixed.length
                after = ns.substring(from: loc)
                restOfLine = after.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            }
            if !restOfLine.unicodeScalars.allSatisfy({ Self.invisible.contains($0) }) {
                // diagnostics without the text itself: kinds of the first characters after the caret
                let kinds = restOfLine.unicodeScalars.prefix(4).map { u -> String in
                    CharacterSet.letters.contains(u) ? "L" : CharacterSet.decimalDigits.contains(u) ? "D"
                        : String(format: "U+%04X", u.value)
                }.joined(separator: " ")
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
                return fail("text-after-caret [\(kinds)] probe=\(fixed.location != NSNotFound) len=\(restOfLine.count) role=\(role as? String ?? "-") value=\(ns.length) caret=\(loc) typed=\(recentTyped.count)")
            }
        }
        let start = max(0, loc - 2000)
        let text = ns.substring(with: NSRange(location: start, length: loc - start))
        lastFieldText = text

        // 1) bounds of the previous character / empty range
        if loc > 0, ns.substring(with: NSRange(location: loc - 1, length: 1)) != "\n" {
            var r = CFRange(location: loc - 1, length: 1)
            if let rv = AXValueCreate(.cfRange, &r) {
                var b: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(e, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &b) == .success,
                   let rect = Self.rect(b) {
                    lastReason = ""
                    rememberAnchor(rect, count: text.count)
                    return Ctx(text: text, anchor: rect, kind: .char)
                }
            }
        }
        // 1b) a character or two further back (some web editors give no box for a just-typed space)
        for back in 2...3 where loc >= back {
            let seg = ns.substring(with: NSRange(location: loc - back, length: back))
            guard !seg.contains("\n") else { break }
            var r = CFRange(location: loc - back, length: 1)
            guard let rv = AXValueCreate(.cfRange, &r) else { break }
            var b: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(e, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &b) == .success,
               var rect = Self.rect(b) {
                rect.origin.x = rect.maxX + CGFloat(back - 1) * rect.height * 0.4 - rect.width
                lastReason = ""
                return Ctx(text: text, anchor: rect, kind: .char)
            }
        }
        // 2) Chrome / Electron: text markers
        var tm: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, "AXSelectedTextMarkerRange" as CFString, &tm) == .success, let tmr = tm {
            var b: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(e, "AXBoundsForTextMarkerRange" as CFString, tmr, &b) == .success,
               let rect = Self.rect(b) {
                lastReason = ""
                return Ctx(text: text, anchor: rect, kind: .caret)
            }
        }
        // 2b) the page didn't answer this time (busy web apps time out): continue from the last good position
        //     in the same field, shifted by the characters typed since
        if let la = lastAnchor, la.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier,
           Date().timeIntervalSince(la.at) < 15, text.count >= la.count, text.count - la.count <= 40,
           !text.suffix(text.count - la.count).contains("\n") {
            var rect = la.rect
            rect.origin.x += CGFloat(text.count - la.count) * la.rect.height * 0.45
            lastReason = ""
            return Ctx(text: text, anchor: rect, kind: .char)
        }
        // 3) fallback: small panel under the text field (off: users found it confusing)
        guard UserDefaults.standard.bool(forKey: "aiPanelFallback") else { return fail("no-caret") }
        var pos: CFTypeRef?, size: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pos) == .success,
           AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size) == .success,
           let pv = pos, let sv = size {
            var p = CGPoint.zero, sz = CGSize.zero
            AXValueGetValue(pv as! AXValue, .cgPoint, &p)
            AXValueGetValue(sv as! AXValue, .cgSize, &sz)
            if sz.width > 0 {
                lastReason = ""
                return Ctx(text: text, anchor: CGRect(origin: p, size: sz), kind: .field)
            }
        }
        return fail("no-caret")
    }

    // MARK: Request

    private func request() {
        let gen = generation
        guard available, !Engine.shared.wordUncertain, !SpellFix.shared.isOffering else { return }
        guard let ctx = readContext() else { return }
        let text = ctx.text
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
              let lastChar = text.last, !lastChar.isNewline else { return }
        // right after "?" the model tends to answer the question itself — nothing to suggest there
        if text.trimmingCharacters(in: .whitespaces).hasSuffix("?") { return }
        let lang = LayoutManager.shared.currentLang ?? .en
        let partial = Self.currentWord(text)
        let s = Settings.shared
        let debug = UserDefaults.standard.bool(forKey: "aiDebug")

        // 1) saved phrases
        if s.aiPhrases, s.aiPersonalization, let p = phraseCompletion(text, lang) {
            present(applyNames(p, partial: partial, lang: lang), ctx, lang)
            return
        }
        // 2) the model leads, as in the early versions: it finishes the current word AND continues the phrase.
        //    The dictionary only cuts misspelled words. When the model has nothing, whole words from the screen,
        //    the dictionary or the user's habits fill in.
        if useModel {
            var prompt = text
            while prompt.last == " " { prompt.removeLast() }
            prompt = buildPrompt(draft: prompt, lang: lang)
            let afterSpace = lastChar == " "
            let maxWords = s.aiPhrases ? max(1, s.aiMaxWords) : 1
            consumed = ""
            let seen = seenWords(text)
            streamTask = AIModel.shared.stream(prompt, maxTokens: min(48, 4 + maxWords * 3)) { [weak self] raw, done, cut in
                guard let self = self, gen == self.generation else { return }
                // while streaming the last word may be unfinished
                var out = Self.extract(raw, afterSpace: afterSpace, midWord: !partial.isEmpty, maxWords: maxWords, cut: !done || cut)
                out = self.preferUserWord(out, partial: partial, lang: lang)
                out = self.removeBanned(out, partial: partial, lang: lang)
                out = self.knownWordsOnly(out, partial: partial, lang: lang, final: done, seen: seen)   // spelling control
                if done, out.isEmpty, let f = self.fallback(text, partial: partial, lang: lang) {
                    out = f
                    if debug { Log.write("ai: model had nothing, fallback word") }
                } else if done, debug {
                    Log.write("ai: answer \(out.isEmpty ? "none" : "\(out.split(separator: " ").count) words")" + Log.words("\(partial)|\(out) model=\(raw)") + " app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
                }
                out = self.applyNames(out, partial: partial, lang: lang)
                // the final answer may reject what an earlier streamed piece already showed — don't leave it on screen
                let dropShown = { if done, self.isVisible { self.hide() } }
                if Self.repeatsTyped(out, text: text, partial: partial) {
                    if done, debug { Log.write("ai: suggestion repeats what was just typed — dropped") }
                    dropShown()
                    return
                }
                guard !out.isEmpty, out.hasPrefix(self.consumed) else { dropShown(); return }
                let rest = String(out.dropFirst(self.consumed.count))
                guard !rest.isEmpty else { dropShown(); return }
                guard rest != self.suggestion else { return }
                if self.isVisible { self.suggestion = rest; self.layout() } else { self.present(rest, ctx, lang) }
            }
            return
        }
        // 3) light mode (no model): screen words, dictionary, habits
        if let f = fallback(text, partial: partial, lang: lang) { present(applyNames(f, partial: partial, lang: lang), ctx, lang) }
    }

    /// The suggestion just repeats the user's last words ("пока не нужно" + "пока не нужно", "нужно" + "нужно"):
    /// models copy text they see on screen or in the draft.
    static func repeatsTyped(_ s: String, text: String, partial: String) -> Bool {
        let wordsOf: (String) -> [String] = { $0.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "-") }.map(String.init) }
        var sug = wordsOf(s)
        guard !sug.isEmpty else { return false }
        var typed = wordsOf(text)
        // the word being typed is completed by the suggestion (only when the suggestion continues it, not ", нужно")
        if !partial.isEmpty, !typed.isEmpty, s.first?.isLetter == true {
            typed.removeLast()
            sug[0] = partial.lowercased() + sug[0]
        }
        let n = min(sug.count, 4)
        guard typed.count >= n else { return false }
        if Array(typed.suffix(n)) == Array(sug.prefix(n)) { return true }
        // the next word equals the last typed word ("нужно нужно")
        return sug.first == typed.last && (sug.first?.count ?? 0) > 2
    }

    /// Whole words only (never a piece of a word): from the conversation on screen, the dictionary when one word
    /// clearly dominates, or the word the user usually writes next.
    private func fallback(_ text: String, partial: String, lang: Lang) -> String? {
        if Settings.shared.aiWindowContext, let c = contextCompletion(text, partial: partial) { return c }
        if !partial.isEmpty {
            let d = removeBanned(dictCompletion(partial, lang), partial: partial, lang: lang)
            return d.isEmpty ? nil : d
        }
        return bigramNext(text, lang)
    }

    /// Prompt = (style examples) + meaningful context above the field + the user's draft.
    /// Plain text for a base model (chosen with tools/test/prompt_bench.py on real samples):
    /// a few of the user's own messages, the text on screen (the conversation), then the draft.
    private func buildPrompt(draft: String, lang: Lang) -> String {
        let s = Settings.shared
        let app = NSWorkspace.shared.frontmostApplication
        var head = ""
        let styles = s.aiLearnStyle ? StyleMemory.shared.examples(app: app?.bundleIdentifier, lang: lang, limit: 6) : []
        let labeled = AIModel.current.file == AIModel.variants[.quality]?.file   // Base model: labeled sections
        if !styles.isEmpty {
            head += (labeled ? "How I write:\n" : "") + styles.map { "- " + $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n") + "\n\n"
        }
        var field = String(draft.suffix(1500))
        if s.aiWindowContext, let pid = app?.processIdentifier {
            let ctx = WindowContext.shared.context(for: pid)
            var win = ctx.text
            // the field's own text may also be visible in the window — don't repeat it
            let probe = String(field.prefix(120))
            if probe.count > 10 { win = win.replacingOccurrences(of: probe, with: "") }
            win = String(win.suffix(2500)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !win.isEmpty { head += labeled ? "Screen:\n" + win + "\n\n" : win + "\n" }
        }
        if field.isEmpty { field = draft }
        // the early versions' plain format for the default (Instruct) model — the one users liked
        let prompt = head + (labeled ? "My message:\n" : "") + field
        if UserDefaults.standard.bool(forKey: "aiDebug") {
            try? ("[\(app?.bundleIdentifier ?? "-")]\n" + prompt).write(
                to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ExoKey-ai-prompt.txt"),
                atomically: true, encoding: .utf8)
        }
        return prompt
    }

    /// Return pressed (message sent / paragraph finished): learn from the text typed so far.
    func messageSent() {
        guard Settings.shared.aiLearnStyle, !lastFieldText.isEmpty else { return }
        StyleMemory.shared.capture(fieldText: lastFieldText, app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        lastFieldText = ""
    }

    private func present(_ s: String, _ ctx: Ctx, _ lang: Lang) {
        if !isVisible { Stats.add(.aiShown) }
        if UserDefaults.standard.bool(forKey: "aiDebug"), !isVisible {
            Log.write("ai: shown \(s.split(separator: " ").count) words at \(ctx.kind) x=\(Int(ctx.anchor.minX)) y=\(Int(ctx.anchor.minY)) h=\(Int(ctx.anchor.height)) app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
        }
        if Settings.shared.aiLearnStyle {
            let app = NSWorkspace.shared.frontmostApplication
            StyleMemory.shared.lastShown = StyleMemory.Shown(
                draft: ctx.text, suggestion: s, accepted: false,
                context: app.map { WindowContext.shared.context(for: $0.processIdentifier).text } ?? "",
                app: app?.bundleIdentifier ?? "")
        }
        suggestion = s
        suggestionLang = lang
        anchor = ctx.anchor
        anchorKind = ctx.kind
        layout()
        panel.orderFrontRegardless()
    }

    /// Names in the suggestion get a capital letter; a lowercase name being typed is fixed on accept.
    private func applyNames(_ s: String, partial: String, lang: Lang) -> String {
        guard !s.isEmpty else { return s }
        let nc = NameCase.shared
        var first = "", rest = Substring(s)
        if !partial.isEmpty {
            let frag = s.prefix { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
            first = String(frag)
            rest = s.dropFirst(frag.count)
            let full = partial + first
            namePartial = (partial == partial.lowercased() && nc.isName(TextNorm.normalize(full, lang), lang)) ? partial : ""
        } else {
            namePartial = ""
        }
        return first + nc.fixWords(String(rest), lang)
    }

    /// Completion copied from the text on screen (the conversation) or from earlier in the same field:
    /// a word that starts with what is being typed, or the words that followed the same two words there.
    private func contextCompletion(_ text: String, partial: String) -> String? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let before = String(text.dropLast(partial.count))
        let source = WindowContext.shared.context(for: pid).text + "\n" + String(before.suffix(3000))
        struct Tok { let w: String; let lw: String; let breakBefore: Bool }
        var toks: [Tok] = []
        var gap = ""
        var cur = ""
        func flush() {
            guard !cur.isEmpty else { return }
            toks.append(Tok(w: cur, lw: cur.lowercased(), breakBefore: gap.contains { ".!?;:\n()[]\"«»".contains($0) }))
            cur = ""; gap = ""
        }
        for ch in source {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" || (ch == "-" && !cur.isEmpty) { cur.append(ch) }
            else { flush(); gap.append(ch) }
        }
        flush()
        if UserDefaults.standard.bool(forKey: "aiDebug") {
            Log.write("ai: screen words \(toks.count), screen chars \(WindowContext.shared.context(for: pid).text.count)")
        }
        guard toks.count > 2 else { return nil }
        let typedWords = before.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" || $0 == "-") }.map { $0.lowercased() }
        let prev1 = typedWords.last, prev2 = typedWords.count > 1 ? typedWords[typedWords.count - 2] : nil
        let sentenceStart = before.trimmingCharacters(in: .whitespaces).last.map { ".!?\n".contains($0) } ?? true

        // words that follow position i in the source, until punctuation (max n)
        func follow(_ i: Int, _ n: Int) -> String {
            var out: [String] = []
            var j = i + 1
            while j < toks.count, out.count < n, !toks[j].breakBefore { out.append(toks[j].w); j += 1 }
            return out.joined(separator: " ")
        }
        if !partial.isEmpty {
            let pl = partial.lowercased()
            guard pl.count >= 2 else { return nil }
            var best: (score: Int, i: Int)?
            for (i, t) in toks.enumerated() where t.lw.count >= max(4, pl.count + 2) && t.lw.hasPrefix(pl) {
                var score = i                                    // later = closer to the field
                if let p = prev1, i > 0, toks[i - 1].lw == p, !t.breakBefore { score += 100_000 }
                if best == nil || score >= best!.score { best = (score, i) }
            }
            guard let b = best else { return nil }
            let word = toks[b.i].w
            var rest = String(word.dropFirst(partial.count))
            // the phrase around it matched too: offer the next words as well
            if b.score >= 100_000 { let more = follow(b.i, 3); if !more.isEmpty { rest += " " + more } }
            return rest.isEmpty ? nil : rest
        }
        // after a space: the same two words (or one long word) appeared on screen — offer what followed them
        guard !sentenceStart, let p1 = prev1, text.last == " " else { return nil }
        for i in stride(from: toks.count - 1, through: 0, by: -1) where toks[i].lw == p1 {
            let matched: Bool
            if let p2 = prev2 { matched = i > 0 && toks[i - 1].lw == p2 && !toks[i].breakBefore } else { matched = p1.count >= 5 }
            guard matched else { continue }
            let more = follow(i, 4)
            if !more.isEmpty { return more }          // the user's own words at the very end have nothing after them
        }
        return nil
    }

    static func currentWord(_ text: String) -> String {
        var w = ""
        for ch in text.reversed() {
            if ch.isLetter || ch == "'" || ch == "’" { w.insert(ch, at: w.startIndex) } else { break }
        }
        return w
    }

    /// Rest of a saved phrase whose beginning matches the end of the text.
    private func phraseCompletion(_ text: String, _ lang: Lang) -> String? {
        let store = UserStore.shared
        let candidates = store.phrases.filter { $0.lang == lang && ($0.source == .manual || $0.uses >= 2) }
        guard !candidates.isEmpty else { return nil }
        let tail = String(text.suffix(120)).lowercased()
        var best: (rest: String, matched: Int, uses: Int)?
        for p in candidates {
            let phrase = p.word
            let lower = phrase.lowercased()
            let chars = Array(lower)
            guard chars.count > 3 else { continue }
            for k in stride(from: chars.count - 1, through: 3, by: -1) {
                let pre = String(chars[0..<k])
                guard tail.hasSuffix(pre) else { continue }
                let before = tail.dropLast(pre.count).last
                if let b = before, b.isLetter { continue }      // must start at a word boundary
                let rest = String(Array(phrase)[k...])
                if best == nil || k > best!.matched || (k == best!.matched && p.uses > best!.uses) {
                    best = (rest, k, p.uses)
                }
                break
            }
        }
        guard let b = best, !b.rest.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return removeBanned(b.rest, lang: lang).isEmpty ? nil : b.rest
    }

    /// A word is spelled right if a dictionary or the user knows it — or it is written in the conversation on screen
    /// or earlier in the field (names, products, terms: "ProPresenter").
    private func isKnownWord(_ w: String, _ lang: Lang, seen: Set<String>) -> Bool {
        let low = TextNorm.normalize(w, lang)
        guard low.count > 1 else { return true }
        if seen.contains(w.lowercased()) || seen.contains(low) { return true }
        if (Engine.shared.dicts[lang]?.freq(low) ?? 0) > 0 { return true }
        for l in Lang.allCases where l != lang { if (Engine.shared.dicts[l]?.freq(low) ?? 0) > 0 { return true } }
        return UserStore.shared.count("uw:\(lang.rawValue):\(low)") > 0 || UserStore.shared.isWord(low, lang)
    }

    /// Cuts a suggestion before its first misspelled word. The first word is checked together with what is typed
    /// of it ("соотв" + "етствуют"); a word still being streamed is not shown until it is complete and checked
    /// (showing it and taking it back made suggestions blink and vanish).
    private func knownWordsOnly(_ s: String, partial: String, lang: Lang, final: Bool, seen: Set<String>) -> String {
        var out = ""
        var word = partial
        var pending = ""
        for ch in s {
            if ch.isLetter || ch == "'" || ch == "’" || ch == "-" {
                word.append(ch); pending.append(ch)
            } else {
                if !word.isEmpty {
                    guard isKnownWord(word, lang, seen: seen) else { return trimmedEnd(out) }
                    out += pending
                }
                word = ""; pending = ""
                out.append(ch)
            }
        }
        if !pending.isEmpty, final, isKnownWord(word, lang, seen: seen) { out += pending }
        return trimmedEnd(out)
    }

    private func trimmedEnd(_ s: String) -> String {
        var out = s
        while let l = out.last, l == " " || l == "," || l == ";" || l == ":" || l == "—" || l == "(" || l == "\"" { out.removeLast() }
        return out
    }

    /// Words of the conversation on screen and of the field itself, lowercased.
    private func seenWords(_ text: String) -> Set<String> {
        var src = String(text.suffix(3000))
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            src += "\n" + WindowContext.shared.context(for: pid).text
        }
        var out = Set<String>()
        for w in src.lowercased().split(whereSeparator: { !($0.isLetter || $0 == "'" || $0 == "’" || $0 == "-") }) where w.count > 1 {
            out.insert(String(w))
        }
        return out
    }

    /// After a space: the word this user wrote after the previous word at least twice, more often than anything else.
    private func bigramNext(_ text: String, _ lang: Lang) -> String? {
        guard text.last == " " else { return nil }
        let words = text.split { !($0.isLetter || $0 == "-" || $0 == "'") }
        guard let lastW = words.last, !".!?".contains(text.trimmingCharacters(in: .whitespaces).last ?? ".") else { return nil }
        let prev = TextNorm.normalize(String(lastW), lang)
        let next = UserStore.shared.counts(withPrefix: "ub:\(lang.rawValue):\(prev) ")
        let total = next.reduce(0) { $0 + $1.count }
        guard let top = next.max(by: { $0.count < $1.count }), top.count >= 2, Double(top.count) / Double(total) >= 0.5 else { return nil }
        return top.rest
    }

    /// The current word, completed from the user's own words and the frequency dictionary — only when one word
    /// clearly dominates among all words with this beginning ("пож" → "алуйста"). Checked with tools/test/typing_sim.py.
    /// Dictionary words (and the user's own) that start with the partial word, with frequencies.
    private func wordCandidates(_ partial: String, _ lang: Lang) -> [(word: String, f: Int)] {
        let low = TextNorm.normalize(partial, lang)
        var c: [String: Int] = [:]
        for w in Engine.shared.dicts[lang]?.topK(low, k: 12) ?? [] { c[w.word] = w.freq }
        for (w, n) in UserStore.shared.typedWordCompletions(low, lang) where w.count > low.count { c[w, default: 0] += n * 200_000 }
        for w in UserStore.shared.userCompletions(low, lang) { c[w, default: 0] += 1_000_000 }
        return c.map { ($0.key, $0.value) }
    }

    /// Frequency × how much the model supports the word's continuation; shown only if one word clearly wins.
    private func filteredCompletion(_ partial: String, _ cands: [(word: String, f: Int)], _ toks: [(token: String, p: Double)], _ lang: Lang) -> String {
        guard !cands.isEmpty, !toks.isEmpty else { return "" }
        let low = TextNorm.normalize(partial, lang)
        var scored: [(String, Double)] = cands.map { c in
            let rest = String(c.word.dropFirst(low.count))
            let m = toks.reduce(0.0) { acc, t in
                let tk = t.token.lowercased()
                return !tk.isEmpty && rest.hasPrefix(tk) ? acc + t.p : acc
            }
            return (c.word, Double(c.f) * (m + 0.01))
        }
        scored.sort { $0.1 > $1.1 }
        let total = scored.reduce(0) { $0 + $1.1 }
        guard total > 0, let top = scored.first else { return "" }
        let second = scored.count > 1 ? scored[1].1 : 0
        let share = top.1 / total
        guard share >= 0.65 || (second > 0 && top.1 >= 4 * second && share >= 0.325) else { return "" }
        var rest = String(top.0.dropFirst(low.count))
        if partial.uppercased() == partial, partial.count > 1 { rest = rest.uppercased() }
        return rest
    }

    private func dictCompletion(_ partial: String, _ lang: Lang, share minShare: Double = 0.5, ratio: Int = 3) -> String {
        guard partial.count >= 2 else { return "" }
        let low = TextNorm.normalize(partial, lang)
        guard let d = Engine.shared.dicts[lang] else { return "" }
        let dictTotal = max(0, d.prefixFreq(low) - d.freq(low))
        var cands: [String: Int] = [:]
        var second = 0
        if let t = d.topCompletions(low) { cands[t.word] = t.f1; second = t.f2 }
        var userTotal = 0
        for (w, n) in UserStore.shared.typedWordCompletions(low, lang) where w.count > low.count {
            cands[w, default: 0] += n * 200_000; userTotal += n * 200_000
        }
        for w in UserStore.shared.userCompletions(low, lang) { cands[w, default: 0] += 1_000_000; userTotal += 1_000_000 }
        let ranked = cands.sorted { $0.value > $1.value }
        guard let top = ranked.first else { return "" }
        let f2 = max(second, ranked.count > 1 ? ranked[1].value : 0)
        let total = Double(max(1, dictTotal + userTotal))
        let share = Double(top.value) / total
        guard share >= minShare || (f2 > 0 && top.value >= ratio * f2 && share >= minShare / 2) || f2 == 0 && top.value >= 50 else {
            return ""      // no piece of a word ("соотв" → "етств"): users found half words worse than nothing
        }
        var rest = String(top.key.dropFirst(low.count))
        if partial.uppercased() == partial, partial.count > 1 { rest = rest.uppercased() }
        return rest
    }

    /// If the user dictionary has a word for the current partial word, it wins over the model's word.
    private func preferUserWord(_ s: String, partial: String, lang: Lang) -> String {
        guard partial.count >= 2 else { return s }
        let low = TextNorm.normalize(partial, lang)
        guard let w = UserStore.shared.userCompletions(low, lang).first else { return s }
        let rest = String(w.dropFirst(low.count))
        let modelRest = String(s.prefix { $0.isLetter || $0 == "'" || $0 == "-" })
        return modelRest.lowercased() == rest ? s : rest
    }

    /// Cuts the suggestion before the first banned word or phrase. Whole words only: a banned "да" must not cut
    /// "когда" into "ког". The first word is checked together with what is typed of it (`partial`).
    private func removeBanned(_ s: String, partial: String = "", lang: Lang) -> String {
        let isW: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" || $0 == "ʼ" || $0 == "-" }
        let glued = !partial.isEmpty && (s.first.map(isW) ?? false)
        let pre = glued ? partial.lowercased() : ""
        let low = Array(pre + s.lowercased())
        let shift = pre.count
        var cutOff = s.count
        for b in UserStore.shared.banned where b.lang == lang {
            let w = Array(b.word.lowercased())
            guard !w.isEmpty, w.count <= low.count else { continue }
            for i in 0...(low.count - w.count) where i + w.count > shift {
                guard Array(low[i..<(i + w.count)]) == w else { continue }
                let startOK = i == 0 || !isW(low[i - 1]) || !isW(w[0])
                let endOK = i + w.count == low.count || !isW(low[i + w.count]) || !isW(w[w.count - 1])
                guard startOK, endOK else { continue }
                cutOff = min(cutOff, max(0, i - shift))
                break
            }
        }
        var out = String(s.prefix(cutOff))
        while let l = out.last, l == " " || l == "," { out.removeLast() }
        return out.contains(where: { $0.isLetter || $0.isNumber }) ? out : ""
    }

    /// Cleans the model output: limited number of words, up to the end of the sentence.
    static func extract(_ raw: String, afterSpace: Bool, midWord: Bool, maxWords: Int, cut: Bool) -> String {
        var s = raw
        if afterSpace {
            guard s.first == " " else { return "" }       // model glued text to the previous word
            s.removeFirst()
        }
        if let nl = s.firstIndex(where: \.isNewline) { s = String(s[..<nl]) }
        // escaped junk like "\n\n\n", markup, code
        if let bad = s.firstIndex(where: { "\\{}<>[]|`#*_=~^".contains($0) }) { s = String(s[..<bad]) }
        var out = ""
        var words = 0
        var inWord = midWord && (s.first?.isLetter ?? false)
        var ended = false
        var stoppedEarly = false
        for ch in s {
            let isW = ch.isLetter || ch.isNumber || ch == "'" || ch == "’" || ch == "-"
            if isW {
                if !inWord { inWord = true }
            } else if inWord {
                inWord = false
                words += 1
                if words >= maxWords && ch == " " { stoppedEarly = true; break }
            }
            out.append(ch)
            if ".!?…".contains(ch) { ended = true; break }
            if out.count >= 120 { stoppedEarly = true; break }
        }
        // the last word may be unfinished (token limit, or the model stopped being sure in the middle of it)
        if !ended, !stoppedEarly, cut, inWord {
            if let sp = out.lastIndex(of: " "), sp != out.startIndex {
                out = String(out[..<sp])
            } else {
                // only a piece of a word ("рабо" + "т", or "раб" after a space): nothing rather than half a word
                return ""
            }
        }
        while let l = out.last, l == " " || l == "," || l == ";" || l == ":" || l == "—" || l == "(" || l == "\"" { out.removeLast() }
        // must be mostly letters, and no long runs of the same character
        let letters = out.filter { $0.isLetter }.count
        guard letters >= 1, Double(letters) / Double(max(1, out.filter { $0 != " " }.count)) > 0.6 else { return "" }
        var run = 1, prev: Character? = nil
        for ch in out { run = ch == prev ? run + 1 : 1; prev = ch; if run >= 4 { return "" } }
        return out
    }

    // MARK: Drawing

    private func reposition() {
        guard !suggestion.isEmpty else { return }
        guard let ctx = readContext() else { hide(); return }
        anchor = ctx.anchor
        anchorKind = ctx.kind
        layout()
    }

    private func layout() {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        if anchorKind == .field {
            // small panel under the text field
            label.font = NSFont.systemFont(ofSize: 13)
            label.textColor = NSColor(white: 0.85, alpha: 1)
            label.stringValue = suggestion + "  ⇥"
            let size = label.fittingSize
            let w = size.width + 16, h = size.height + 8
            let frame = NSRect(x: anchor.minX, y: primaryH - anchor.maxY - h - 4, width: w, height: h)
            panel.setFrame(frame, display: false)
            bg.isHidden = false
            bg.frame = NSRect(x: 0, y: 0, width: w, height: h)
            label.frame = NSRect(x: 8, y: 4, width: size.width, height: size.height)
            panel.display()
            return
        }
        bg.isHidden = true
        let h = max(10, anchor.height)
        label.font = NSFont.systemFont(ofSize: max(9, min(40, (h * 0.78).rounded())))
        label.textColor = NSColor(white: 0.55, alpha: 0.85)
        label.stringValue = suggestion
        let size = label.fittingSize
        // NSTextField draws its text ~2pt inside its frame; fine-tune with hidden defaults aiGhostDX / aiGhostDY
        let d = UserDefaults.standard
        let dx = d.object(forKey: "aiGhostDX") as? Double ?? -2
        let dy = d.object(forKey: "aiGhostDY") as? Double ?? -2
        let x = (anchorKind == .char ? anchor.maxX : anchor.minX) + CGFloat(dx)
        let midY = primaryH - anchor.midY
        let frame = NSRect(x: x.rounded(), y: (midY - size.height / 2 + CGFloat(dy)).rounded(), width: size.width + 4, height: size.height)
        panel.setFrame(frame, display: false)
        label.frame = NSRect(origin: .zero, size: frame.size)
        panel.display()
    }
}
