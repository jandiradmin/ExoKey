import AppKit
import Combine
import ServiceManagement

struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    var mods: UInt64   // CGEventFlags raw value subset: cmd/opt/ctrl/shift

    static let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    func matches(code: UInt16, flags: CGEventFlags) -> Bool {
        code == keyCode && flags.intersection(Self.relevant).rawValue == mods
    }

    var display: String {
        let f = CGEventFlags(rawValue: mods)
        var s = ""
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
        return s + KeyNames.name(keyCode)
    }
}

enum KeyNames {
    static let special: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    ]
    static func name(_ code: UInt16) -> String {
        if let s = special[code] { return s }
        if let en = LayoutManager.shared.layouts[.en], let c = en.char(KeyStroke(code: code, shift: false, caps: false)) {
            return c.uppercased()
        }
        return "#\(code)"
    }
}

enum AddMode: String, CaseIterable, Codable, Identifiable {
    case confirm, repeated, immediate
    var id: String { rawValue }
}

enum UILang: String, CaseIterable, Codable, Identifiable {
    case system, ru, uk, en
    var id: String { rawValue }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "enabled") } }
    @Published var activeLangs: Set<Lang> { didSet { d.set(activeLangs.map(\.rawValue), forKey: "activeLangs") } }
    @Published var minLetters: Int { didSet { d.set(minLetters, forKey: "minLetters") } }
    @Published var learning: Bool { didSet { d.set(learning, forKey: "learning") } }
    @Published var addMode: AddMode { didSet { d.set(addMode.rawValue, forKey: "addMode") } }
    @Published var repeatCount: Int { didSet { d.set(repeatCount, forKey: "repeatCount") } }
    @Published var undosToException: Int { didSet { d.set(undosToException, forKey: "undosToException") } }
    @Published var notifications: Bool { didSet { d.set(notifications, forKey: "notifications") } }
    @Published var uiLang: UILang { didSet { d.set(uiLang.rawValue, forKey: "uiLang") } }
    @Published var excludedApps: [String] { didSet { d.set(excludedApps, forKey: "excludedApps") } }
    @Published var hkUndo: Hotkey { didSet { save(hkUndo, "hkUndo") } }
    @Published var hkConvert: Hotkey { didSet { save(hkConvert, "hkConvert") } }
    @Published var hkPause: Hotkey { didSet { save(hkPause, "hkPause") } }

    private init() {
        d.register(defaults: [
            "enabled": true, "minLetters": 3, "learning": true, "addMode": AddMode.repeated.rawValue,
            "repeatCount": 3, "undosToException": 2, "notifications": true, "uiLang": UILang.system.rawValue,
            "excludedApps": ["com.apple.Terminal", "com.googlecode.iterm2", "com.apple.keychainaccess"],
            "activeLangs": ["en", "ru", "uk"],
        ])
        enabled = d.bool(forKey: "enabled")
        activeLangs = Set((d.stringArray(forKey: "activeLangs") ?? []).compactMap(Lang.init(rawValue:)))
        minLetters = d.integer(forKey: "minLetters")
        learning = d.bool(forKey: "learning")
        addMode = AddMode(rawValue: d.string(forKey: "addMode") ?? "") ?? .repeated
        repeatCount = d.integer(forKey: "repeatCount")
        undosToException = d.integer(forKey: "undosToException")
        notifications = d.bool(forKey: "notifications")
        uiLang = UILang(rawValue: d.string(forKey: "uiLang") ?? "") ?? .system
        excludedApps = d.stringArray(forKey: "excludedApps") ?? []
        let ctrlOpt = CGEventFlags([.maskControl, .maskAlternate]).rawValue
        hkUndo = Self.load(d, "hkUndo") ?? Hotkey(keyCode: 6, mods: ctrlOpt)      // ⌃⌥Z
        hkConvert = Self.load(d, "hkConvert") ?? Hotkey(keyCode: 7, mods: ctrlOpt) // ⌃⌥X
        hkPause = Self.load(d, "hkPause") ?? Hotkey(keyCode: 35, mods: ctrlOpt)    // ⌃⌥P
    }

    private func save(_ h: Hotkey, _ k: String) { d.set(try? JSONEncoder().encode(h), forKey: k) }
    private static func load(_ d: UserDefaults, _ k: String) -> Hotkey? {
        d.data(forKey: k).flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) }
    }

    var autostart: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("ExoKey autostart: \(error)")
            }
        }
    }
}
