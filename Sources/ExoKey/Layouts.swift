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

    private func refreshCurrent() {
        let src = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        if let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
            currentID = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        }
        if let c = current { layouts[c.lang] = c }
    }

    private func selectionChanged() {
        refreshCurrent()
        let external = expectedID != currentID
        expectedID = nil
        onChange?(external)
    }

    /// Language of the current layout, nil if it is not one of en/ru/uk (or not enabled in the system).
    var currentLang: Lang? { current?.lang }

    var current: KeyLayout? { all.first { $0.id == currentID } }

    func select(_ lang: Lang) {
        guard let l = layouts[lang], l.id != currentID else { return }
        expectedID = l.id
        TISSelectInputSource(l.source)
        currentID = l.id
    }
}
