import UIKit

/// Contact names and e-mails for the keyboard: names from iOS (the supplementary lexicon), e-mails from the app
/// (contacts.json in the app group) and the user's own addresses.
final class People {
    static let shared = People()
    private(set) var names: [String] = []                 // display forms: "Виталий", "Ткачишин"
    private(set) var emails: [(email: String, name: String)] = []
    struct Contact { let name: String; let phones: [String]; let emails: [String]; let company: String; let tokens: [String] }
    private(set) var contacts: [Contact] = []

    func reload(_ controller: UIInputViewController) {
        guard KLog.defaults.object(forKey: "contacts") as? Bool ?? true else { names = []; emails = []; return }
        var set = Set<String>()
        controller.requestSupplementaryLexicon { [weak self] lex in
            for e in lex.entries where e.userInput.first?.isUppercase == true && e.userInput.allSatisfy({ $0.isLetter || $0 == "-" }) {
                set.insert(e.userInput)
            }
            var emails: [(String, String)] = []
            var contacts: [Contact] = []
            let mine = (KLog.defaults.string(forKey: "myEmails") ?? "")
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map(String.init).filter { $0.contains("@") }
            emails += mine.map { ($0, "") }
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KLog.group)?.appendingPathComponent("contacts.json"),
               let data = try? Data(contentsOf: url),
               let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for c in list {
                    let n = c["n"] as? String ?? ""
                    let o = c["o"] as? String ?? ""
                    let full = n.isEmpty ? o : n
                    if !full.isEmpty {
                        let toks = (full.split(separator: " ").map(String.init) + [c["k"] as? String ?? "", o]).map(Self.norm).filter { !$0.isEmpty }
                        contacts.append(Contact(name: full, phones: c["p"] as? [String] ?? [], emails: c["e"] as? [String] ?? [], company: o, tokens: toks))
                    }
                    // a name is written with a capital: "мойка", "муж" in a contact card are not names
                    for part in n.split(separator: " ") where part.count > 1 && part.first?.isUppercase == true { set.insert(String(part)) }
                    for e in c["e"] as? [String] ?? [] { emails.append((e, n + " " + (c["k"] as? String ?? ""))) }
                }
            }
            DispatchQueue.main.async {
                self?.names = Array(set)
                self?.emails = emails
                self?.contacts = contacts
                KLog.write("people: names=\(set.count) emails=\(emails.count) mine=\(mine.count)")
            }
        }
    }

    /// E-mails for what is being typed: "vit@" → Vitaliy's address, "jan" → jandir@…; in an e-mail field any start.
    func emails(for token: String, emailField: Bool) -> [String] {
        let t = token.lowercased()
        if t.isEmpty { return emailField ? emails.prefix(3).map(\.email) : [] }
        var out: [String] = []
        if t.hasPrefix("@") {
            return []
        } else if let at = t.firstIndex(of: "@") {
            let who = String(t[..<at])
            out += emails.filter { $0.email.lowercased().hasPrefix(t) }.map(\.email)
            if t.hasSuffix("@"), who.count >= 2 {
                out += emails.filter { e in e.name.lowercased().split(separator: " ").contains { $0.hasPrefix(who) } }.map(\.email)
            }
        } else if emailField {
            out += emails.filter { $0.email.lowercased().hasPrefix(t) }.map(\.email)
            do { out += emails.filter { e in e.name.lowercased().split(separator: " ").contains { $0.hasPrefix(t) } }.map(\.email) }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Contact names starting like the typed word (≥ 2 letters).
    func names(startingWith w: String) -> [String] {
        guard w.count >= 2 else { return [] }
        let l = w.lowercased()
        return names.filter { $0.lowercased().hasPrefix(l) && $0.count > w.count }.sorted { $0.count < $1.count }
    }

    /// Contact names one typing slip away (a letter wrong, missed, extra or two swapped): "Виталй" → "Виталий".
    /// Static over a copy of `names`, so it runs on the suggestion queue.
    static func slips(_ w: String, in names: [String]) -> [String] {
        let a = Array(w.lowercased())
        guard a.count >= 3 else { return [] }
        return names.filter { n in
            let b = Array(n.lowercased())
            guard abs(a.count - b.count) <= 1, a != b, a.first == b.first || a.count == b.count else { return false }
            if a.count == b.count {
                let d = (0..<a.count).filter { a[$0] != b[$0] }
                return d.count == 1 || (d.count == 2 && d[1] == d[0] + 1 && a[d[0]] == b[d[1]] && a[d[1]] == b[d[0]])
            }
            let (s, l) = a.count < b.count ? (a, b) : (b, a)
            var i = 0
            while i < s.count, s[i] == l[i] { i += 1 }
            return Array(s[i...]) == Array(l[(i + 1)...])
        }
    }

    static func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "ё", with: "е") }

    /// "@мар" → the contacts with a name, nickname or company starting so (first names first).
    func matching(_ q: String) -> [Contact] {
        let q = Self.norm(q)
        guard !q.isEmpty else { return [] }
        return contacts.compactMap { c -> (Int, Contact)? in
            guard let i = c.tokens.firstIndex(where: { $0.hasPrefix(q) }) else { return nil }
            return (i, c)
        }.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.name.localizedCompare($1.1.name) == .orderedAscending }.map(\.1)
    }

    func isName(_ w: String) -> Bool { let l = w.lowercased(); return names.contains { $0.lowercased() == l } }
}
