import AppKit
import ApplicationServices

/// Reads the meaningful text above the input field (the conversation / letter / page the user replies to).
/// Skips menus, toolbars, buttons, sidebars and short UI labels. Processed in memory only, never stored.
final class WindowContext {
    static let shared = WindowContext()
    private let queue = DispatchQueue(label: "exokey.windowctx", qos: .userInitiated)
    /// Last context per app: switching between apps no longer leaves the field without its conversation
    /// while a new read (an OCR can take a second) is running.
    private var cache: [pid_t: (text: String, title: String, at: Date, ocr: Bool)] = [:]
    private var busy = false
    private let lock = NSLock()

    /// Latest context for the app (up to 10 minutes old — a conversation rarely changes faster than that).
    func context(for pid: pid_t) -> (text: String, title: String) {
        lock.lock(); defer { lock.unlock() }
        guard let c = cache[pid], Date().timeIntervalSince(c.at) < 600 else { return ("", "") }
        return (c.text, c.title)
    }

    func refresh(maxAge: TimeInterval = 8) {
        guard Settings.shared.aiWindowContext, let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        lock.lock()
        let fresh = cache[pid].map { Date().timeIntervalSince($0.at) < ($0.ocr ? max(maxAge, 20) : maxAge) } ?? false
        if fresh || busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async { [weak self] in
            let r = Self.collect(pid: pid)
            guard let self = self else { return }
            self.lock.lock()
            // keep the previous text if this read found nothing (e.g. a menu was open)
            if !r.text.isEmpty || self.cache[pid] == nil { self.cache[pid] = (r.text, r.title, Date(), Self.lastWasOCR) }
            else { self.cache[pid]?.at = Date() }
            if self.cache.count > 20, let oldest = self.cache.min(by: { $0.value.at < $1.value.at })?.key { self.cache[oldest] = nil }
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

    private struct Piece { let text: String; let y: CGFloat; let minX: CGFloat; let maxX: CGFloat }

    static func collect(pid: pid_t) -> (text: String, title: String) {
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
        var usedOCR = false
        var visited = 0
        let deadline = Date().addingTimeInterval(0.2)

        // Only the part of the window above the field and in its column is read: whole subtrees outside it
        // (sidebars, toolbars, the rest of a long page) are skipped without asking the app about their contents.
        // Reading everything made busy pages (Gmail in a browser) and ExoKey use a lot of CPU.
        let area: CGRect? = column.map { CGRect(x: $0.minX - 80, y: -100_000, width: $0.width + 160, height: 100_000 + $0.minY + 4) }
        func walk(_ e: AXUIElement, depth: Int) {
            guard visited < 2500, depth < 60, Date() < deadline else { return }
            visited += 1
            if let f = focused, CFEqual(f, e) { return }
            let role = attr(e, kAXRoleAttribute) as? String ?? ""
            if skipRoles.contains(role) { return }
            if depth > 2, let a = area, let fr = frame(e), fr.width > 0, fr.height > 0, !fr.intersects(a) { return }
            if role == kAXStaticTextRole as String || role == kAXTextAreaRole as String || role == "AXHeading" {
                if let v = attr(e, kAXValueAttribute) as? String {
                    let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty, let fr = frame(e), keep(fr, column: column) {
                        pieces.append(Piece(text: t, y: fr.minY, minX: fr.minX, maxX: fr.maxX))
                    }
                }
                if role == kAXStaticTextRole as String { return }
            }
            guard let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
            for k in kids { walk(k, depth: depth + 1) }
        }
        walk(win, depth: 0)

        // Nothing readable through Accessibility (Telegram, WeChat...): read the window like a person — screenshot + OCR
        let axChars = pieces.reduce(0) { $0 + $1.text.count }
        if axChars < 150 {
            if let ocr = ScreenText.recognize(pid: pid, near: column) {
                let kept = ocr.filter { keep($0.rect, column: column) }
                if kept.reduce(0, { $0 + $1.text.count }) > axChars {
                    pieces = kept.map { Piece(text: $0.text, y: $0.rect.minY, minX: $0.rect.minX, maxX: $0.rect.maxX) }
                    usedOCR = true
                }
            } else {
                ScreenText.requestOnce()
            }
        }

        // Join fragments of the same line, drop UI labels, keep reading order.
        pieces.sort { $0.y < $1.y }
        struct Line { var text: String; var minX: CGFloat; var maxX: CGFloat }
        var lines: [Line] = []
        var lastY: CGFloat = -1000
        for p in pieces {
            if abs(p.y - lastY) < 4, !lines.isEmpty {
                lines[lines.count - 1].text += " " + p.text
                lines[lines.count - 1].minX = min(lines[lines.count - 1].minX, p.minX)
                lines[lines.count - 1].maxX = max(lines[lines.count - 1].maxX, p.maxX)
            } else {
                lines.append(Line(text: p.text, minX: p.minX, maxX: p.maxX))
            }
            lastY = p.y
        }
        // message times ("9:52 PM", "21:52") are noise for the model
        let time = try? NSRegularExpression(pattern: "\\s*\\b\\d{1,2}:\\d{2}(\\s?[AaPp][Mm])?\\s*$")
        for i in lines.indices {
            let t = lines[i].text
            lines[i].text = time?.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "") ?? t
        }
        lines = lines.filter { isMeaningful($0.text) }
        // Chats: my messages are on the right, the other side's on the left — label them so the model
        // knows whose words are whose (only when both sides are present).
        enum Side { case me, them, none }
        func side(_ l: Line) -> Side {
            guard let c = column, c.width > 100 else { return .none }
            let w = c.width
            if l.minX > c.minX + w * 0.25 && l.maxX > c.maxX - w * 0.2 { return .me }
            if l.minX < c.minX + w * 0.2 && l.maxX < c.maxX - w * 0.2 { return .them }
            return .none
        }
        let sides = lines.map(side)
        let chat = sides.contains(.me) && sides.contains(.them)
        var dedup: [String] = []
        var prevSide: Side = .none
        for (l, sd) in zip(lines, sides) {
            var t = l.text
            if chat, sd != .none, sd != prevSide { t = (sd == .me ? "Me: " : "Them: ") + t }
            if chat, sd != .none { prevSide = sd }
            if dedup.last != t { dedup.append(t) }
        }
        // nearest to the field = most relevant: keep the end
        var out = ""
        for l in dedup.reversed() {
            if out.count + l.count > 2500 { break }
            out = l + "\n" + out
        }
        if usedOCR { lastWasOCR = true } else { lastWasOCR = false }
        return (out, title)
    }
    /// The last context came from a screenshot (refreshed less often: OCR is heavier).
    static var lastWasOCR = false

    private static func keep(_ fr: CGRect, column: CGRect?) -> Bool {
        guard fr.width > 0, fr.height > 0 else { return false }
        guard let c = column else { return true }
        if fr.minY >= c.minY { return false }                                  // below / beside the field
        let overlap = min(fr.maxX, c.maxX + 60) - max(fr.minX, c.minX - 60)
        return overlap > min(fr.width, c.width) * 0.5                          // same column as the field
    }

    /// Real text, not a label: two words or more (short chat replies count), mostly letters, not a time/date/counter.
    private static func isMeaningful(_ s: String) -> Bool {
        let words = s.split(whereSeparator: { $0.isWhitespace }).count
        guard words >= 2 || s.count >= 12 else { return false }
        let letters = s.filter { $0.isLetter }.count
        return Double(letters) / Double(max(1, s.count)) > 0.5
    }
}
