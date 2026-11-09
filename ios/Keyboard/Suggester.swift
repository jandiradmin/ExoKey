import UIKit

/// How the user speaks about themself: "я пошёл" / "я пошла" / no preference.
enum Gender: String { case masculine, feminine, none }

/// Word suggestions from the ExoKey dictionaries (same files as on the Mac: word forms with frequencies).
final class Suggester {
    static let shared = Suggester()     // the suggestion worker queue
    static let main = Suggester()       // the main thread: quick word checks (the dictionary reader isn't thread-safe)
    static let next = Suggester()       // the next-letter queue: which letters can continue the word
    private var dicts: [KeyboardLang: WordDictionary] = [:]

    private func dict(_ l: KeyboardLang) -> WordDictionary? {
        if let d = dicts[l] { return d }
        guard let url = Bundle.main.url(forResource: l.rawValue, withExtension: "exd"),
              let d = WordDictionary(url: url, lang: l == .ru ? .ru : .en) else { return nil }
        dicts[l] = d
        return d
    }

    func norm(_ s: String, _ l: KeyboardLang) -> String { TextNorm.normalize(s, l == .ru ? .ru : .en) }
    func freq(_ w: String, _ l: KeyboardLang) -> Int { dict(l)?.freq(w) ?? 0 }

    /// The unverified list (forms the spelling dictionary doesn't confirm) also has real words ("пробую"):
    /// such a form is noise only when a confirmed word one slip away is 20× more frequent ("сегодн" → "сегодня").
    private func unverified(_ w: String, _ l: KeyboardLang) -> Bool { WordSet.unverified(l)?.contains(w) ?? false }

    func isJunk(_ w: String, _ l: KeyboardLang) -> Bool {
        guard unverified(w, l), let d = dict(l) else { return false }
        let f = d.freq(w)
        return oneSlip(w, l, [:]).keys.contains { c in
            let fc = d.freq(c)
            return fc > 20 * max(1, f) && !unverified(c, l)
        }
    }

    func isReal(_ w: String, _ l: KeyboardLang) -> Bool { freq(w, l) > 0 && !isJunk(w, l) }
    func prefixFreq(_ p: String, _ l: KeyboardLang) -> Int { dict(l)?.prefixFreq(p) ?? 0 }

    /// Keys next to each letter on screen: a slip to a neighbour is the usual typo.
    typealias Neighbors = [Character: Set<Character>]

    /// Real words one slip away from a typo, best first. Scores: frequency × how likely the slip is.
    /// `final` — the word is finished (space): compare with the typed word itself; while typing, compare with
    /// everything that starts like it ("hel" stays a beginning of "hello", not a typo of "he").
    func fixes(_ key: String, lang: KeyboardLang, near: Neighbors, final: Bool = false, deep: Bool = false) -> [(w: String, s: Double, p: Double)] {
        guard key.count >= 3, let d = dict(lang) else { return [] }
        // a typed form the spelling dictionary doesn't confirm counts as not a word ("сегодн")
        let typedMass = max(1, final ? (isJunk(key, lang) ? 0 : d.freq(key)) : d.prefixFreq(key))
        // a real word, or the beginning of common words: nothing to fix (and no slow search on every key)
        if typedMass >= (final ? 1000 : 5000) { return [] }
        // a real word, however rare ("отдача", "тактильная"), is never "fixed" into another one
        if final, isReal(key, lang) { return [] }
        var out: [String: (s: Double, p: Double)] = [:]
        // p — how likely the slip itself is; s — frequency × p
        func add(_ w: String, _ f: Int, _ weight: Double) {
            // never into a form the spelling dictionary doesn't know, unless it is common in its own right
            if w.split(separator: " ").contains(where: { unverified(String($0), lang) && d.freq(String($0)) < 1000 }) { return }
            if Double(f) * weight > (out[w]?.s ?? 0) { out[w] = (Double(f) * weight, weight) }
        }
        for (cand, var weight) in oneSlip(key, lang, near) where final || cand.count >= key.count || typedMass <= 1 {
            // "нов" + space is a cut-short word, not "но" with an extra letter
            if final, cand.count < key.count, cand == String(key.dropLast()) { weight *= 0.1 }
            let f = d.freq(cand)
            if f > 20 * typedMass { add(cand, f, weight) }
        }
        // two neighbour keys missed in a short word ("tiu" → "you")
        if key.count <= 4, !near.isEmpty {
            let c = Array(key)
            for i in 0..<c.count {
                for j in (i + 1)..<max(i + 1, c.count) {
                    for a in near[c[i]] ?? [] {
                        for b in near[c[j]] ?? [] {
                            var t = c; t[i] = a; t[j] = b
                            let w = String(t), f = d.freq(w)
                            if f > 20 * typedMass { add(w, f, 0.25) }
                        }
                    }
                }
            }
        }
        // two slips in a longer word ("осдуим" → "обсудим", "фругков" → "фруктов"): the second slip is searched
        // only from first-slip variants that still begin a real word, so it stays fast
        if deep, key.count >= 5, (out.values.map(\.s).max() ?? 0) < 1000 {
            let first = oneSlip(key, lang, near).filter { $0.value >= 0.5 }
            for (v, w1) in first where d.prefixFreq(v) > 0 {
                for (cand, w2) in oneSlip(v, lang, near) where w2 >= 0.5 && cand != key {
                    let f = d.freq(cand)
                    if f >= 1000, f > 20 * typedMass { add(cand, f, w1 * w2 * 0.5) }
                }
            }
        }
        // while typing: a slip in the beginning of a longer word ("встети" → "встретиться")
        if !final {
            var best: (v: String, m: Double)?
            for (v, weight) in oneSlip(key, lang, near) where v.count >= key.count {
                let m = Double(d.prefixFreq(v)) * weight
                if m > 20 * Double(typedMass), m > (best?.m ?? 0) { best = (v, m) }
            }
            if let b = best { for c in d.topK(b.v, k: 2) where out[c.word] == nil { add(c.word, c.freq, 0.5) } }
        }
        // two words: a letter instead of the space, or the space missed ("аюнапример" → "а например")
        let c = Array(key)
        if d.freq(key) == 0, d.prefixFreq(key) <= 1 {
            for i in 1..<c.count {
                for (right, weight) in [(String(c[(i + 1)...]), 0.5), (String(c[i...]), 0.3)] where !right.isEmpty {
                    let left = String(c[..<i])
                    let fl = d.freq(left), fr = d.freq(right)
                    // both real words; a one-letter word only if it is a common one ("а", "и", "I")
                    func ok(_ w: String, _ f: Int) -> Bool { f >= (w.count == 1 ? 1_000_000 : 20_000) }
                    if ok(left, fl), ok(right, fr) { add(left + " " + right, min(fl, fr), weight * 0.5) }
                }
            }
        }
        // the best few, without dictionary noise ("егодн", "подн")
        return Array(out.map { (w: $0.key, s: $0.value.s, p: $0.value.p) }.sorted { $0.s > $1.s }.prefix(8))
            .filter { $0.w.contains(" ") || !isJunk($0.w, lang) }
    }

