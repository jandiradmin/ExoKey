import Foundation
enum P {
    static func extract(_ raw: String, afterSpace: Bool, midWord: Bool, maxWords: Int, cut: Bool) -> String {
        var s = raw
        if afterSpace {
            guard s.first == " " else { return "" }       // model glued text to the previous word
            s.removeFirst()
        }
        if let nl = s.firstIndex(where: \.isNewline) { s = String(s[..<nl]) }
        // escaped junk like "\n\n\n", markup, code
        if let bad = s.firstIndex(where: { "\\{}<>[]|`#*_=~^".contains($0) }) { s = String(s[..<bad]) }
        var out = ""
        var words = 0
        var inWord = midWord && (s.first?.isLetter ?? false)
        var ended = false
        var stoppedEarly = false
        for ch in s {
            let isW = ch.isLetter || ch.isNumber || ch == "'" || ch == "’" || ch == "-"
            if isW {
                if !inWord { inWord = true }
            } else if inWord {
                inWord = false
                words += 1
                if words >= maxWords && ch == " " { stoppedEarly = true; break }
            }
            out.append(ch)
            if ".!?…".contains(ch) { ended = true; break }
            if out.count >= 120 { stoppedEarly = true; break }
        }
        // the last word may be unfinished if the model hit the token limit
        if !ended, !stoppedEarly, cut, inWord, let sp = out.lastIndex(of: " "), sp != out.startIndex {
            out = String(out[..<sp])
        }
        while let l = out.last, l == " " || l == "," || l == ";" || l == ":" || l == "—" || l == "(" || l == "\"" { out.removeLast() }
        // must be mostly letters, and no long runs of the same character
        let letters = out.filter { $0.isLetter }.count
        guard letters >= 1, Double(letters) / Double(max(1, out.filter { $0 != " " }.count)) > 0.6 else { return "" }
        var run = 1, prev: Character? = nil
        for ch in out { run = ch == prev ? run + 1 : 1; prev = ch; if run >= 4 { return "" } }
        return out
    }

}
let cases: [(String, Bool, Bool, Int, Bool)] = [
  (" подписать договор. Однако, у нас", true, false, 8, true),
  (" виправити помилки", true, false, 8, true),
  ("ете, как у тебя дела", false, true, 8, true),
  (" и", false, true, 8, false),
  ("ание", false, true, 8, false),
  (" будет встреча по вопросу \"Пов", true, false, 8, true),
  (" updated version of the document. I have", true, false, 3, true),
  ("ять", false, true, 1, true),
  (" \\n\\n\\n\\n\\n", true, false, 8, true),
  ("\\n\\n\\n", false, true, 8, true),
  (" вас... ...", true, false, 8, false),
]
for c in cases { print("[\(P.extract(c.0, afterSpace: c.1, midWord: c.2, maxWords: c.3, cut: c.4))]") }
