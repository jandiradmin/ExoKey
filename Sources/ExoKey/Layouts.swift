import Carbon
import Foundation

/// Physical key press: key code + shift/caps state.
struct KeyStroke: Codable, Equatable {
    let code: UInt16
    let shift: Bool
    let caps: Bool
}

/// A keyboard layout installed in the system, with a cached key → character map.
final class KeyLayout {
    let lang: Lang
    let id: String
    let name: String
    let source: TISInputSource
    private var map: [Int: String] = [:]

    init?(source: TISInputSource) {
        guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        id = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        if let nPtr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) {
            name = Unmanaged<CFString>.fromOpaque(nPtr).takeUnretainedValue() as String
        } else { name = id }
        guard let lPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
        let langs = Unmanaged<CFArray>.fromOpaque(lPtr).takeUnretainedValue() as? [String] ?? []
        guard let first = langs.first, let l = Lang(rawValue: String(first.prefix(2))) else { return nil }
        lang = l
        self.source = source
        guard let dPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(dPtr).takeUnretainedValue() as Data
        let kbdType = UInt32(LMGetKbdType())
        data.withUnsafeBytes { raw in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in 0..<128 {
                for shift in [false, true] {
                    for caps in [false, true] {
                        var dead: UInt32 = 0
                        var len = 0
                        var chars = [UniChar](repeating: 0, count: 4)
                        var mods: UInt32 = 0
                        if shift { mods |= UInt32(shiftKey) }
                        if caps { mods |= UInt32(alphaLock) }
                        let st = UCKeyTranslate(p, UInt16(code), UInt16(kUCKeyActionDown), (mods >> 8) & 0xFF,
                                                kbdType, OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                                &dead, 4, &len, &chars)
                        if st == noErr, len > 0 {
                            map[Self.key(UInt16(code), shift, caps)] = String(utf16CodeUnits: chars, count: len)
                        }
                    }
                }
            }
        }
        if map.isEmpty { return nil }
    }

    private static func key(_ c: UInt16, _ s: Bool, _ k: Bool) -> Int { Int(c) << 2 | (s ? 1 : 0) | (k ? 2 : 0) }

    func char(_ k: KeyStroke) -> String? { map[Self.key(k.code, k.shift, k.caps)] }

    func text(_ keys: [KeyStroke]) -> String { keys.map { char($0) ?? "" }.joined() }

    /// Key that types `ch` in this layout (without Caps Lock).
    func keystroke(for ch: String) -> KeyStroke? {
        if reverse.isEmpty {
            for (k, s) in map where k & 2 == 0 {
                let ks = KeyStroke(code: UInt16(k >> 2), shift: k & 1 == 1, caps: false)
                if let old = reverse[s], !old.shift || ks.shift { continue }   // prefer the unshifted key
                reverse[s] = ks
            }
        }
        return reverse[ch]
    }
    private var reverse: [String: KeyStroke] = [:]

    func isLetter(_ k: KeyStroke) -> Bool {
        guard let s = char(k), s.count == 1, let c = s.first else { return false }
        return TextNorm.isLetter(c, lang)
    }

    func isWordChar(_ k: KeyStroke) -> Bool {
        guard let s = char(k), s.count == 1, let c = s.first else { return false }
        return TextNorm.isLetter(c, lang) || TextNorm.isInner(c, lang)
    }
}

/// Tracks enabled system layouts and the current one.
final class LayoutManager {
    static let shared = LayoutManager()
    /// Preferred layout per language (the last one the user used for it).
    private(set) var layouts: [Lang: KeyLayout] = [:]
    private(set) var all: [KeyLayout] = []
    private(set) var currentID: String = ""
    var onChange: ((_ external: Bool) -> Void)?
    private var expectedID: String?

