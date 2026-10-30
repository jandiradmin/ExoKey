import Foundation

enum Lang: String, CaseIterable, Codable, Identifiable {
    case en, ru, uk
    var id: String { rawValue }
    var short: String { rawValue.uppercased() }
    var isCyrillic: Bool { self != .en }
}

/// Text normalization shared with tools/build_dicts.py
enum TextNorm {
    static func normalize(_ s: String, _ lang: Lang) -> String {
        var r = s.lowercased()
        r = r.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{02BC}", with: "'")
            .replacingOccurrences(of: "`", with: "'")
        if lang == .ru { r = r.replacingOccurrences(of: "ё", with: "е") }
        return r
    }

    static let letters: [Lang: Set<Character>] = [
        .en: Set("abcdefghijklmnopqrstuvwxyz"),
        .ru: Set("абвгдеёжзийклмнопрстуфхцчшщъыьэюя"),
        .uk: Set("абвгґдеєжзиіїйклмнопрстуфхцчшщьюя"),
    ]

    static func isLetter(_ c: Character, _ lang: Lang) -> Bool {
        guard let l = c.lowercased().first else { return false }
        return letters[lang]!.contains(l)
    }

    static func isInner(_ c: Character, _ lang: Lang) -> Bool {
        if c == "-" { return true }
        if c == "'" || c == "\u{2019}" || c == "\u{02BC}" { return lang != .ru }
        return false
    }
}

/// Memory-mapped, front-coded sorted word list with cumulative frequencies.
final class WordDictionary {
    let lang: Lang
    private let base: UnsafeRawPointer
    private let size: Int
    let count: Int
    private let nBlocks: Int
    private let blockSize: Int
    private let offsetsPos: Int
    private let cumPos: Int
    private let dataPos: Int
    private var buf = [UInt8](repeating: 0, count: 256)

    init?(url: URL, lang: Lang) {
        self.lang = lang
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 20 else { return nil }
        size = Int(st.st_size)
        guard let p = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), p != MAP_FAILED else { return nil }
        base = UnsafeRawPointer(p)
        guard base.load(as: UInt32.self) == 0x3244_5845 else { return nil } // "EXD2"
        count = Int(base.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        nBlocks = Int(base.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
        blockSize = Int(base.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
        offsetsPos = 20
        cumPos = offsetsPos + nBlocks * 4
        dataPos = cumPos + (nBlocks + 1) * 4
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), size) }

    private func u32(_ pos: Int) -> Int { Int(base.loadUnaligned(fromByteOffset: pos, as: UInt32.self)) }
    private func byte(_ pos: Int) -> UInt8 { base.load(fromByteOffset: pos, as: UInt8.self) }

    private func varint(_ pos: inout Int) -> Int {
        var r = 0, shift = 0
        while true {
            let b = byte(pos); pos += 1
            r |= Int(b & 0x7F) << shift
            if b & 0x80 == 0 { return r }
            shift += 7
        }
    }

    private static func compare(_ a: UnsafeBufferPointer<UInt8>, _ b: [UInt8]) -> Int {
        let n = min(a.count, b.count)
        for i in 0..<n where a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
        return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
    }

    private func firstWordCompare(block: Int, _ key: [UInt8]) -> Int {
        var pos = dataPos + u32(offsetsPos + block * 4)
        let len = varint(&pos)
        let ptr = base.advanced(by: pos).assumingMemoryBound(to: UInt8.self)
        return Self.compare(UnsafeBufferPointer(start: ptr, count: len), key)
    }

