import AppKit
import ApplicationServices

/// Hotkeys that work on the selected text: change layout (⌃⌥X), change case (⌃⌥R).
enum Selection {
    /// Selected text via Accessibility: nil = the app doesn't tell, "" = nothing selected.
    static func axSelected() -> String? {
        Predictor.shared.enableAccessibility(for: NSWorkspace.shared.frontmostApplication)
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.15)
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success,
              let v = f, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        var t: CFTypeRef?
        guard AXUIElementCopyAttributeValue(v as! AXUIElement, kAXSelectedTextAttribute as CFString, &t) == .success
        else { return nil }
        return t as? String
    }

    /// Selection for ⌃⌥X: Accessibility only (a ⌘C probe could grab a whole line in some editors).
    static func read(_ done: @escaping (String?) -> Void) {
        done(axSelected())
    }

    /// Selection for explicit "work on selection" hotkeys: Accessibility, then a ⌘C probe; the clipboard is restored.
    static func readOrCopy(_ done: @escaping (String?) -> Void) {
        if let s = axSelected(), !s.isEmpty { done(s); return }
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let n = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { n.setData(d, forType: t) } }
            return n
        }
        let before = pb.changeCount
        Injector.key(8, flags: .maskCommand)   // ⌘C
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            var text: String?
            if pb.changeCount != before {
                text = pb.string(forType: .string)
                pb.clearContents()
                if !saved.isEmpty { pb.writeObjects(saved) }
            }
            // editors copy the whole line when nothing is selected
            if let s = text, s.hasSuffix("\n") { text = nil }
            done(text)
        }
    }

    // MARK: layout

    /// Returns false when nothing could be converted (then the caller converts the last word instead).
    @discardableResult
    static func convertLayout(_ s: String) -> Bool {
        let lm = LayoutManager.shared
        let cyr = s.unicodeScalars.filter { (0x400...0x4FF).contains($0.value) }.count
        let lat = s.unicodeScalars.filter { $0.isASCII && CharacterSet.letters.contains($0) }.count
        let from: Lang
        var targets: [Lang]
        if cyr > lat {
            from = s.lowercased().contains(where: { "іїєґ".contains($0) }) && lm.layouts[.uk] != nil ? .uk
                 : (lm.layouts[.ru] != nil ? .ru : .uk)
            targets = [.en]
        } else {
            from = .en
            targets = [Lang.ru, .uk].filter { lm.layouts[$0] != nil }
        }
        guard let fromL = lm.layouts[from] else { return false }
        var best: (lang: Lang, text: String, score: Int)?
        for t in targets {
            guard let toL = lm.layouts[t] else { continue }
            var out = ""
            for ch in s {
                let c = String(ch)
                if let ks = fromL.keystroke(for: c), let r = toL.char(ks) { out += r }
                else if let ks = fromL.keystroke(for: c.lowercased()), let r = toL.char(ks) { out += r.uppercased() }
                else { out += c }
            }
            let words = out.lowercased().split { !$0.isLetter && $0 != "'" }
            let score = words.filter { (Engine.shared.dicts[t]?.freq(String($0)) ?? 0) > 0 }.count
            if best == nil || score > best!.score { best = (t, out, score) }
        }
        guard let b = best, b.text != s else { return false }
        Injector.type(b.text)
        lm.select(b.lang)
        Log.write("selection: layout -> \(b.lang.rawValue) (\(s.count) chars)")
        return true
    }

    // MARK: case

    /// aa → AA → Aa → aa
    static func changeCase() {
        readOrCopy { sel in
            guard let s = sel, !s.isEmpty else { Notifier.show(L.t("notif.noSelection")); return }
            let next: String
            if s == s.lowercased() { next = s.uppercased() }
            else if s == s.uppercased() { next = s.prefix(1).uppercased() + s.dropFirst().lowercased() }
            else { next = s.lowercased() }
            Injector.type(next)
            // keep it selected so the hotkey can be pressed again
            if next.count <= 500 { Injector.key(123, flags: .maskShift, count: next.count) }
            Engine.shared.reset()
            Log.write("selection: case (\(s.count) chars)")
        }
    }
}
