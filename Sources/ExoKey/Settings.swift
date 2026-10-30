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

enum AIMode: String, CaseIterable, Codable, Identifiable {
    case model, light
    var id: String { rawValue }
}

enum AIVariant: String, CaseIterable, Codable, Identifiable {
    case fast, quality
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
    @Published var aiEnabled: Bool { didSet { d.set(aiEnabled, forKey: "aiEnabled") } }
    @Published var aiMode: AIMode { didSet { d.set(aiMode.rawValue, forKey: "aiMode") } }
    @Published var aiVariant: AIVariant { didSet { d.set(aiVariant.rawValue, forKey: "aiVariant") } }
    /// 0 = careful (short, sure), 1 = normal, 2 = bold (longer, more guesses)
    @Published var aiConfidence: Int { didSet { d.set(aiConfidence, forKey: "aiConfidence") } }
    @Published var aiLearnStyle: Bool { didSet { d.set(aiLearnStyle, forKey: "aiLearnStyle") } }
    /// 0 off, 1 on layout change, 2 always while typing
    @Published var badgeMode: Int { didSet { d.set(badgeMode, forKey: "badgeMode") } }
    @Published var fixNameCase: Bool { didSet { d.set(fixNameCase, forKey: "fixNameCase") } }
    @Published var aiWindowContext: Bool { didSet { d.set(aiWindowContext, forKey: "aiWindowContext") } }
    @Published var aiPhrases: Bool { didSet { d.set(aiPhrases, forKey: "aiPhrases") } }
    @Published var aiMaxWords: Int { didSet { d.set(aiMaxWords, forKey: "aiMaxWords") } }
    @Published var aiDelay: Int { didSet { d.set(aiDelay, forKey: "aiDelay") } }
    @Published var aiLangs: Set<Lang> { didSet { d.set(aiLangs.map(\.rawValue), forKey: "aiLangs") } }
    @Published var aiExcludedApps: [String] { didSet { d.set(aiExcludedApps, forKey: "aiExcludedApps") } }
    @Published var aiPersonalization: Bool { didSet { d.set(aiPersonalization, forKey: "aiPersonalization") } }
    @Published var learnPhrases: Bool { didSet { d.set(learnPhrases, forKey: "learnPhrases") } }
    @Published var hkAcceptWord: Hotkey { didSet { save(hkAcceptWord, "hkAcceptWord") } }
    @Published var hkAcceptAll: Hotkey { didSet { save(hkAcceptAll, "hkAcceptAll") } }
    @Published var hkHide: Hotkey { didSet { save(hkHide, "hkHide") } }
    @Published var hkUndoInsert: Hotkey { didSet { save(hkUndoInsert, "hkUndoInsert") } }
    @Published var hkToggleAI: Hotkey { didSet { save(hkToggleAI, "hkToggleAI") } }
    @Published var skipAllCaps: Bool { didSet { d.set(skipAllCaps, forKey: "skipAllCaps") } }
    var firstRunDone: Bool {
        get { d.bool(forKey: "firstRunDone") }
        set { d.set(newValue, forKey: "firstRunDone") }
    }
    @Published var calculator: Bool { didSet { d.set(calculator, forKey: "calculator") } }
    @Published var learnNames: Bool { didSet { d.set(learnNames, forKey: "learnNames") } }
    @Published var implicitUndo: Bool { didSet { d.set(implicitUndo, forKey: "implicitUndo") } }
    /// bundle id -> layout language to switch to when the app becomes active
    @Published var appLayouts: [String: String] { didSet { d.set(appLayouts, forKey: "appLayouts") } }
    /// Apps where auto-correction may switch only to the assigned language
    @Published var appLayoutLocks: [String] { didSet { d.set(appLayoutLocks, forKey: "appLayoutLocks") } }
    @Published var hkUndo: Hotkey { didSet { save(hkUndo, "hkUndo") } }
    @Published var hkConvert: Hotkey { didSet { save(hkConvert, "hkConvert") } }
    @Published var hkPause: Hotkey { didSet { save(hkPause, "hkPause") } }

