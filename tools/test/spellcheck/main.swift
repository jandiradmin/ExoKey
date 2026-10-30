import Foundation
// Standalone check of SpellIndex on the built dictionaries (no app UI).
let root = URL(fileURLWithPath: CommandLine.arguments[1])
for (l, words) in [(Lang.ru, ["хорактестиски", "првиет", "спасиюо", "кнечно", "пожалуйчта", "сегодян", "мостик", "гугл"]),
                   (Lang.uk, ["дякуюю", "звичано", "хорактеристики"]),
                   (Lang.en, ["teh", "recieve", "tommorow", "definately", "wierd", "gonna"])] {
    guard let d = WordDictionary(url: root.appendingPathComponent("\(l.rawValue).exd"), lang: l) else { continue }
    let ix = SpellIndex(lang: l, unverifiedURL: root.appendingPathComponent("\(l.rawValue).unverified"))
    let t0 = Date(); ix.build(d); print(l.rawValue, "index", Int(Date().timeIntervalSince(t0) * 1000), "ms")
    for w in words {
        let t = Date()
        let wf = d.freq(w)
        let known = wf > 0 && (!ix.isUnverified(w) || wf >= 2000)
        let r = known ? nil : ix.best(for: w)
        print("  \(w) ->", known ? "known" : (r.map { "\($0.1) d=\($0.0)" } ?? "—"), Int(Date().timeIntervalSince(t) * 1000), "ms")
    }
}
