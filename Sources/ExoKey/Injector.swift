import CoreGraphics

/// Posts synthetic keyboard events. All of them carry a tag so our own tap ignores them.
enum Injector {
    static let tag: Int64 = 0x4558_4F4B // "EXOK"
    static var lastWasAccept = false
    private static let source = CGEventSource(stateID: .privateState)

    static func isOwn(_ e: CGEvent) -> Bool { e.getIntegerValueField(.eventSourceUserData) == tag }

    private static func post(_ e: CGEvent) {
        e.setIntegerValueField(.eventSourceUserData, value: tag)
        e.post(tap: .cghidEventTap)
    }

    static func key(_ code: CGKeyCode, count: Int = 1) {
        for _ in 0..<max(0, count) {
            guard let d = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                  let u = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { continue }
            d.flags = []; u.flags = []
            post(d); post(u)
        }
    }

    static func backspaces(_ n: Int) { key(51, count: n) }

    static func type(_ s: String) {
        let units = Array(s.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            i += chunk.count
            guard let d = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let u = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            d.flags = []; u.flags = []
            d.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            u.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            post(d); post(u)
        }
    }

    /// Re-post a copy of a swallowed key event (e.g. space after a corrected word).
    static func repost(_ e: CGEvent) {
        guard let c = e.copy() else { return }
        post(c)
    }
}
