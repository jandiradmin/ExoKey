import Foundation

/// What the user writes after what: word pairs and triples learned from their own typing ("доброе" → "утро",
/// "спасибо большое" → "за"). Kept on the phone (the app group folder); used to suggest the next word / phrase.
final class NGrams {
    static let shared = NGrams()

    /// "w1" → next → count, "w1 w2" → next → count (lower case)
    private var next: [String: [String: Int]] = [:]
    private var dirty = false
    private let saveQueue = DispatchQueue(label: "ngrams-save", qos: .utility)
    private static let maxContexts = 30_000

    private let url: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KLog.group)?
        .appendingPathComponent("Library/ngrams.json")

    private init() {
        if let u = url, let d = try? Data(contentsOf: u), let m = try? JSONDecoder().decode([String: [String: Int]].self, from: d) {
            next = m
        }
    }

    /// The words of the current sentence before the cursor (lower case, letters only): a new sentence starts fresh.
    static func sentenceWords(_ before: String) -> [String] {
        let sentence = before.split(omittingEmptySubsequences: false, whereSeparator: { ".!?\n".contains($0) }).last ?? ""
        return sentence.lowercased().split(whereSeparator: { !($0.isLetter || $0 == "-" || $0 == "'" || $0 == "’") }).map(String.init)
    }

    /// Learns the last word of `words` after the one/two before it.
    func learn(_ words: [String]) {
        guard let w = words.last, w.count >= 1 else { return }
        let n = words.count
        if n >= 2 { bump(words[n - 2], w) }
        if n >= 3 { bump(words[n - 3] + " " + words[n - 2], w) }
        dirty = true
        scheduleSave()
    }

    private func bump(_ ctx: String, _ w: String) {
        if next[ctx] == nil, next.count >= Self.maxContexts {
            // forget the contexts seen least
            let weakest = next.min { $0.value.values.reduce(0, +) < $1.value.values.reduce(0, +) }?.key
            if let k = weakest { next[k] = nil }
        }
        next[ctx, default: [:]][w, default: 0] += 1
    }

    /// Next words after the sentence so far, most likely first: the last two words, then the last one.
    /// Seen at least twice and a good share of the times; more frequent ones go first.
    func predict(after words: [String], limit: Int = 3) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ ctx: String) {
            let m = next[ctx] ?? [:], total = m.values.reduce(0, +)
            // a habit: written here at least twice and at least a quarter of the times
            // (once is chance: "for it" → "possible to", "на" → "траве")
            for (w, c) in m.sorted(by: { $0.value > $1.value }) where c >= 2 && c * 4 >= total && seen.insert(w).inserted {
                out.append(w)
            }
        }
        let n = words.count
        if n >= 2 { add(words[n - 2] + " " + words[n - 1]) }
        if n >= 1 { add(words[n - 1]) }
        return Array(out.prefix(limit))
    }

    /// A short phrase: the likely next word and, if it is also a habit, the word after it ("доброе" → "утро всем").
    func phrase(after words: [String]) -> String? {
        guard let w1 = predict(after: words, limit: 1).first else { return nil }
        guard let w2 = predict(after: words + [w1], limit: 1).first else { return nil }
        return w1 + " " + w2
    }

    /// How often `w` followed the last word(s): to rank completions of the word being typed.
    func count(of w: String, after words: [String]) -> Int {
        let n = words.count
        var c = 0
        if n >= 1 { c += next[words[n - 1]]?[w] ?? 0 }
        if n >= 2 { c += 3 * (next[words[n - 2] + " " + words[n - 1]]?[w] ?? 0) }
        return c
    }

    private var saveScheduled = false

    /// Written a few seconds after the last word, off the main thread.
    private func scheduleSave() {
        guard dirty, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            saveScheduled = false
            dirty = false
            let snapshot = next, u = url
            saveQueue.async {
                guard let u, let d = try? JSONEncoder().encode(snapshot) else { return }
                try? d.write(to: u, options: .atomic)
            }
        }
    }
}
