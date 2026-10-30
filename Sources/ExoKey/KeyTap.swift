import AppKit
import CoreGraphics

/// Global keyboard/mouse event tap.
final class KeyTap {
    static let shared = KeyTap()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        // HID level first: we see keys before other apps' global hotkeys take them (e.g. ⌃⌥X)
        var created = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: keyTapCallback, userInfo: nil)
        Log.write("tap level: \(created != nil ? "hid" : "session")")
        if created == nil {
            created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: keyTapCallback, userInfo: nil)
        }
        guard let t = created else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func reenable() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
    }
}

private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        KeyTap.shared.reenable()
        Engine.shared.reset()
        return Unmanaged.passUnretained(event)
    case .keyDown:
        if Injector.isOwn(event) { return Unmanaged.passUnretained(event) }
        if Engine.shared.keyDown(event) == .swallow {
            if !Injector.lastWasAccept { DispatchQueue.main.async { Predictor.shared.keyTyped(code: -1, typed: nil) } }
            Injector.lastWasAccept = false
            return nil
        }
        if event.flags.intersection([.maskCommand, .maskControl]).isEmpty {
            // at HID level the event has no text yet: take the character from the current layout
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let ks = KeyStroke(code: UInt16(code), shift: event.flags.contains(.maskShift), caps: event.flags.contains(.maskAlphaShift))
            let typed = LayoutManager.shared.current?.char(ks)
            let nav: Set<Int64> = [51, 53, 115, 116, 117, 119, 121, 123, 124, 125, 126, 36, 76, 48]
            DispatchQueue.main.async {
                if code == 36 || code == 76 { Predictor.shared.messageSent() }
                if nav.contains(code) && code != 51 { Predictor.shared.hide(); return }
                Predictor.shared.keyTyped(code: code, typed: code == 51 ? nil : typed)
                LayoutBadge.shared.keyTyped()
            }
        } else {
            Predictor.shared.hide()
        }
        return Unmanaged.passUnretained(event)
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
        Engine.shared.reset()
        FieldGuard.reset()
        Predictor.shared.hide()
        return Unmanaged.passUnretained(event)
    default:
        return Unmanaged.passUnretained(event)
    }
}
