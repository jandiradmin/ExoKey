import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class HotkeyRecorder: ObservableObject {
    @Published var recording = false
    var monitor: Any?
}

struct HotkeyField: View {
    @Binding var hotkey: Hotkey
    @ObservedObject var rec: HotkeyRecorder

    var body: some View {
        Button(rec.recording ? L.t("hk.press") : hotkey.display) {
            rec.recording ? stop() : start()
        }
        .frame(minWidth: 140)
        .onDisappear { stop() }
    }

    private func start() {
        rec.recording = true
        Engine.shared.recordingHotkey = true
        rec.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil } // Esc cancels
            var f = CGEventFlags()
            if e.modifierFlags.contains(.command) { f.insert(.maskCommand) }
            if e.modifierFlags.contains(.option) { f.insert(.maskAlternate) }
            if e.modifierFlags.contains(.control) { f.insert(.maskControl) }
            if e.modifierFlags.contains(.shift) { f.insert(.maskShift) }
            let isF = KeyNames.special[e.keyCode]?.hasPrefix("F") ?? false
            guard f.contains(.maskCommand) || f.contains(.maskAlternate) || f.contains(.maskControl) || isF else { return nil }
            hotkey = Hotkey(keyCode: e.keyCode, mods: f.rawValue)
            stop()
            return nil
        }
    }

    private func stop() {
        rec.recording = false
        Engine.shared.recordingHotkey = false
        if let m = rec.monitor { NSEvent.removeMonitor(m) }
        rec.monitor = nil
    }
}

final class SettingsUIState: ObservableObject {
    @Published var autostart = Settings.shared.autostart
    @Published var confirmDelete = false
    @Published var message = ""
    let recUndo = HotkeyRecorder()
    let recConvert = HotkeyRecorder()
    let recPause = HotkeyRecorder()
}

struct SettingsView: View {
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var ui = SettingsUIState()

    var body: some View {
        Form {
            Section(L.t("set.general")) {
                Toggle(L.t("menu.enabled"), isOn: $s.enabled)
                Toggle(L.t("set.autostart"), isOn: $ui.autostart)
                    .onChange(of: ui.autostart) { s.autostart = $0 }
                Picker(L.t("set.uiLang"), selection: $s.uiLang) {
                    Text(L.t("set.uiLang.system")).tag(UILang.system)
                    Text("Русский").tag(UILang.ru)
                    Text("Українська").tag(UILang.uk)
                    Text("English").tag(UILang.en)
                }
                Toggle(L.t("set.notifications"), isOn: $s.notifications)
            }
            Section(L.t("set.languages")) {
                ForEach(Lang.allCases) { l in
                    Toggle(L.langName(l), isOn: Binding(
                        get: { s.activeLangs.contains(l) },
                        set: { on in if on { s.activeLangs.insert(l) } else { s.activeLangs.remove(l) } }))
                }
                Picker(L.t("set.minLetters"), selection: $s.minLetters) {
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                .pickerStyle(.segmented)
            }
            Section(L.t("set.learning")) {
                Toggle(L.t("set.learning"), isOn: $s.learning)
                Picker(L.t("set.addMode"), selection: $s.addMode) {
                    Text(L.t("set.addMode.confirm")).tag(AddMode.confirm)
                    Text(L.t("set.addMode.repeated")).tag(AddMode.repeated)
                    Text(L.t("set.addMode.immediate")).tag(AddMode.immediate)
                }
                Stepper("\(L.t("set.repeatCount")): \(s.repeatCount)", value: $s.repeatCount, in: 2...10)
                    .disabled(s.addMode != .repeated)
                Stepper("\(L.t("set.undos")): \(s.undosToException)", value: $s.undosToException, in: 1...10)
            }
            Section(L.t("set.hotkeys")) {
                LabeledContent(L.t("hk.undo")) { HotkeyField(hotkey: $s.hkUndo, rec: ui.recUndo) }
                LabeledContent(L.t("hk.convert")) { HotkeyField(hotkey: $s.hkConvert, rec: ui.recConvert) }
                LabeledContent(L.t("hk.pause")) { HotkeyField(hotkey: $s.hkPause, rec: ui.recPause) }
            }
            Section(L.t("set.excluded")) {
                ForEach(s.excludedApps, id: \.self) { id in
                    HStack {
                        Text(appName(id))
                        Text(id).foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        Button(L.t("set.remove")) { s.excludedApps.removeAll { $0 == id } }
                    }
                }
                Button(L.t("set.add")) { addApp() }
            }
            Section(L.t("set.data")) {
                HStack {
                    Button(L.t("set.export")) { exportJSON() }
                    Button(L.t("set.import")) { importJSON() }
                    Button(L.t("set.backup")) { backup() }
                    Button(L.t("set.restore")) { restore() }
                }
                HStack {
                    Button(L.t("set.resetLearning")) { UserStore.shared.resetLearning(); ui.message = "✓" }
                    Button(L.t("set.deleteAll"), role: .destructive) { ui.confirmDelete = true }
                }
                if !ui.message.isEmpty { Text(ui.message).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 560)
        .confirmationDialog(L.t("set.deleteAll.confirm"), isPresented: $ui.confirmDelete) {
            Button(L.t("dict.delete"), role: .destructive) { UserStore.shared.deleteAll(); ui.message = "✓" }
        }
    }

    private func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func addApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        for u in p.urls {
            if let id = Bundle(url: u)?.bundleIdentifier, !s.excludedApps.contains(id) { s.excludedApps.append(id) }
        }
    }

    private func exportJSON() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "exokey-dictionary.json"
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try UserStore.shared.exportJSON(to: u); ui.message = "✓ \(u.lastPathComponent)" } catch { ui.message = error.localizedDescription }
    }

    private func importJSON() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let u = p.url else { return }
        do { let n = try UserStore.shared.importJSON(from: u); ui.message = "✓ \(n)" } catch { ui.message = error.localizedDescription }
    }

    private func backup() {
        let p = NSSavePanel()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        p.nameFieldStringValue = "exokey-backup-\(f.string(from: Date())).sqlite"
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try UserStore.shared.backup(to: u); ui.message = "✓ \(u.lastPathComponent)" } catch { ui.message = error.localizedDescription }
    }

    private func restore() {
        let p = NSOpenPanel()
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try UserStore.shared.restore(from: u); ui.message = "✓" } catch { ui.message = error.localizedDescription }
    }
}