    /// The fix to make on space: only when the typed word is not a word and one fix clearly wins.
    func autocorrect(_ word: String, lang: KeyboardLang, near: Neighbors, finalFixes: [(w: String, s: Double, p: Double)]? = nil) -> String? {
        guard word.count >= 3, word.allSatisfy({ $0.isLetter }), word.dropFirst().allSatisfy({ $0.isLowercase }) else { return nil }
        let key = norm(word, lang)
        let list = finalFixes ?? fixes(key, lang: lang, near: near, final: true)
        // only into a real, common word (the dictionary also has rare noise like "пожав", "немног")
        // and only by a likely slip: a neighbour key, swapped / missed / doubled letter, a letter for the space
        // (not "нов" → "но", not "млрко" → "марко"); two slips only in a 3-letter word ("tiu" → "you")
        let all = list.filter { $0.w.contains(" ") || freq($0.w, lang) >= 1000 }
        let fx = all.filter { $0.w.contains(" ") || $0.p >= 0.5 || (key.count == 3 && $0.p >= 0.25) }
        guard let best = fx.first else { return nil }
        let second = all.first { $0.w != best.w }?.s ?? 0
        let exact = isJunk(key, lang) ? 0 : Double(freq(key, lang))
        guard best.s >= 3 * second, exact * 100 < best.s else { return nil }
        return best.w
    }

    func suggest(word: String, before: String, lang: KeyboardLang, gender: Gender, near: Neighbors = [:]) -> [String] {
        let key = norm(word, lang)
        guard let d = dict(lang) else { return [] }
        // completions: longer words starting like this, most frequent first
        var cands: [(w: String, f: Int)] = d.topK(key, k: 16, limit: 30000).map { (w: $0.word, f: $0.freq) }
            .filter { !(unverified($0.w, lang) && $0.f < 1000) }
        // a typo: a word one slip away (wrong, missing, extra or swapped letter) that is far more frequent than
        // everything starting like the typed text ("превет" → "привет"; "hel" stays "hello", not "he")
        let fx = fixes(key, lang: lang, near: near)
        if let top = fx.first?.s {
            // fixes keep their order; their "frequency" is set above every completion so the filter below keeps them
            let lift = (cands.map(\.f).max() ?? 0) + 1
            cands = fx.prefix(3).enumerated().map { (w: $0.element.w, f: lift + Int($0.element.s / top * 1000) - $0.offset) } + cands
        }
        // rare look-alikes and dictionary noise ("сегодн") next to a frequent word
        let top = cands.map(\.f).max() ?? 0
        cands.removeAll { $0.f * 200 < top }
        if lang == .ru, aboutMyself(before) {
            if gender != .none {
                cands = cands.map { c in genderForm(c.w, gender, d).map { ($0, c.f) } ?? c }
                // a form that agrees with me ("я сделал") fits better than the infinitive or an adjective
                let opposite: Gender = gender == .masculine ? .feminine : .masculine
                let mine = cands.filter { genderForm($0.w, opposite, d) != nil }
                cands = mine + cands.filter { c in !mine.contains { $0.w == c.w } }
            }
            // "я пошли / я пошло" isn't Russian: plural and neuter past tense go last
            let pairs = [("ли", "л"), ("ло", "л"), ("лись", "лся"), ("лось", "лся")]
            let others = cands.filter { c in pairs.contains { c.w.hasSuffix($0.0) && d.freq(String(c.w.dropLast($0.0.count)) + $0.1) > 0 } }
            cands = cands.filter { c in !others.contains { $0.w == c.w } } + others
        }
        var seen = Set<String>()
        var out = cands.map(\.w).filter { seen.insert($0).inserted }
        out.removeAll { $0 == key }       // the typed word itself isn't a suggestion
        return Array(out.prefix(3))
    }

