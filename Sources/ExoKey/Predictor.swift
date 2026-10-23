import AppKit
import ApplicationServices
import Carbon

/// Next-word suggestions from the local model, shown near the caret. Tab accepts.
final class Predictor {
    static let shared = Predictor()

    private var timer: Timer?
    private var generation = 0
    private var suggestion = ""
    private let panel: NSPanel
    private let label: NSTextField

    var isVisible: Bool { panel.isVisible && !suggestion.isEmpty }

    private init() {
        label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = NSColor(white: 0.85, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 24),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .darkAqua)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
        panel.contentView = bg
    }

    // MARK: Triggers

    /// Called after a key was delivered to the app.
    func keyTyped() {
        let s = Settings.shared
        guard s.aiEnabled, AIModel.shared.state == .ready, s.enabled, !Engine.shared.excludedApp,
              !IsSecureEventInputEnabled() else { return }
        timer?.invalidate()
        generation += 1
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in self?.request() }
    }

    func hide() {
        timer?.invalidate()
        generation += 1
        suggestion = ""
        panel.orderOut(nil)
    }

    func accept() {
        let s = suggestion
        hide()
        guard !s.isEmpty else { return }
        Injector.type(s)
        Log.write("ai: accepted")
        keyTyped()
    }

    // MARK: Context

    private struct Ctx { let text: String; let caret: NSRect? }

    private func readContext() -> Ctx? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        let e = el as! AXUIElement
        var sub: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, kAXSubroleAttribute as CFString, &sub) == .success,
           (sub as? String) == (kAXSecureTextFieldSubrole as String) { return nil }
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &val) == .success,
              let full = val as? String else { return nil }
        var rangeRef: CFTypeRef?
        var range = CFRange(location: (full as NSString).length, length: 0)
        if AXUIElementCopyAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() {
            AXValueGetValue(rv as! AXValue, .cfRange, &range)
        }
        guard range.length == 0 else { return nil }  // something selected
        let ns = full as NSString
        let loc = min(range.location, ns.length)
        // caret must be at end of line (nothing but whitespace after it on the same line)
        let after = ns.substring(from: loc)
        if let firstLine = after.split(separator: "\n", omittingEmptySubsequences: false).first,
           !firstLine.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        let start = max(0, loc - 1500)
        let text = ns.substring(with: NSRange(location: start, length: loc - start))

        var caret: NSRect?
        var r = CFRange(location: max(0, loc - 1), length: loc > 0 ? 1 : 0)
        if let rv = AXValueCreate(.cfRange, &r) {
            var b: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(e, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &b) == .success,
               let bv = b, CFGetTypeID(bv) == AXValueGetTypeID() {
                var rect = CGRect.zero
                AXValueGetValue(bv as! AXValue, .cgRect, &rect)
                if rect.width > 0 || rect.height > 0 { caret = rect }
            }
        }
        return Ctx(text: text, caret: caret)
    }

    // MARK: Request

    private func request() {
        let gen = generation
        guard let ctx = readContext(), let caret = ctx.caret else { return }
        let text = ctx.text
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3,
              let lastChar = text.last, !lastChar.isNewline else { return }
        // models predict better without a trailing space; the completion then starts with " word"
        var prompt = text
        while prompt.last == " " { prompt.removeLast() }
        AIModel.shared.complete(prompt) { [weak self] out in
            guard let self = self, gen == self.generation, let out = out else { return }
            let s = Self.extract(out, midWord: lastChar.isLetter, afterSpace: lastChar == " ")
            guard !s.isEmpty else { return }
            self.show(s, at: caret)
        }
    }

    /// Takes the end of the current word plus one next word (or two words after a space).
    static func extract(_ raw: String, midWord: Bool, afterSpace: Bool) -> String {
        if afterSpace && raw.first != " " { return "" }   // model glued to previous word
        var out = ""
        var words = 0
        var inWord = midWord
        let limit = midWord ? 1 : 2
        for ch in raw {
            if ch.isNewline { break }
            let isW = ch.isLetter || ch.isNumber || ch == "'" || ch == "’" || ch == "-"
            if isW {
                inWord = true
            } else if inWord {
                words += 1
                inWord = false
                if words > limit { break }
                if !(ch == " " || ch == "," ) { break }
            }
            if afterSpace && out.isEmpty && ch == " " { continue }
            out.append(ch)
            if out.count > 40 { break }
        }
        while let l = out.last, l == " " || l == "," { out.removeLast() }
        // skip garbage
        if out.contains(where: { $0.isLetter }) == false { return "" }
        return out
    }

    // MARK: Panel

    private func show(_ s: String, at axRect: CGRect) {
        suggestion = s
        label.stringValue = "\(s)  ⇥"
        label.sizeToFit()
        let w = label.fittingSize.width + 16
        let h: CGFloat = 24
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let x = axRect.maxX + 2
        let y = primaryH - axRect.maxY - h - 2   // below the caret line
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        panel.orderFrontRegardless()
    }
}
