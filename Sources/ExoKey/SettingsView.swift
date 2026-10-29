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
    var allowPlain = false

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
            if e.keyCode == 53 && !allowPlain { stop(); return nil } // Esc cancels
            var f = CGEventFlags()
            if e.modifierFlags.contains(.command) { f.insert(.maskCommand) }
            if e.modifierFlags.contains(.option) { f.insert(.maskAlternate) }
            if e.modifierFlags.contains(.control) { f.insert(.maskControl) }
            if e.modifierFlags.contains(.shift) { f.insert(.maskShift) }
            let isF = KeyNames.special[e.keyCode]?.hasPrefix("F") ?? false
            guard allowPlain || f.contains(.maskCommand) || f.contains(.maskAlternate) || f.contains(.maskControl) || isF else { return nil }
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

final class AIRecorders {
    static let shared = AIRecorders()
    let word = HotkeyRecorder(), all = HotkeyRecorder(), hide = HotkeyRecorder(), undo = HotkeyRecorder(), toggle = HotkeyRecorder()
}

struct AISection: View {
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var ai = AIModel.shared
    private let rec = AIRecorders.shared

    private var stateText: String {
        switch ai.state {
        case .notInstalled: return L.t("ai.state.notInstalled")
        case .downloading(let p): return "\(L.t("ai.state.downloading")) \(Int(p * 100))%"
        case .installed: return L.t("ai.state.installed")
        case .starting: return L.t("ai.state.starting")
        case .ready: return L.t("ai.state.ready")
        case .failed(let e): return L.t("ai.state.failed", e)
        }
    }

    private func applyEnabled(_ on: Bool) {
        s.aiEnabled = on
        if on { AIModel.shared.start() } else { AIModel.shared.stop(); Predictor.shared.hide() }
    }

