import AppKit

extension Notification.Name {
    static let exoLayoutChanged = Notification.Name("ExoKeyLayoutChanged")
}

/// Small colored EN / RU / UK label under the text caret.
final class LayoutBadge {
    static let shared = LayoutBadge()
    private let panel: NSPanel
    private let box: NSView
    private let label: NSTextField
    private var hideWork: DispatchWorkItem?
    private var lastShown = Date.distantPast
    private let size = NSSize(width: 24, height: 15)

    private init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        box = NSView(frame: NSRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.cornerRadius = 4
        label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 9.5, weight: .bold)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 1, width: size.width, height: 12)
        box.addSubview(label)
        panel.contentView = box
    }

    static func colors(_ l: Lang) -> (bg: NSColor, fg: NSColor) {
        switch l {
        case .en: return (NSColor(srgbRed: 0.20, green: 0.48, blue: 0.95, alpha: 1), .white)
        case .uk: return (NSColor(srgbRed: 0.98, green: 0.80, blue: 0.18, alpha: 1), .black)
        case .ru: return (NSColor(srgbRed: 0.58, green: 0.33, blue: 0.87, alpha: 1), .white)
        }
    }

    /// Layout changed (by the user or by ExoKey), or another app became active.
    func flash() {
        guard Settings.shared.badgeMode >= 1 else { return }
        show(seconds: 1.3, mouseFallback: true)
    }

    /// Mode "always": follows the caret while typing.
    func keyTyped() {
        guard Settings.shared.badgeMode == 2 else { return }
        if panel.isVisible, Date().timeIntervalSince(lastShown) < 0.15 { scheduleHide(1.5); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { self.show(seconds: 1.5, mouseFallback: false) }
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }

    private func show(seconds: TimeInterval, mouseFallback: Bool) {
        guard let lang = LayoutManager.shared.currentLang, !IsSecureEventInputEnabledSafe() else { hide(); return }
        let c = Self.colors(lang)
        box.layer?.backgroundColor = c.bg.cgColor
        label.textColor = c.fg
        label.stringValue = lang.short
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let origin: NSPoint
        if let r = CaretLocator.caretRect() {
            origin = NSPoint(x: r.minX - 2, y: primaryH - r.maxY - size.height - 2)
        } else if mouseFallback {
            let m = NSEvent.mouseLocation
            origin = NSPoint(x: m.x + 12, y: m.y - size.height - 14)
        } else {
            hide(); return
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        lastShown = Date()
        scheduleHide(seconds)
    }

    private func scheduleHide(_ s: TimeInterval) {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }
}

import Carbon
private func IsSecureEventInputEnabledSafe() -> Bool { IsSecureEventInputEnabled() }
