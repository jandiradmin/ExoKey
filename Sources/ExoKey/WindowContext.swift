import AppKit
import ApplicationServices

/// Reads visible text of the focused window (e.g. the conversation above the input field),
/// so suggestions follow the context of the dialog. Processed in memory only, never stored.
final class WindowContext {
    static let shared = WindowContext()
    private let queue = DispatchQueue(label: "exokey.windowctx", qos: .userInitiated)
    private var cache: (pid: pid_t, text: String, at: Date)?
    private var busy = false
    private let lock = NSLock()

    /// Latest window text for the frontmost app (may be a couple of seconds old).
    func text(for pid: pid_t) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let c = cache, c.pid == pid, Date().timeIntervalSince(c.at) < 30 else { return "" }
        return c.text
    }

    /// Refreshes in the background if older than `maxAge` seconds.
    func refresh(maxAge: TimeInterval = 2) {
        guard Settings.shared.aiWindowContext, let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        lock.lock()
        let fresh = cache.map { $0.pid == pid && Date().timeIntervalSince($0.at) < maxAge } ?? false
        if fresh || busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async { [weak self] in
            let t = Self.collect(pid: pid)
            guard let self = self else { return }
            self.lock.lock()
            self.cache = (pid, t, Date())
            self.busy = false
            self.lock.unlock()
        }
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private static func collect(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let w = attr(app, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() else { return "" }
        let focused = attr(app, kAXFocusedUIElementAttribute)
        var parts: [String] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(0.4)
        var lastPart = ""

        func walk(_ e: AXUIElement, depth: Int) {
            guard visited < 6000, depth < 60, Date() < deadline else { return }
            visited += 1
            if let f = focused, CFEqual(f, e) { return }       // skip the input field itself
            let role = attr(e, kAXRoleAttribute) as? String ?? ""
            if role == kAXStaticTextRole as String || role == kAXTextAreaRole as String || role == "AXHeading" {
                if let v = attr(e, kAXValueAttribute) as? String {
                    let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty, t != lastPart { parts.append(t); lastPart = t }
                }
                if role == kAXStaticTextRole as String { return }
            }
            if role == kAXMenuBarRole as String || role == kAXToolbarRole as String || role == kAXImageRole as String { return }
            guard let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
            for k in kids { walk(k, depth: depth + 1) }
        }
        walk(w as! AXUIElement, depth: 0)
        // keep the end of the window text (most recent messages)
        var out = ""
        for p in parts.reversed() {
            if out.count + p.count > 2500 { break }
            out = p + "\n" + out
        }
        return out
    }
}
