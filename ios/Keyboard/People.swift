import UIKit

/// Contact names and e-mails for the keyboard: names from iOS (the supplementary lexicon), e-mails from the app
/// (contacts.json in the app group) and the user's own addresses.
final class People {
    static let shared = People()
    private(set) var names: [String] = []                 // display forms: "Виталий", "Ткачишин"
    private(set) var emails: [(email: String, name: String)] = []

    func reload(_ controller: UIInputViewController) {
        guard KLog.defaults.object(forKey: "contacts") as? Bool ?? true else { names = []; emails = []; return }
        var set = Set<String>()
        controller.requestSupplementaryLexicon { [weak self] lex in
            for e in lex.entries where e.userInput.first?.isUppercase == true && e.userInput.allSatisfy({ $0.isLetter || $0 == "-" }) {
                set.insert(e.userInput)
            }
            var emails: [(String, String)] = []
            let mine = (KLog.defaults.string(forKey: "myEmails") ?? "")
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map(String.init).filter { $0.contains("@") }
            emails += mine.map { ($0, "") }
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KLog.group)?.appendingPathComponent("contacts.json"),
               let data = try? Data(contentsOf: url),
               let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for c in list {
                    let n = c["n"] as? String ?? ""
                    for part in n.split(separator: " ") where part.count > 1 { set.insert(String(part)) }
                    for e in c["e"] as? [String] ?? [] { emails.append((e, n + " " + (c["k"] as? String ?? ""))) }
                }
            }
            DispatchQueue.main.async {
                self?.names = Array(set)
                self?.emails = emails
                KLog.write("people: names=\(set.count) emails=\(emails.count) mine=\(mine.count)")
            }
        }
    }

    /// E-mails for what is being typed: "vit@" → Vitaliy's address, "jan" → jandir@…; in an e-mail field any start.
    func emails(for token: String, emailField: Bool) -> [String] {
        let t = token.lowercased()
        if t.isEmpty { return emailField ? emails.prefix(3).map(\.email) : [] }
        var out: [String] = []
        if let at = t.firstIndex(of: "@") {
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

    func isName(_ w: String) -> Bool { let l = w.lowercased(); return names.contains { $0.lowercased() == l } }
}