    private static let alphabet: [KeyboardLang: [Character]] = [
        .ru: Array("абвгдежзийклмнопрстуфхцчшщъыьэюя"), .en: Array("abcdefghijklmnopqrstuvwxyz'"),
    ]

    /// All strings one typing slip away from `w`, with how likely that slip is.
    private func oneSlip(_ w: String, _ lang: KeyboardLang, _ near: Neighbors) -> [String: Double] {
        let c = Array(w), abc = Self.alphabet[lang]!
        var out: [String: Double] = [:]
        func put(_ s: [Character], _ p: Double) { let k = String(s); out[k] = max(out[k] ?? 0, p) }
        let unknownLayout = near.isEmpty
        for i in 0..<c.count {
            // extra letter: likely when it sits next to its neighbour on screen or doubles it
            let adj = (i > 0 && (c[i - 1] == c[i] || near[c[i - 1]]?.contains(c[i]) == true))
                || (i + 1 < c.count && (c[i + 1] == c[i] || near[c[i + 1]]?.contains(c[i]) == true))
            // the first letter is almost always meant ("пмоему" is not "моему")
            put(Array(c[..<i] + c[(i + 1)...]), i == 0 ? 0.2 : (adj ? 0.8 : 0.3))
            if i + 1 < c.count { var t = c; t.swapAt(i, i + 1); put(t, 0.6) }                 // swapped
            for a in abc where a != c[i] {                                                       // wrong letter
                var t = c; t[i] = a
                put(t, unknownLayout ? 0.5 : (near[c[i]]?.contains(a) == true ? 1.0 : 0.12))
            }
        }
        for i in 0...c.count { for a in abc { var t = c; t.insert(a, at: i); put(t, 0.6) } }    // missed letter
        out[w] = nil
        return out
    }

    /// The sentence part before the word speaks about "я": one of its last three words.
    private func aboutMyself(_ before: String) -> Bool {
        let clause = before.split(omittingEmptySubsequences: false, whereSeparator: { ".!?\n,;:".contains($0) }).last ?? ""
        let words = clause.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "-" }).suffix(3)
        return words.contains("я")
    }

    /// The same word in the user's grammatical gender (past tense and short adjectives), only if the dictionary knows it.
    private func genderForm(_ w: String, _ g: Gender, _ d: WordDictionary) -> String? {
        let f0 = d.freq(w)
        // a real counterpart, not a rare look-alike ("так" → "така")
        func real(_ s: String) -> String? { let f = d.freq(s); return f > 0 && f * 50 >= f0 ? s : nil }
        let chars = Array(w)
        let vowels = Set("аеёиоуыэюя")
        switch g {
        case .feminine:
            if w.hasSuffix("лся") { return real(String(w.dropLast(3)) + "лась") }
            guard let last = chars.last, !vowels.contains(last), last != "ь", last != "й" else { return nil }
            if let f = real(w + "а") { return f }                                       // ходил → ходила, рад → рада
            if chars.count >= 3, "еоё".contains(chars[chars.count - 2]) {               // пошел → пошла, должен → должна
                return real(String(chars.dropLast(2)) + String(last) + "а")
            }
            return nil
        case .masculine:
            if w.hasSuffix("лась") { return real(String(w.dropLast(4)) + "лся") }
            guard w.hasSuffix("ла") || w.hasSuffix("на"), chars.count >= 3 else { return nil }
            let base = String(chars.dropLast())                                          // ходила → ходил
            if let m = real(base) { return m }
            return real(String(chars.dropLast(2)) + "е" + String(chars[chars.count - 2])) // пошла → пошел, должна → должен
        case .none:
            return nil
        }
    }
}
