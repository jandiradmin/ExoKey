import AppKit

/// Typo correction: "хорактестиски" → "характеристики", "првиет" → "привет", "teh" → "the".
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

    init(lang: Lang) { self.lang = lang }

    func build(_ dict: WordDictionary) {
        if let u = Bundle.main.resourceURL?.appendingPathComponent("\(lang.rawValue).unverified"),
           let t = try? String(contentsOf: u, encoding: .utf8) {
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
        Log.write("spell index \(lang.rawValue): \(freqs.count) words")
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

final class SpellFix {
    static let shared = SpellFix()
    private var indexes: [Lang: SpellIndex] = [:]
    private let queue = DispatchQueue(label: "exokey.spell", qos: .userInitiated)
    private var loading = false

    // offer (plaque) state
    private(set) var offer: (orig: String, fix: String, boundary: String)?
    private var generation = 0
    // last applied fix, for ⌃⌥Z
    private var applied: (orig: String, fix: String, boundary: String)?
    private var keysSinceApply = 0

    private let panel: NSPanel
    private let label: NSTextField
    private let bg: NSVisualEffectView

    var isOffering: Bool { offer != nil && panel.isVisible }

    private init() {
        label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(white: 0.95, alpha: 1)
        bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .darkAqua)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 6
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let root = NSView()
        root.addSubview(bg)
        root.addSubview(label)
        panel.contentView = root
    }

    /// Builds indexes in the background (first use or app start).
    func warmUp() {
        guard !loading, Settings.shared.spellMode > 0 else { return }
        loading = true
        let dicts = Engine.shared.dicts
        queue.async {
            for l in Lang.allCases {
                guard let d = dicts[l] else { continue }
                let ix = SpellIndex(lang: l)
                ix.build(d)
                DispatchQueue.main.async { self.indexes[l] = ix }
            }
        }
    }

    // MARK: decision

    /// Correction for a finished word as typed (with case), or nil. Runs on the spell queue.
    private func correction(_ typed: String, _ lang: Lang, auto: Bool) -> String? {
        guard let ix = indexes[lang], ix.ready else { return nil }
        let lower = TextNorm.normalize(typed, lang)
        guard lower.count >= 3, lower.allSatisfy({ TextNorm.isLetter($0, lang) || $0 == "-" || $0 == "'" }) else { return nil }
        if UserStore.shared.isWord(lower, lang) || UserStore.shared.isException(lower, lang) { return nil }
        let wf = Engine.shared.dicts[lang]?.freq(lower) ?? 0
        // a real word stays; a frequency-list word unknown to Hunspell may be a typo
        if wf > 0 && (!ix.isUnverified(lower) || wf >= 2000) { return nil }
        guard let (d, cand, cf) = ix.best(for: lower) else { return nil }
        if wf > 0 && cf < wf * (auto ? 3000 : 100) { return nil }
        if auto && (d > 2 || cf < 1000) { return nil }
        if d >= 3 && cf < 50 { return nil }
        // keep the case the user typed
        var out = cand
        if typed == typed.uppercased() && typed.count > 1 { out = cand.uppercased() }
        else if typed.first?.isUppercase == true || NameCase.shared.isName(cand, lang) { out = NameCase.capitalize(cand) }
        return out == typed ? nil : out
    }

    // MARK: entry points from Engine

    /// Word finished with a space or punctuation. Mode 1: offer a plaque; mode 2: replace right away.
    func wordFinished(_ typed: String, lang: Lang, boundary: String) {
        let mode = Settings.shared.spellMode
        guard mode > 0 else { return }
        if indexes.isEmpty { warmUp(); return }
        generation += 1
        let gen = generation
        queue.async {
            guard let fix = self.correction(typed, lang, auto: mode == 2) else { return }
            DispatchQueue.main.async {
                guard gen == self.generation else { return }        // user typed further
                if mode == 2 {
                    self.replace(orig: typed, fix: fix, boundary: boundary)
                    Log.write("spell: auto")
                } else {
                    self.offer = (typed, fix, boundary)
                    self.showPanel(fix)
                    Log.write("spell: offered")
                }
            }
        }
    }

    /// Any key pressed: cancels pending work; returns true if the key was used (Tab / Esc on the plaque).
    func keyDown(code: UInt16, flags: CGEventFlags) -> Bool {
        keysSinceApply += 1
        if isOffering {
            let plain = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
            if code == 48 && plain { accept(); return true }
            if code == 53 && plain { dismiss(); return true }
        }
        generation += 1
        dismiss()
        return false
    }

    func dismiss() {
        offer = nil
        panel.orderOut(nil)
    }

    private func accept() {
        guard let o = offer else { return }
        dismiss()
        replace(orig: o.orig, fix: o.fix, boundary: o.boundary)
        Log.write("spell: accepted")
    }

    private func replace(orig: String, fix: String, boundary: String) {
        Injector.backspaces(orig.count + boundary.count)
        Injector.type(fix + boundary)
        applied = (orig, fix, boundary)
        keysSinceApply = 0
    }

    /// ⌃⌥Z right after a fix: brings back what was typed and remembers the word.
    func undoLast() -> Bool {
        guard let a = applied, keysSinceApply <= 1 else { return false }
        applied = nil
        Injector.backspaces(a.fix.count + a.boundary.count)
        Injector.type(a.orig + a.boundary)
        if let lang = LayoutManager.shared.currentLang {
            let w = TextNorm.normalize(a.orig, lang)
            _ = UserStore.shared.touch(.word, lang, w, uses: 1)
        }
        Log.write("spell: undone")
        return true
    }

    /// Hotkey: fix the word just typed (or being typed). `typed` is on screen, followed by `boundary`.
    func fixNow(_ typed: String, lang: Lang, boundary: String) {
        if indexes.isEmpty { warmUp() }
        queue.async {
            let fix = self.correction(typed, lang, auto: false)
            DispatchQueue.main.async {
                guard let fix = fix else { Notifier.show(L.t("spell.none")); return }
                self.replace(orig: typed, fix: fix, boundary: boundary)
            }
        }
    }

    // MARK: plaque

    private func showPanel(_ fix: String) {
        label.stringValue = "\(fix)  ⇥"
        let size = label.fittingSize
        let w = size.width + 16, h = size.height + 8
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let origin: NSPoint
        if let r = CaretLocator.caretRect() {
            origin = NSPoint(x: r.minX - 4, y: primaryH - r.maxY - h - 4)
        } else {
            let m = NSEvent.mouseLocation
            origin = NSPoint(x: m.x + 12, y: m.y - h - 14)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: false)
        bg.frame = NSRect(x: 0, y: 0, width: w, height: h)
        label.frame = NSRect(x: 8, y: 4, width: size.width, height: size.height)
        panel.display()
        panel.orderFrontRegardless()
    }
}
