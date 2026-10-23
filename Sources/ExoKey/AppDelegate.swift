import AppKit
import ApplicationServices
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var permTimer: Timer?
    private var bag: Set<AnyCancellable> = []
    private var settingsWindow: NSWindow?
    private var dictWindow: NSWindow?
    private let settings = Settings.shared

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        _ = UserStore.shared
        _ = LayoutManager.shared
        let engine = Engine.shared
        engine.onStateChange = { [weak self] in self?.updateStatus() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatus()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] n in
            self?.updateExcluded()
            Engine.shared.reset()
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Predictor.shared.hide()
            if Settings.shared.aiEnabled { Predictor.shared.enableAccessibility(for: app) }
            if let id = app?.bundleIdentifier, let raw = Settings.shared.appLayouts[id], let l = Lang(rawValue: raw) {
                LayoutManager.shared.select(l)
                self?.updateStatus()
            }
        }
        settings.$excludedApps.sink { [weak self] _ in DispatchQueue.main.async { self?.updateExcluded() } }.store(in: &bag)
        settings.$enabled.sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatus() } }.store(in: &bag)
        updateExcluded()

        if settings.notifications { Notifier.requestAuthorization() }
        if settings.aiEnabled { AIModel.shared.start() }
        startTapOrAskPermission()
        if !settings.firstRunDone {
            settings.firstRunDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.openSettings() }
        }
    }

    func applicationWillTerminate(_ n: Notification) { AIModel.shared.stop() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    // MARK: Permissions

    private var hasPermissions: Bool { AXIsProcessTrusted() }

    private func startTapOrAskPermission() {
        Log.write("launch: AX=\(AXIsProcessTrusted()) listen=\(CGPreflightListenEventAccess()) post=\(CGPreflightPostEventAccess())")
        if hasPermissions, KeyTap.shared.start() {
            Log.write("tap started")
            updateStatus()
            return
        }
        Log.write("tap not started, asking permissions")
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        showPermissionAlert()
        permTimer?.invalidate()
        permTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self = self else { return }
            if self.hasPermissions, KeyTap.shared.start() {
                Log.write("tap started after permission")
                t.invalidate()
                self.updateStatus()
            }
        }
    }

    private func showPermissionAlert() {
        let a = NSAlert()
        a.messageText = L.t("perm.title")
        a.informativeText = L.t("perm.text")
        a.addButton(withTitle: L.t("perm.open"))
        a.addButton(withTitle: L.t("perm.later"))
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    // MARK: Status

    private func updateExcluded() {
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        Engine.shared.excludedApp = settings.excludedApps.contains(id)
    }

    func updateStatus() {
        guard let b = statusItem?.button else { return }
        let engine = Engine.shared
        var title = engine.statusLang?.short ?? "—"
        if !KeyTap.shared.isRunning { title = "⚠︎ " + title }
        else if !settings.enabled { title = "⏸ " + title }
        else if engine.sleeping { title = "z " + title }
        b.title = title
        b.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        b.toolTip = "ExoKey"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let engine = Engine.shared
        if !KeyTap.shared.isRunning {
            menu.addItem(item(L.t("menu.permissions"), #selector(askPermissions)))
            menu.addItem(.separator())
        }
        let en = item(L.t("menu.enabled"), #selector(toggleEnabled), key: settings.hkPause)
        en.state = settings.enabled ? .on : .off
        menu.addItem(en)
        if settings.enabled && engine.sleeping {
            let s = NSMenuItem(title: L.t("menu.sleep"), action: nil, keyEquivalent: "")
            s.isEnabled = false
            menu.addItem(s)
        }
        menu.addItem(item(L.t("menu.undo"), #selector(undo), key: settings.hkUndo))
        menu.addItem(item(L.t("menu.convert"), #selector(convert), key: settings.hkConvert))
        menu.addItem(.separator())
        if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
           id != Bundle.main.bundleIdentifier {
            let name = app.localizedName ?? id
            let sub = NSMenu()
            let current = settings.appLayouts[id]
            let none = NSMenuItem(title: L.t("menu.appLayout.none"), action: #selector(setAppLayout(_:)), keyEquivalent: "")
            none.target = self
            none.representedObject = [id, ""]
            none.state = current == nil ? .on : .off
            sub.addItem(none)
            for l in Lang.allCases where LayoutManager.shared.layouts[l] != nil {
                let it = NSMenuItem(title: L.langName(l), action: #selector(setAppLayout(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = [id, l.rawValue]
                it.state = current == l.rawValue ? .on : .off
                sub.addItem(it)
            }
            let parent = NSMenuItem(title: L.t("menu.appLayout", name), action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }
        menu.addItem(item(L.t("menu.dictionary"), #selector(openDictionary)))
        menu.addItem(item(L.t("menu.settings"), #selector(openSettings)))
        let au = item(L.t("menu.autostart"), #selector(toggleAutostart))
        au.state = settings.autostart ? .on : .off
        menu.addItem(au)
        menu.addItem(.separator())
        menu.addItem(item(L.t("menu.about"), #selector(about)))
        menu.addItem(item(L.t("menu.quit"), #selector(quit)))
    }

    private func item(_ title: String, _ sel: Selector, key: Hotkey? = nil) -> NSMenuItem {
        let t = key.map { "\(title)    \($0.display)" } ?? title
        let i = NSMenuItem(title: t, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func setAppLayout(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? [String], v.count == 2 else { return }
        if v[1].isEmpty {
            settings.appLayouts[v[0]] = nil
        } else {
            settings.appLayouts[v[0]] = v[1]
            if let l = Lang(rawValue: v[1]) { LayoutManager.shared.select(l); updateStatus() }
        }
    }

    @objc private func askPermissions() { startTapOrAskPermission() }
    @objc private func toggleEnabled() { settings.enabled.toggle(); Engine.shared.reset(); updateStatus() }
    @objc private func toggleAutostart() { settings.autostart.toggle() }
    @objc private func undo() { Engine.shared.undo() }
    @objc private func convert() { Engine.shared.convert() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "ExoKey",
            .credits: NSAttributedString(string: "Layout switcher for English, Russian, Ukrainian.\nDictionaries: FrequencyWords (CC BY-SA 4.0), LibreOffice hunspell dictionaries."),
        ])
    }

    @objc private func openSettings() {
        settingsWindow = show(settingsWindow, title: L.t("set.title"), view: SettingsView(), size: NSSize(width: 560, height: 640))
    }

    @objc private func openDictionary() {
        dictWindow = show(dictWindow, title: L.t("dict.title"), view: DictionaryView(), size: NSSize(width: 760, height: 560))
    }

    private func show<V: View>(_ existing: NSWindow?, title: String, view: V, size: NSSize) -> NSWindow {
        if let w = existing {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return w
        }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentViewController = NSHostingController(rootView: view.preferredColorScheme(.dark))
        w.setContentSize(size)
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        return w
    }
}
