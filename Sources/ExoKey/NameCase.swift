import Foundation

/// Proper names: which words are written with a capital letter ("Марина", "Олег", "Київ").
/// Source: Hunspell forms that exist only capitalized + what the user actually types.
final class NameCase {
    static let shared = NameCase()
    private var names: [Lang: Set<String>] = [:]
    private let store = UserStore.shared

    private init() {
        DispatchQueue.global(qos: .utility).async {
            var loaded: [Lang: Set<String>] = [:]
            for l in Lang.allCases {
                guard let u = Bundle.main.resourceURL?.appendingPathComponent("\(l.rawValue).names"),
                      let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
                loaded[l] = Set(text.split(separator: "\n").map(String.init))
            }
            DispatchQueue.main.async { self.names = loaded }
        }
    }

    /// `lower` is a normalized lowercase word.
    func isName(_ lower: String, _ l: Lang) -> Bool {
        guard lower.count >= 2 else { return false }
        let cap = store.count("cap:\(l.rawValue):\(lower)")
        let low = store.count("low:\(l.rawValue):\(lower)")
        if cap >= 2 && cap > low { return true }      // the user writes it capitalized
        if low >= 2 && low >= cap { return false }    // the user writes it lowercase
        return names[l]?.contains(lower) ?? false
    }

    func isDictName(_ lower: String, _ l: Lang) -> Bool { names[l]?.contains(lower) ?? false }

    /// Learn from a finished word typed by the user (not at the start of a sentence).
    func learn(lower: String, capitalized: Bool, _ l: Lang) {
        guard lower.count >= 2 else { return }
        if capitalized {
            store.bump("cap:\(l.rawValue):\(lower)")
        } else if isDictName(lower, l) || store.count("cap:\(l.rawValue):\(lower)") > 0 {
            store.bump("low:\(l.rawValue):\(lower)")
        }
    }

    /// "марина" → "Марина", "лос-анджелес" → "Лос-Анджелес", "ростов-на-дону" → "Ростов-на-Дону"
    static func capitalize(_ w: String) -> String {
        w.split(separator: "-", omittingEmptySubsequences: false).enumerated().map { i, p in
            (i == 0 || p.count > 2) ? p.prefix(1).uppercased() + p.dropFirst() : String(p)
        }.joined(separator: "-")
    }

    /// Capitalizes lowercase names inside a suggestion.
    func fixWords(_ text: String, _ l: Lang) -> String {
        var out = "", word = ""
        func flush() {
            guard !word.isEmpty else { return }
            if word == word.lowercased(), isName(TextNorm.normalize(word, l), l) { out += Self.capitalize(word) } else { out += word }
            word = ""
        }
        for ch in text {
            if ch.isLetter || ch == "'" || ch == "’" || ch == "-" { word.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        return out
    }
}