    private init() {
        d.register(defaults: [
            "enabled": true, "minLetters": 3, "learning": true, "addMode": AddMode.repeated.rawValue,
            "repeatCount": 3, "undosToException": 2, "notifications": true, "uiLang": UILang.system.rawValue,
            "excludedApps": ["com.apple.Terminal", "com.googlecode.iterm2", "com.apple.keychainaccess"],
            "activeLangs": ["en", "ru", "uk"],
            "aiEnabled": false, "aiMode": AIMode.model.rawValue, "aiPhrases": true, "badgeMode": 1, "fixNameCase": false, "aiLearnStyle": false, "aiVariant": AIVariant.fast.rawValue, "aiWindowContext": true, "aiMaxWords": 6, "aiDelay": 120, "aiConfidence": 1,
            "aiLangs": ["en", "ru", "uk"], "aiPersonalization": true, "learnPhrases": false,
            "aiExcludedApps": ["com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode",
                               "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode", "dev.zed.Zed", "dev.warp.Warp-Stable",
                               "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "com.sublimetext.4",
                               "com.jetbrains.*", "com.apple.keychainaccess"], "skipAllCaps": true,
            "calculator": true, "learnNames": true, "implicitUndo": true,
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
        aiEnabled = d.bool(forKey: "aiEnabled")
        skipAllCaps = d.bool(forKey: "skipAllCaps")
        aiMode = AIMode(rawValue: d.string(forKey: "aiMode") ?? "") ?? .model
        aiPhrases = d.bool(forKey: "aiPhrases")
        aiWindowContext = d.bool(forKey: "aiWindowContext")
        badgeMode = d.integer(forKey: "badgeMode")
        fixNameCase = d.bool(forKey: "fixNameCase")
        aiLearnStyle = d.bool(forKey: "aiLearnStyle")
        aiConfidence = d.integer(forKey: "aiConfidence")
        aiVariant = AIVariant(rawValue: d.string(forKey: "aiVariant") ?? "") ?? .fast
        aiMaxWords = d.integer(forKey: "aiMaxWords")
        aiDelay = d.integer(forKey: "aiDelay")
        aiLangs = Set((d.stringArray(forKey: "aiLangs") ?? []).compactMap(Lang.init(rawValue:)))
        aiExcludedApps = d.stringArray(forKey: "aiExcludedApps") ?? []
        aiPersonalization = d.bool(forKey: "aiPersonalization")
        learnPhrases = d.bool(forKey: "learnPhrases")
        calculator = d.bool(forKey: "calculator")
        learnNames = d.bool(forKey: "learnNames")
        implicitUndo = d.bool(forKey: "implicitUndo")
        appLayouts = d.dictionary(forKey: "appLayouts") as? [String: String] ?? [:]
        appLayoutLocks = d.stringArray(forKey: "appLayoutLocks") ?? []
        let ctrlOpt = CGEventFlags([.maskControl, .maskAlternate]).rawValue
        hkUndo = Self.load(d, "hkUndo") ?? Hotkey(keyCode: 6, mods: ctrlOpt)      // ⌃⌥Z
        hkConvert = Self.load(d, "hkConvert") ?? Hotkey(keyCode: 7, mods: ctrlOpt) // ⌃⌥X
        hkPause = Self.load(d, "hkPause") ?? Hotkey(keyCode: 35, mods: ctrlOpt)    // ⌃⌥P
        hkAcceptWord = Self.load(d, "hkAcceptWord") ?? Hotkey(keyCode: 48, mods: 0) // Tab
        hkAcceptAll = Self.load(d, "hkAcceptAll") ?? Hotkey(keyCode: 48, mods: CGEventFlags.maskShift.rawValue) // ⇧Tab
        hkHide = Self.load(d, "hkHide") ?? Hotkey(keyCode: 53, mods: 0)            // Esc
        hkUndoInsert = Self.load(d, "hkUndoInsert") ?? Hotkey(keyCode: 51, mods: ctrlOpt) // ⌃⌥⌫
        hkToggleAI = Self.load(d, "hkToggleAI") ?? Hotkey(keyCode: 0, mods: ctrlOpt)      // ⌃⌥A
    }

    func isAIExcluded(_ bundleID: String) -> Bool {
        aiExcludedApps.contains { $0.hasSuffix("*") ? bundleID.hasPrefix(String($0.dropLast())) : $0 == bundleID }
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
