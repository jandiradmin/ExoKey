import AppKit
import ApplicationServices

/// Position of the text caret in the focused field (Accessibility coordinates, top-left origin).
enum CaretLocator {
    static func caretRect() -> CGRect? {
        Predictor.shared.enableAccessibility(for: NSWorkspace.shared.frontmostApplication)
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.15)
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success,
              let v = f, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let e = v as! AXUIElement

        var rr: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, &rr) == .success,
           let x = rr, CFGetTypeID(x) == AXValueGetTypeID() {
            var range = CFRange()
            AXValueGetValue(x as! AXValue, .cfRange, &range)
            let loc = range.location
            if loc > 0, previousChar(e, loc) != "\n", let r = bounds(e, CFRange(location: loc - 1, length: 1)) {
                return CGRect(x: r.maxX, y: r.minY, width: 1, height: r.height)
            }
            if let r = bounds(e, CFRange(location: loc, length: 0)) {
                return CGRect(x: r.minX, y: r.minY, width: 1, height: r.height)
            }
        }
        // Chrome / Electron
        var tm: CFTypeRef?
        if AXUIElementCopyAttributeValue(e, "AXSelectedTextMarkerRange" as CFString, &tm) == .success, let tmr = tm {
            var b: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(e, "AXBoundsForTextMarkerRange" as CFString, tmr, &b) == .success,
               let r = rect(b) {
                return CGRect(x: r.minX, y: r.minY, width: 1, height: r.height)
            }
        }
        return nil
    }

    /// Frame of the focused input field (fallback when the caret can't be located).
    static func fieldRect() -> CGRect? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.15)
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success,
              let v = f, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let e = v as! AXUIElement
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size) == .success,
              let pv = pos, let sv = size else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        guard s.width > 20, s.height > 8, s.height < 600 else { return nil }
        return CGRect(origin: p, size: s)
    }

    private static func previousChar(_ e: AXUIElement, _ loc: Int) -> String? {
        var r = CFRange(location: loc - 1, length: 1)
        guard let rv = AXValueCreate(.cfRange, &r) else { return nil }
        var s: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXStringForRangeParameterizedAttribute as CFString, rv, &s) == .success else { return nil }
        return s as? String
    }

    private static func bounds(_ e: AXUIElement, _ range: CFRange) -> CGRect? {
        var r = range
        guard let rv = AXValueCreate(.cfRange, &r) else { return nil }
        var b: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &b) == .success else { return nil }
        return rect(b)
    }

    private static func rect(_ v: CFTypeRef?) -> CGRect? {
        guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &r), r.height > 2, r.height < 200 else { return nil }
        return r
    }
}
