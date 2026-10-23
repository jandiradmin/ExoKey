import AppKit
import ApplicationServices
import Carbon

/// Inline "ghost text" completions from the local model, drawn right after the caret.
/// Tab accepts the whole suggestion, ⇧Tab the next word. Typing the suggested characters keeps it.
final class Predictor {
    static let shared = Predictor()

    private var timer: Timer?
    private var generation = 0
    private(set) var suggestion = ""
    private let panel: NSPanel
    private let label: NSTextField
    private var caret: CGRect = .zero          // AX coordinates (top-left origin)
    private var caretIsChar = true             // caret rect is the previous character (vs zero-width caret)
    private var lastReason = ""
    private var enabledPids: Set<pid_t> = []

    var isVisible: Bool { panel.isVisible && !suggestion.isEmpty }

    private init() {
        label = NSTextField(labelWithString: "")
        label.textColor = NSColor(white: 0.55, alpha: 0.85)
        label.backgroundColor = .clear
        label.drawsBackground = false
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = label
    }

    // MARK: Triggers

    private var available: Bool {
        let s = Settings.shared
        return s.aiEnabled && AIModel.shared.state == .ready && s.enabled && !Engine.shared.excludedApp
            && !IsSecureEventInputEnabled()
    }

    /// Called after a key event was delivered to the app. `typed` is the produced character, if any.
    func keyTyped(_ typed: String?) {
        guard available else { hide(); return }
        if isVisible, let t = typed, t.count == 1, suggestion.hasPrefix(t) {
            // user types what we suggested — keep the rest
            suggestion.removeFirst()
            if suggestion.trimmingCharacters(in: .whitespaces).isEmpty { hide(); schedule(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.reposition() }
            return
        }
        hide()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        generation += 1
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in self?.request() }
    }

    func hide() {
        timer?.invalidate()
        generation += 1
        suggestion = ""
        panel.orderOut(nil)
    }

    /// Accept everything (`all`) or just the next word.
    func accept(all: Bool) {
        guard !suggestion.isEmpty else { return }
        var part = suggestion
        if !all {
            // leading spaces + one word (+ following punctuation)
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
        Log.write("ai: accepted \(all ? "all" : "word")")
        if all || part == suggestion {
            hide()
            schedule()
        } else {
            suggestion.removeFirst(part.count)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.reposition() }
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

    private struct Ctx { let text: String; let caret: CGRect; let caretIsChar: Bool }

    private func fail(_ r: String) -> Ctx? {
        if r != lastReason {
            Log.write("ai: skip \(r) app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
        }
        lastReason = r
        return nil
    }

    private static let invisible = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{FFFC}\u{00A0}"))

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
        // caret must be at the end of its line (only invisible characters may follow)
        let after = ns.substring(from: loc)
        let restOfLine = after.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if !restOfLine.unicodeScalars.allSatisfy({ Self.invisible.contains($0) }) { return fail("text-after-caret") }
        let start = max(0, loc - 2000)
        let text = ns.substring(with: NSRange(location: start, length: loc - start))

        // caret position: bounds of the previous character, or of the empty range at the caret
        let tries: [(CFRange, Bool)] = loc > 0 ? [(CFRange(location: loc - 1, length: 1), true), (CFRange(location: loc, length: 0), false)]
                                               : [(CFRange(location: 0, length: 0), false)]
        for (r0, isChar) in tries {
            var r = r0
            guard let rv = AXValueCreate(.cfRange, &r) else { continue }
            var b: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(e, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &b) == .success,
               let bv = b, CFGetTypeID(bv) == AXValueGetTypeID() {
                var rect = CGRect.zero
                AXValueGetValue(bv as! AXValue, .cgRect, &rect)
                // previous char is a newline → its bounds are useless
                if isChar, ns.substring(with: NSRange(location: loc - 1, length: 1)) == "\n" { continue }
                if rect.height > 2 && rect.height < 200 {
                    lastReason = ""
                    return Ctx(text: text, caret: rect, caretIsChar: isChar)
                }
            }
        }
        return fail("no-caret")
    }

    // MARK: Request

    private func request() {
        let gen = generation
        guard let ctx = readContext() else { return }
        let text = ctx.text
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3,
              let lastChar = text.last, !lastChar.isNewline else { return }
        var prompt = text
        while prompt.last == " " { prompt.removeLast() }   // LMs predict better without a trailing space
        let afterSpace = lastChar == " "
        AIModel.shared.complete(prompt) { [weak self] out in
            guard let self = self, gen == self.generation, let out = out else { return }
            let s = Self.extract(out, afterSpace: afterSpace)
            guard !s.isEmpty else { Log.write("ai: empty suggestion"); return }
            self.caret = ctx.caret
            self.caretIsChar = ctx.caretIsChar
            self.show(s)
        }
    }

    /// Cleans the model output: up to the end of the sentence, no broken last word.
    static func extract(_ raw: String, afterSpace: Bool) -> String {
        var s = raw
        if afterSpace {
            guard s.first == " " else { return "" }       // model glued text to the previous word
            s.removeFirst()
        }
        if let nl = s.firstIndex(where: \.isNewline) { s = String(s[..<nl]) }
        // cut after the first sentence end
        var out = ""
        var ended = false
        for ch in s {
            out.append(ch)
            if ".!?…".contains(ch) { ended = true; break }
        }
        if !ended, let sp = out.lastIndex(of: " ") {
            out = String(out[..<sp])                      // drop possibly unfinished last word
        }
        while let l = out.last, l == " " || l == "," || l == ";" || l == ":" || l == "—" || l == "-" { out.removeLast() }
        if out.count > 120 { out = String(out.prefix(120)) }
        guard out.contains(where: \.isLetter) || out.contains(where: \.isNumber) else { return "" }
        return out
    }

    // MARK: Ghost text

    private func show(_ s: String) {
        suggestion = s
        layout()
        panel.orderFrontRegardless()
    }

    private func reposition() {
        guard !suggestion.isEmpty else { return }
        guard let ctx = readContext() else { hide(); return }
        caret = ctx.caret
        caretIsChar = ctx.caretIsChar
        layout()
    }

    private func layout() {
        let h = max(10, caret.height)
        let fontSize = max(9, min(40, (h * 0.78).rounded()))
        label.font = NSFont.systemFont(ofSize: fontSize)
        label.stringValue = suggestion
        let size = label.fittingSize
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let x = caretIsChar ? caret.maxX : caret.minX + 1
        // vertically center the label on the caret line
        let midY = primaryH - caret.midY
        let frame = NSRect(x: x + 1, y: (midY - size.height / 2).rounded(), width: size.width + 4, height: size.height)
        panel.setFrame(frame, display: true)
        label.frame = NSRect(origin: .zero, size: frame.size)
    }
}
