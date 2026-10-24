import ApplicationServices
import AppKit

/// Detects password-like fields that macOS does not protect with secure input:
/// fields whose label, placeholder, title or description mention a password, PIN or code.
enum FieldGuard {
    private static var lastElement: AXUIElement?
    private static var lastResult = false

    private static let markers = [
        "password", "passwd", "passcode", "pass phrase", "passphrase", "pin", "secret", "otp", "2fa", "one-time", "verification code",
        "пароль", "парол", "пин-код", "пінкод", "пін-код", "пин", "пін", "код подтверждения", "код підтвердження", "секрет",
    ]

    /// True if the focused field looks like a password field. Cached per focused element.
    static func focusedIsSensitive() -> Bool {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.05)
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success,
              let v = f, CFGetTypeID(v) == AXUIElementGetTypeID() else { return false }
        let e = v as! AXUIElement
        if let last = lastElement, CFEqual(last, e) { return lastResult }
        lastElement = e
        lastResult = check(e)
        if lastResult { Log.write("field guard: password-like field skipped") }
        return lastResult
    }

    static func reset() { lastElement = nil }

    private static func str(_ e: AXUIElement, _ a: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func check(_ e: AXUIElement) -> Bool {
        if str(e, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) { return true }
        var texts: [String] = []
        for a in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute,
                  "AXIdentifier", "AXDOMIdentifier", kAXRoleDescriptionAttribute] {
            if let s = str(e, a as String) { texts.append(s) }
        }
        var t: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, kAXTitleUIElementAttribute as CFString, &t) == .success,
           let te = t, CFGetTypeID(te) == AXUIElementGetTypeID() {
            if let s = str(te as! AXUIElement, kAXValueAttribute) { texts.append(s) }
            if let s = str(te as! AXUIElement, kAXTitleAttribute) { texts.append(s) }
        }
        let joined = texts.joined(separator: " ").lowercased()
        guard !joined.isEmpty else { return false }
        // whole-word match so that "spinner" or "opinion" don't count as "pin"
        let words = Set(joined.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }).map(String.init))
        for m in markers {
            if m.contains(" ") { if joined.contains(m) { return true } }
            else if words.contains(m) || (m.count >= 5 && joined.contains(m)) { return true }
        }
        return false
    }
}
