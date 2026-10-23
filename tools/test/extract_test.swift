import Foundation
enum P {
    static func extract(_ raw: String, afterSpace: Bool, midWord: Bool, maxWords: Int, cut: Bool) -> String {
        var s = raw
        if afterSpace {
            guard s.first == " " else { return "" }       // model glued text to the previous word
            s.removeFirst()
        }
        if let nl = s.firstIndex(where: \.isNewline) { s = String(s[..<nl]) }
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
        while let l = out.last, l == " " || l == "," || l == ";" || l == ":" || l == "—" { out.removeLast() }
        guard out.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
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
]
for c in cases { print("[\(P.extract(c.0, afterSpace: c.1, midWord: c.2, maxWords: c.3, cut: c.4))]") }