    /// Returns (index of first word >= key, cumulative freq before it, freq of that word if equal to key)
    private func lowerBound(_ key: [UInt8]) -> (cum: Int, exactFreq: Int) {
        guard nBlocks > 0 else { return (0, 0) }
        var lo = 0, hi = nBlocks - 1, blk = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if firstWordCompare(block: mid, key) <= 0 { blk = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        if blk < 0 { return (0, 0) }
        var cum = u32(cumPos + blk * 4)
        var pos = dataPos + u32(offsetsPos + blk * 4)
        let inBlock = min(blockSize, count - blk * blockSize)
        var curLen = 0
        for i in 0..<inBlock {
            if i == 0 {
                curLen = varint(&pos)
                for j in 0..<curLen { buf[j] = byte(pos + j) }
                pos += curLen
            } else {
                let shared = Int(byte(pos)); pos += 1
                let suf = varint(&pos)
                for j in 0..<suf { buf[shared + j] = byte(pos + j) }
                pos += suf
                curLen = shared + suf
            }
            let fr = varint(&pos)
            let c = buf.withUnsafeBufferPointer { Self.compare(UnsafeBufferPointer(rebasing: $0[0..<curLen]), key) }
            if c >= 0 { return (cum, c == 0 ? fr : 0) }
            cum += fr
        }
        return (u32(cumPos + (blk + 1) * 4), 0)
    }

    /// Most frequent word that starts with `prefix` (longer than it). Scans at most `limit` words.
    func bestCompletion(_ prefix: String, limit: Int = 40000) -> (word: String, freq: Int)? {
        let key = Array(prefix.utf8)
        guard key.count >= 2, nBlocks > 0 else { return nil }
        var lo = 0, hi = nBlocks - 1, blk = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if firstWordCompare(block: mid, key) < 0 { blk = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        var pos = dataPos + u32(offsetsPos + blk * 4)
        var idx = blk * blockSize
        var cur = [UInt8](repeating: 0, count: 256)
        var len = 0
        var best: ([UInt8], Int)?
        var scanned = 0
        while idx < count, scanned < limit {
            if idx % blockSize == 0 {
                pos = dataPos + u32(offsetsPos + (idx / blockSize) * 4)
                len = varint(&pos)
                for j in 0..<len { cur[j] = byte(pos + j) }
                pos += len
            } else {
                let shared = Int(byte(pos)); pos += 1
                let suf = varint(&pos)
                for j in 0..<suf { cur[shared + j] = byte(pos + j) }
                pos += suf
                len = shared + suf
            }
            let fr = varint(&pos)
            idx += 1
            let hasPrefix = len >= key.count && (0..<key.count).allSatisfy { cur[$0] == key[$0] }
            if hasPrefix {
                scanned += 1
                if len > key.count, fr > (best?.1 ?? 0) { best = (Array(cur[0..<len]), fr) }
            } else {
                let c = cur.withUnsafeBufferPointer { Self.compare(UnsafeBufferPointer(rebasing: $0[0..<len]), key) }
                if c > 0 { break }
            }
        }
        guard let b = best, let w = String(bytes: b.0, encoding: .utf8) else { return nil }
        return (w, b.1)
    }

    /// Sequential scan of all words with frequency >= minFreq.
    func forEach(minFreq: Int, _ body: (UnsafeBufferPointer<UInt8>, Int) -> Void) {
        var pos = dataPos
        var cur = [UInt8](repeating: 0, count: 256)
        var len = 0
        for i in 0..<count {
            if i % blockSize == 0 {
                pos = dataPos + u32(offsetsPos + (i / blockSize) * 4)
                len = varint(&pos)
                for j in 0..<len { cur[j] = byte(pos + j) }
                pos += len
            } else {
                let shared = Int(byte(pos)); pos += 1
                let suf = varint(&pos)
                for j in 0..<suf { cur[shared + j] = byte(pos + j) }
                pos += suf
                len = shared + suf
            }
            let fr = varint(&pos)
            if fr >= minFreq { cur.withUnsafeBufferPointer { body(UnsafeBufferPointer(rebasing: $0[0..<len]), fr) } }
        }
    }

    func freq(_ word: String) -> Int {
        let k = Array(word.utf8)
        guard !k.isEmpty, k.count < 200 else { return 0 }
        return lowerBound(k).exactFreq
    }

    /// Sum of frequencies of all words starting with prefix.
    func prefixFreq(_ prefix: String) -> Int {
        let k = Array(prefix.utf8)
        guard !k.isEmpty, k.count < 200 else { return 0 }
        let a = lowerBound(k).cum
        let b = lowerBound(k + [0xFF]).cum
        return max(0, b - a)
    }
}
