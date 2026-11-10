import Foundation

/// A sorted word list (one word per line, byte order), memory-mapped and searched in place: the dictionary's
/// unverified forms ("сегодн", "немног", "встетиться" — not confirmed by the spelling dictionary).
final class WordSet {
    private let data: Data
    private var starts: [Int32] = []

    init?(url: URL) {
        guard let d = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        data = d
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var s = 0
            for i in 0..<p.count where p[i] == 10 { starts.append(Int32(s)); s = i + 1 }
            if s < p.count { starts.append(Int32(s)) }
        }
    }

    func contains(_ w: String) -> Bool {
        let key = Array(w.utf8)
        return data.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Bool in
            var lo = 0, hi = starts.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let a = Int(starts[mid])
                var b = a
                while b < p.count, p[b] != 10 { b += 1 }
                var c = 0, i = 0
                while c == 0 {
                    if i == key.count { c = (a + i == b) ? 0 : 1; break }
                    if a + i == b { c = -1; break }
                    c = Int(p[a + i]) - Int(key[i])
                    i += 1
                }
                if c == 0 { return true }
                if c < 0 { lo = mid + 1 } else { hi = mid - 1 }
            }
            return false
        }
    }

    private static let sets: [KeyboardLang: WordSet] = {
        var r: [KeyboardLang: WordSet] = [:]
        for l in [KeyboardLang.ru, .en] {
            if let u = Bundle.main.url(forResource: l.rawValue, withExtension: "unv"), let s = WordSet(url: u) { r[l] = s }
        }
        return r
    }()

    static func unverified(_ l: KeyboardLang) -> WordSet? { sets[l] }

    /// First names and place names (lower case, all forms: "даша", "дашу"), never "fixed" into other words.
    private static let nameSets: [KeyboardLang: WordSet] = {
        var r: [KeyboardLang: WordSet] = [:]
        for l in [KeyboardLang.ru, .en] {
            if let u = Bundle.main.url(forResource: l.rawValue, withExtension: "nam"), let s = WordSet(url: u) { r[l] = s }
        }
        return r
    }()

    static func names(_ l: KeyboardLang) -> WordSet? { nameSets[l] }
}
