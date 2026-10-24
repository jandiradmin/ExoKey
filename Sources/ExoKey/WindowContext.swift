import AppKit
import ApplicationServices

/// Reads the meaningful text above the input field (the conversation / letter / page the user replies to).
/// Skips menus, toolbars, buttons, sidebars and short UI labels. Processed in memory only, never stored.
final class WindowContext {
    static let shared = WindowContext()
    private let queue = DispatchQueue(label: "exokey.windowctx", qos: .userInitiated)
    private var cache: (pid: pid_t, text: String, title: String, at: Date)?
    private var busy = false
    private let lock = NSLock()

    /// Latest context for the frontmost app (may be a couple of seconds old).
    func context(for pid: pid_t) -> (text: String, title: String) {
        lock.lock(); defer { lock.unlock() }
        guard let c = cache, c.pid == pid, Date().timeIntervalSince(c.at) < 30 else { return ("", "") }
        return (c.text, c.title)
    }

    func refresh(maxAge: TimeInterval = 2) {
        guard Settings.shared.aiWindowContext, let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        lock.lock()
        let fresh = cache.map { $0.pid == pid && Date().timeIntervalSince($0.at) < maxAge } ?? false
        if fresh || busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async { [weak self] in
            let r = Self.collect(pid: pid)
            guard let self = self else { return }
            self.lock.lock()
            self.cache = (pid, r.text, r.title, Date())
            self.busy = false
            self.lock.unlock()
        }
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    private static let skipRoles: Set<String> = [
        kAXMenuBarRole as String, kAXMenuRole as String, kAXMenuItemRole as String, kAXToolbarRole as String,
        kAXButtonRole as String, kAXPopUpButtonRole as String, kAXCheckBoxRole as String, kAXRadioButtonRole as String,
        kAXImageRole as String, kAXTabGroupRole as String, kAXScrollBarRole as String, kAXComboBoxRole as String,
        kAXTextFieldRole as String, kAXSliderRole as String, "AXSearchField", "AXDisclosureTriangle",
    ]

    private struct Piece { let text: String; let y: CGFloat }

    private static func collect(pid: pid_t) -> (text: String, title: String) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let w = attr(app, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() else { return ("", "") }
        let win = w as! AXUIElement
        let title = attr(win, kAXTitleAttribute) as? String ?? ""
        let focused = attr(app, kAXFocusedUIElementAttribute)
        // The column of the input field: text must be above it and overlap it horizontally (no sidebars).
        var column: CGRect?
        if let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID(), let fr = frame(f as! AXUIElement), fr.width > 40 {
            column = fr
        }
        var pieces: [Piece] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(0.4)

        func walk(_ e: AXUIElement, depth: Int) {
            guard visited < 8000, depth < 70, Date() < deadline else { return }
            visited += 1
            if let f = focused, CFEqual(f, e) { return }
            let role = attr(e, kAXRoleAttribute) as? String ?? ""
            if skipRoles.contains(role) { return }
            if role == kAXStaticTextRole as String || role == kAXTextAreaRole as String || role == "AXHeading" {
                if let v = attr(e, kAXValueAttribute) as? String {
                    let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty, let fr = frame(e), keep(fr, column: column) {
                        pieces.append(Piece(text: t, y: fr.minY))
                    }
                }
                if role == kAXStaticTextRole as String { return }
            }
            guard let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
            for k in kids { walk(k, depth: depth + 1) }
        }
        walk(win, depth: 0)

        // Join fragments of the same line, drop UI labels, keep reading order.
        pieces.sort { $0.y < $1.y }
        var lines: [String] = []
        var lastY: CGFloat = -1000
        for p in pieces {
            if abs(p.y - lastY) < 4, let l = lines.last { lines[lines.count - 1] = l + " " + p.text }
            else { lines.append(p.text) }
            lastY = p.y
        }
        lines = lines.filter { isMeaningful($0) }
        var dedup: [String] = []
        for l in lines where dedup.last != l { dedup.append(l) }
        // nearest to the field = most relevant: keep the end
        var out = ""
        for l in dedup.reversed() {
            if out.count + l.count > 1800 { break }
            out = l + "\n" + out
        }
        return (out, title)
    }

    private static func keep(_ fr: CGRect, column: CGRect?) -> Bool {
        guard fr.width > 0, fr.height > 0 else { return false }
        guard let c = column else { return true }
        if fr.minY >= c.minY { return false }                                  // below / beside the field
        let overlap = min(fr.maxX, c.maxX + 60) - max(fr.minX, c.minX - 60)
        return overlap > min(fr.width, c.width) * 0.5                          // same column as the field
    }

    /// Real text, not a label: at least 3 words or 20 characters, mostly letters, not a time/date/counter.
    private static func isMeaningful(_ s: String) -> Bool {
        let words = s.split(whereSeparator: { $0.isWhitespace }).count
        guard words >= 3 || s.count >= 20 else { return false }
        let letters = s.filter { $0.isLetter }.count
        return Double(letters) / Double(max(1, s.count)) > 0.5
    }
}
