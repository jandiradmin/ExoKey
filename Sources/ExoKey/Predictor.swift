import AppKit
import ApplicationServices
import Carbon

/// Autocomplete (TZ §13): ghost text after the caret (or a small panel if the caret can't be located).
/// Sources in priority order: saved phrases → local model → dictionary (light mode).
final class Predictor {
    static let shared = Predictor()

    private var timer: Timer?
    private var generation = 0
    private(set) var suggestion = ""
    private var suggestionLang: Lang = .en
    private let panel: NSPanel
    private let label: NSTextField
    private let bg: NSVisualEffectView
    private var anchor: CGRect = .zero          // AX coordinates (top-left origin)
    private var anchorKind: AnchorKind = .char
    private var lastReason = ""
    private var enabledPids: Set<pid_t> = []

    // last insertion (for undo and learning)
    private var lastInsert = ""
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
        guard s.aiEnabled, !IsSecureEventInputEnabled() else { return false }
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, s.isAIExcluded(id) { return false }
        guard let l = LayoutManager.shared.currentLang, s.aiLangs.contains(l) else { return false }
        return true
    }

    private var useModel: Bool { Settings.shared.aiMode == .model && AIModel.shared.state == .ready }

    // MARK: Key flow

    /// Called after a key event was delivered to the app. `typed` — produced character (nil for non-text).
    func keyTyped(code: Int64, typed: String?) {
        keysSinceInsert += 1
        if keysSinceInsert == 1, code == 51, !lastInsert.isEmpty {
            recordRejection()                      // erased right after accepting
        }
        guard available else { hide(); return }
        if isVisible, let t = typed, t.count == 1, suggestion.hasPrefix(t) {
            suggestion.removeFirst()               // user types what we suggested — keep the rest
            if suggestion.trimmingCharacters(in: .whitespaces).isEmpty { hide(); schedule(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.reposition() }
            return
        }
        hide()
        schedule()
    }

    func schedule() {
        timer?.invalidate()
        generation += 1
        let delay = Double(max(50, Settings.shared.aiDelay)) / 1000
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.request() }
    }

    func hide() {
        timer?.invalidate()
        generation += 1
        suggestion = ""
        panel.orderOut(nil)
    }

    /// Esc: hide without treating it as an error (ignoring is not a negative signal).
    func dismiss() { hide() }

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
        Injector.type(part)
        lastInsert = part
        lastInsertLang = suggestionLang
        keysSinceInsert = 0
        recordAccept(part)
        Log.write("ai: accepted \(all ? "all" : "word")")
        if part == suggestion {
            hide()
            schedule()
        } else {
            suggestion.removeFirst(part.count)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.reposition() }
        }
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
        if n >= 2, UserStore.shared.find(.banned, lastInsertLang, k) == nil {
            UserStore.shared.upsert(UserEntry(word: k, lang: lastInsertLang, kind: .banned, source: .learned))
            Log.write("ai: banned learned")
        }
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

    private func fail(_ r: String) -> Ctx? {
        if r != lastReason {
            Log.write("ai: skip \(r) app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
        }
        lastReason = r
        return nil
    }

    private static let invisible = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{FFFC}\u{00A0}"))

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
        let loc = min(max(0, range.location), ns.length)
        let after = ns.substring(from: loc)
        let restOfLine = after.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if !restOfLine.unicodeScalars.allSatisfy({ Self.invisible.contains($0) }) { return fail("text-after-caret") }
        let start = max(0, loc - 2000)
        let text = ns.substring(with: NSRange(location: start, length: loc - start))

        // 1) bounds of the previous character / empty range
        if loc > 0, ns.substring(with: NSRange(location: loc - 1, length: 1)) != "\n" {
            var r = CFRange(location: loc - 1, length: 1)
            if let rv = AXValueCreate(.cfRange, &r) {
                var b: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(e, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &b) == .success,
                   let rect = Self.rect(b) {
                    lastReason = ""
                    return Ctx(text: text, anchor: rect, kind: .char)
                }
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
        // 3) fallback: small panel under the text field
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
        guard available, !Engine.shared.wordUncertain else { return }
        guard let ctx = readContext() else { return }
        let text = ctx.text
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
              let lastChar = text.last, !lastChar.isNewline else { return }
        let lang = LayoutManager.shared.currentLang ?? .en
        let partial = Self.currentWord(text)
        let s = Settings.shared

        // 1) saved phrases
        if s.aiPhrases, s.aiPersonalization, let p = phraseCompletion(text, lang) {
            present(p, ctx, lang)
            return
        }
        // 2) model
        if useModel {
            var prompt = text
            while prompt.last == " " { prompt.removeLast() }
            let afterSpace = lastChar == " "
            let maxWords = s.aiPhrases ? max(1, s.aiMaxWords) : 1
            AIModel.shared.complete(prompt, maxTokens: min(48, 4 + maxWords * 3)) { [weak self] out, cut in
                guard let self = self, gen == self.generation, var out = out else { return }
                out = Self.extract(out, afterSpace: afterSpace, midWord: !partial.isEmpty, maxWords: maxWords, cut: cut)
                out = self.preferUserWord(out, partial: partial, lang: lang)
                out = self.removeBanned(out, lang: lang)
                if out.isEmpty, !partial.isEmpty { out = self.dictCompletion(partial, lang) }
                guard !out.isEmpty else { return }
                self.present(out, ctx, lang)
            }
            return
        }
        // 3) light mode: complete the current word from dictionaries
        if !partial.isEmpty {
            let out = removeBanned(dictCompletion(partial, lang), lang: lang)
            if !out.isEmpty { present(out, ctx, lang) }
        }
    }

    private func present(_ s: String, _ ctx: Ctx, _ lang: Lang) {
        suggestion = s
        suggestionLang = lang
        anchor = ctx.anchor
        anchorKind = ctx.kind
        layout()
        panel.orderFrontRegardless()
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

    private func dictCompletion(_ partial: String, _ lang: Lang) -> String {
        guard partial.count >= 2 else { return "" }
        let low = TextNorm.normalize(partial, lang)
        var word = UserStore.shared.userCompletions(low, lang).first
        if word == nil, let d = Engine.shared.dicts[lang]?.bestCompletion(low), d.freq >= 20 { word = d.word }
        guard let w = word, w.count > low.count else { return "" }
        var rest = String(w.dropFirst(low.count))
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

    private func removeBanned(_ s: String, lang: Lang) -> String {
        let low = s.lowercased()
        var cut = s.endIndex
        for b in UserStore.shared.banned where b.lang == lang {
            if let r = low.range(of: b.word.lowercased()) {
                let off = low.distance(from: low.startIndex, to: r.lowerBound)
                let idx = s.index(s.startIndex, offsetBy: off)
                if idx < cut { cut = idx }
            }
        }
        var out = String(s[..<cut])
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
        // the last word may be unfinished if the model hit the token limit
        if !ended, !stoppedEarly, cut, inWord, let sp = out.lastIndex(of: " "), sp != out.startIndex {
            out = String(out[..<sp])
        }
        while let l = out.last, l == " " || l == "," || l == ";" || l == ":" || l == "—" { out.removeLast() }
        guard out.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
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
        let x = anchorKind == .char ? anchor.maxX : anchor.minX
        let midY = primaryH - anchor.midY
        let frame = NSRect(x: x + 1, y: (midY - size.height / 2).rounded(), width: size.width + 4, height: size.height)
        panel.setFrame(frame, display: false)
        label.frame = NSRect(origin: .zero, size: frame.size)
        panel.display()
    }
}
