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
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: keyTapCallback, userInfo: nil) else { return false }
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
        if Engine.shared.keyDown(event) == .swallow { return nil }
        if event.flags.intersection([.maskCommand, .maskControl]).isEmpty {
            DispatchQueue.main.async { Predictor.shared.keyTyped() }
        }
        return Unmanaged.passUnretained(event)
    case .leftMouseDown, .rightMouseDown, .otherMouseDown:
        Engine.shared.reset()
        Predictor.shared.hide()
        return Unmanaged.passUnretained(event)
    default:
        return Unmanaged.passUnretained(event)
    }
}
