import Foundation

/// Typo correction index: "хорактестиски" → "характеристики", "првиет" → "привет", "teh" → "the".
/// Candidates: frequent dictionary words with the same first letter (or first two letters swapped),
/// within an edit distance that grows with word length (missing / extra / wrong / swapped letters).
final class SpellIndex {
    let lang: Lang
    private var chars: [UInt16] = []
    private var starts: [Int32] = []
    private var freqs: [Int32] = []
    private var buckets: [UInt16: Range<Int>] = [:]
    private var unverified: Set<String> = []
    private(set) var ready = false

    private let unverifiedURL: URL?

    init(lang: Lang, unverifiedURL: URL? = nil) {
        self.lang = lang
        self.unverifiedURL = unverifiedURL ?? Bundle.main.resourceURL?.appendingPathComponent("\(lang.rawValue).unverified")
    }

    func build(_ dict: WordDictionary) {
        if let u = unverifiedURL, let t = try? String(contentsOf: u, encoding: .utf8) {
            unverified = Set(t.split(separator: "\n").map(String.init))
        }
        var items: [(first: UInt16, w: [UInt16], f: Int32)] = []
        dict.forEach(minFreq: 2) { bytes, f in
            let s = String(decoding: bytes, as: UTF8.self)
            // targets: verified words, or common ones
            if f < 2000 && unverified.contains(s) { return }
            let u = Array(s.utf16)
            if let first = u.first { items.append((first, u, Int32(min(f, Int(Int32.max))))) }
        }
        items.sort { $0.first != $1.first ? $0.first < $1.first : $0.w.count < $1.w.count }
        chars.reserveCapacity(items.reduce(0) { $0 + $1.w.count })
        var i = 0
        while i < items.count {
            let first = items[i].first
            let begin = starts.count
            while i < items.count && items[i].first == first {
                starts.append(Int32(chars.count)); chars.append(contentsOf: items[i].w); freqs.append(items[i].f); i += 1
            }
            buckets[first] = begin..<starts.count
        }
        starts.append(Int32(chars.count))
        ready = true
        if Bundle.main.bundleIdentifier != nil { Log.write("spell index \(lang.rawValue): \(freqs.count) words") }
    }

    func isUnverified(_ w: String) -> Bool { unverified.contains(w) }

    static func maxDist(_ n: Int) -> Int { n <= 4 ? 1 : n <= 8 ? 2 : n <= 11 ? 3 : 4 }

    /// Best candidate (distance, word, freq) for a lowercase normalized word.
    func best(for word: String) -> (Int, String, Int)? {
        guard ready else { return nil }
        let w = Array(word.utf16)
        guard w.count >= 3 else { return nil }
        let k = Self.maxDist(w.count)
        var best: (d: Int, idx: Int)?
        var firsts: [UInt16] = [w[0]]
        if w[1] != w[0] { firsts.append(w[1]) }
        var prev2 = [Int](repeating: 0, count: 64), prev = prev2, cur = prev2
        for first in firsts {
            guard let r = buckets[first] else { continue }
            for idx in r {
                let a = Int(starts[idx]), b = Int(starts[idx + 1])
                let m = b - a
                if abs(m - w.count) > k || m >= 63 { continue }
                let d = chars.withUnsafeBufferPointer { c -> Int in
                    Self.osa(w, c, a, m, k, &prev2, &prev, &cur)
                }
                guard d <= k, d > 0 else { continue }
                if best == nil || d < best!.d || (d == best!.d && freqs[idx] > freqs[best!.idx]) { best = (d, idx) }
            }
        }
        guard let bb = best else { return nil }
        let a = Int(starts[bb.idx]), b = Int(starts[bb.idx + 1])
        return (bb.d, String(decoding: chars[a..<b], as: UTF16.self), Int(freqs[bb.idx]))
    }

    /// Optimal string alignment distance with early cutoff.
    private static func osa(_ s: [UInt16], _ c: UnsafeBufferPointer<UInt16>, _ off: Int, _ m: Int, _ k: Int,
                            _ p2: inout [Int], _ p1: inout [Int], _ cur: inout [Int]) -> Int {
        let n = s.count
        for j in 0...m { p1[j] = j }
        for i in 1...n {
            cur[0] = i
            var rowMin = i
            for j in 1...m {
                let cost = s[i - 1] == c[off + j - 1] ? 0 : 1
                var v = min(p1[j] + 1, cur[j - 1] + 1, p1[j - 1] + cost)
                if i > 1 && j > 1 && s[i - 1] == c[off + j - 2] && s[i - 2] == c[off + j - 1] { v = min(v, p2[j - 2] + 1) }
                cur[j] = v
                if v < rowMin { rowMin = v }
            }
            if rowMin > k { return k + 1 }
            swap(&p2, &p1); swap(&p1, &cur)
        }
        return p1[m]
    }
}