    private init() {
        reload()
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                        object: nil, queue: .main) { [weak self] _ in self?.selectionChanged() }
        dnc.addObserver(forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                        object: nil, queue: .main) { [weak self] _ in self?.reload() }
    }

    func reload() {
        var result: [Lang: KeyLayout] = [:]
        var list: [KeyLayout] = []
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        if let srcs = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] {
            for src in srcs {
                guard let l = KeyLayout(source: src) else { continue }
                list.append(l)
                if result[l.lang] == nil { result[l.lang] = l }
            }
        }
        all = list
        layouts = result
        refreshCurrent()
    }

    private static func systemID() -> String {
        let src = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    private func refreshCurrent() {
        currentID = Self.systemID()
        if let c = all.first(where: { $0.id == currentID }) { layouts[c.lang] = c }
    }

    private var syncScheduled = false

    /// The system is the only truth: a select can be ignored or undone by macOS without a notification
    /// (seen on app switches), and a stale `currentID` made ExoKey show and assume the wrong language.
    /// A mismatch is handled like a change notification, but later on the main queue (no re-entry into the caller).
    private func realID() -> String {
        guard Thread.isMainThread else { return currentID }   // TIS calls belong on the main thread
        let real = Self.systemID()
        if !real.isEmpty, real != currentID, !syncScheduled {
            syncScheduled = true
            Log.write("layout: out of sync, ExoKey had \(currentID), the system has \(real)")
            DispatchQueue.main.async { [weak self] in
                self?.syncScheduled = false
                self?.selectionChanged()
            }
        }
        return real.isEmpty ? currentID : real
    }

    private func selectionChanged() {
        let before = currentID
        refreshCurrent()
        // macOS often sends the notification twice; the second one (same layout) is not a new switch
        if currentID == before && expectedID == nil { return }
        let external = expectedID != currentID
        expectedID = nil
        onChange?(external)
        NotificationCenter.default.post(name: .exoLayoutChanged, object: nil)
    }

    /// Language of the current layout, nil if it is not one of en/ru/uk (or not enabled in the system).
    var currentLang: Lang? { current?.lang }

    var current: KeyLayout? {
        let id = realID()
        return all.first { $0.id == id }
    }

    /// The system's own "select previous / next input source" shortcuts (⌃Space, ⌃⌥Space by default), as set in
    /// System Settings → Keyboard → Shortcuts. They switch the layout and don't edit text.
    private(set) lazy var switchShortcuts: [(code: Int64, mods: UInt64)] = Self.readSwitchShortcuts()

    func isSwitchShortcut(code: Int64, flags: CGEventFlags) -> Bool {
        let m = flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).rawValue
        return switchShortcuts.contains { $0.code == code && $0.mods == m }
    }

    private static func readSwitchShortcuts() -> [(code: Int64, mods: UInt64)] {
        guard let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
                as? [String: Any] else { return [] }
        var out: [(code: Int64, mods: UInt64)] = []
        for id in ["60", "61"] {
            guard let e = all[id] as? [String: Any], (e["enabled"] as? Bool) ?? ((e["enabled"] as? Int) == 1),
                  let v = e["value"] as? [String: Any], let p = v["parameters"] as? [Any], p.count == 3,
                  let code = (p[1] as? NSNumber)?.int64Value, let mods = (p[2] as? NSNumber)?.uint64Value else { continue }
            out.append((code, mods))
        }
        return out
    }

    func select(_ lang: Lang, retries: Int = 2) {
        guard let l = layouts[lang], l.id != realID() else { return }
        expectedID = l.id
        let status = TISSelectInputSource(l.source)
        currentID = Self.systemID()
        if currentID != l.id { Log.write("layout: select \(lang.rawValue) not applied (status \(status)), system has \(currentID)") }
        // check again when macOS settles; the user's own switch or typing since then wins
        guard retries > 0 else { return }
        let asked = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, Engine.shared.lastUserInput < asked else { return }
            let real = Self.systemID()
            guard real != l.id else { return }
            Log.write("layout: \(lang.rawValue) did not stick (system has \(real)), selecting again")
            self.select(lang, retries: retries - 1)
        }
    }
}