    var body: some View {
        Section(L.t("ai.title")) {
            Text(L.t("ai.explain")).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L.t("ai.enable"), isOn: Binding(get: { s.aiEnabled }, set: { applyEnabled($0) }))
            Picker(L.t("ai.mode"), selection: Binding(get: { s.aiMode }, set: { m in
                s.aiMode = m
                if m == .light { AIModel.shared.stop() } else if s.aiEnabled { AIModel.shared.start() }
            })) {
                Text(L.t("ai.mode.model")).tag(AIMode.model)
                Text(L.t("ai.mode.light")).tag(AIMode.light)
            }
            if s.aiMode == .model {
                Picker(L.t("ai.variant"), selection: Binding(get: { s.aiVariant }, set: { v in
                    s.aiVariant = v
                    AIModel.shared.variantChanged()
                })) {
                    Text(L.t("ai.variant.fast")).tag(AIVariant.fast)
                    Text(L.t("ai.variant.quality")).tag(AIVariant.quality)
                }
                HStack {
                    Text(L.t("ai.model", AIModel.modelName)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    switch ai.state {
                    case .notInstalled, .failed:
                        Button(L.t("ai.download")) { ai.download() }
                    case .downloading:
                        Button(L.t("ai.cancel")) { ai.cancel() }
                    default:
                        Button(L.t("ai.remove"), role: .destructive) { ai.remove() }
                    }
                }
                if case .downloading(let p) = ai.state { ProgressView(value: p) }
                Text(stateText).font(.caption).foregroundStyle(.secondary)
            }
            Picker(L.t("ai.phrases"), selection: $s.aiPhrases) {
                Text(L.t("ai.phrases.words")).tag(false)
                Text(L.t("ai.phrases.all")).tag(true)
            }
            .pickerStyle(.segmented)
            if s.aiPhrases {
                Stepper("\(L.t("ai.length")): \(s.aiMaxWords)", value: $s.aiMaxWords, in: 2...15)
            }
            Picker(L.t("ai.confidence"), selection: $s.aiConfidence) {
                Text(L.t("ai.confidence.0")).tag(0)
                Text(L.t("ai.confidence.1")).tag(1)
                Text(L.t("ai.confidence.2")).tag(2)
            }
            .pickerStyle(.segmented)
            Stepper("\(L.t("ai.delay")): \(s.aiDelay)", value: $s.aiDelay, in: 100...1500, step: 50)
            LabeledContent(L.t("ai.langs")) {
                HStack(spacing: 6) {
                    ForEach(Lang.allCases) { l in
                        Toggle(l.short, isOn: Binding(
                            get: { s.aiLangs.contains(l) },
                            set: { on in if on { s.aiLangs.insert(l) } else { s.aiLangs.remove(l) } }))
                            .toggleStyle(.button)
                            .fixedSize()
                    }
                }
            }
            Toggle(L.t("ai.windowContext"), isOn: $s.aiWindowContext)
            Toggle(L.t("ai.learnStyle"), isOn: $s.aiLearnStyle)
            Text(L.t("ai.learnStyle.hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(L.t("ai.learnStyle.clear")) { StyleMemory.shared.clear() }
            Toggle(L.t("ai.personal"), isOn: $s.aiPersonalization)
            Toggle(L.t("ai.learnPhrases"), isOn: $s.learnPhrases).disabled(!s.aiPersonalization)
            Button(L.t("ai.clear")) { UserStore.shared.clearPersonalization() }
            LabeledContent(L.t("hk.acceptWord")) { HotkeyField(hotkey: $s.hkAcceptWord, rec: rec.word, allowPlain: true) }
            LabeledContent(L.t("hk.acceptAll")) { HotkeyField(hotkey: $s.hkAcceptAll, rec: rec.all, allowPlain: true) }
            LabeledContent(L.t("hk.hide")) { HotkeyField(hotkey: $s.hkHide, rec: rec.hide, allowPlain: true) }
            LabeledContent(L.t("hk.undoInsert")) { HotkeyField(hotkey: $s.hkUndoInsert, rec: rec.undo) }
            LabeledContent(L.t("hk.toggleAI")) { HotkeyField(hotkey: $s.hkToggleAI, rec: rec.toggle) }
        }
        Section(L.t("ai.excluded")) {
            ForEach(s.aiExcludedApps, id: \.self) { id in
                HStack {
                    Text(id.hasSuffix("*") ? id : SettingsView.appName(id))
                    Text(id).foregroundStyle(.secondary).font(.caption)
                    Spacer()
                    Button(L.t("set.remove")) { s.aiExcludedApps.removeAll { $0 == id } }
                }
            }
            Button(L.t("set.add")) {
                for id in SettingsView.pickApps() where !s.aiExcludedApps.contains(id) { s.aiExcludedApps.append(id) }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var ui = SettingsUIState()

    var body: some View {
        Form {
            AISection()
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
            Section(L.t("set.extras")) {
                Toggle(L.t("set.skipAllCaps"), isOn: $s.skipAllCaps)
                Toggle(L.t("set.calculator"), isOn: $s.calculator)
                Toggle(L.t("set.learnNames"), isOn: $s.learnNames)
                Toggle(L.t("set.implicitUndo"), isOn: $s.implicitUndo)
            }
            Section {
                ForEach(s.appLayouts.keys.sorted(), id: \.self) { id in
                    HStack {
                        Text(appName(id))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { s.appLayouts[id] ?? "en" },
                            set: { s.appLayouts[id] = $0 })) {
                            ForEach(installedLangs) { l in Text(L.langName(l)).tag(l.rawValue) }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        Toggle(L.t("set.appLayouts.lock"), isOn: Binding(
                            get: { s.appLayoutLocks.contains(id) },
                            set: { on in if on { if !s.appLayoutLocks.contains(id) { s.appLayoutLocks.append(id) } } else { s.appLayoutLocks.removeAll { $0 == id } } }))
                            .toggleStyle(.checkbox)
                            .fixedSize()
                        Button(L.t("set.remove")) { s.appLayouts[id] = nil; s.appLayoutLocks.removeAll { $0 == id } }
                    }
                }
                Button(L.t("set.add")) { addAppLayout() }
            } header: {
                Text(L.t("set.appLayouts"))
            } footer: {
                Text(L.t("set.appLayouts.hint")).font(.caption).foregroundStyle(.secondary)
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

    private var installedLangs: [Lang] { Lang.allCases.filter { LayoutManager.shared.layouts[$0] != nil } }

    static func pickApps() -> [String] {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return [] }
        return p.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
    }

    static func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path)
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

    private func addAppLayout() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        let def = LayoutManager.shared.currentLang?.rawValue ?? "en"
        for u in p.urls {
            if let id = Bundle(url: u)?.bundleIdentifier, s.appLayouts[id] == nil { s.appLayouts[id] = def }
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
