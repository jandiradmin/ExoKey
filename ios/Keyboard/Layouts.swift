import UIKit

enum KeyboardLang: String, CaseIterable {
    case en, ru
    var title: String { self == .en ? "English" : "Русский" }
    var locale: String { self == .en ? "en-US" : "ru-RU" }
    var next: KeyboardLang { self == .en ? .ru : .en }
}

enum KeyKind: Equatable {
    case char(String)     // lowercase text the key types
    case shift, backspace, symbols, letters, globe, space, ret
}

struct Key {
    let kind: KeyKind
    var alts: [String] = []       // long press
    var width: CGFloat = 1        // in letter-key units; a row is `Layouts.grid` units wide
    var isDigit = false
}

enum Layouts {
    /// Row width in letter keys: 9 Russian letters + ⇧ + ⌫ fit, so every letter key has the same size in every layout.
    static let grid: CGFloat = 11
    static let edge: CGFloat = 1.0       // ⇧ and ⌫, the same in every layout

    private static func row(_ s: String, alts: [Character: [String]] = [:]) -> [Key] {
        s.map { Key(kind: .char(String($0)), alts: alts[$0] ?? []) }
    }

    static let digits: [Key] = {
        let shifted: [Character: String] = ["1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
                                            "6": "^", "7": "&", "8": "*", "9": "(", "0": ")"]
        return "1234567890".map { Key(kind: .char(String($0)), alts: [shifted[$0]!], isDigit: true) }
    }()

    /// Rare letters live on a long press so the keys of the common ones are wider.
    static func letters(_ lang: KeyboardLang) -> [[Key]] {
        switch lang {
        case .en:
            return [
                row("qwertyuiop", alts: ["e": ["é", "è", "ê", "ë"], "u": ["ú", "ü"], "i": ["í", "ï"], "o": ["ó", "ö"]]),
                row("asdfghjkl", alts: ["a": ["á", "à", "ä"], "s": ["ß"]]),
                [Key(kind: .shift, width: edge)] + row("zxcvbnm", alts: ["c": ["ç"], "n": ["ñ"]]) + [Key(kind: .backspace, width: edge)],
            ]
        case .ru:
            return [
                row("йцукенгшщзх", alts: ["е": ["ё"], "х": ["ъ"]]),
                row("фывапролджэ"),
                [Key(kind: .shift, width: edge)] + row("ячсмитьбю", alts: ["ь": ["ъ"]]) + [Key(kind: .backspace, width: edge)],
            ]
        }
    }

    static let symbols: [[Key]] = [
        row("-/:;()$&@\"", alts: ["$": ["€", "₴", "£", "¥"], "-": ["–", "—"], "\"": ["«", "»", "„", "“", "”"]]),
        row("[]{}#%^*+=", alts: ["%": ["‰"], "=": ["≈", "≠"]]),
        [Key(kind: .char("_"), width: 1)] + row("\\|~<>'`") + [Key(kind: .char("…")), Key(kind: .backspace, width: edge)],
    ]

    static func bottom(symbolsMode: Bool, globe: Bool) -> [Key] {
        var r = [Key(kind: symbolsMode ? .letters : .symbols, width: 1.4)]
        if globe { r.append(Key(kind: .globe, width: 1.1)) }
        r.append(Key(kind: .space))
        r.append(Key(kind: .char("."), alts: ["?", ",", "!", "'", "\"", "-", ":", ";"], width: 1.1))
        r.append(Key(kind: .ret, width: 1.9))
        return r
    }
}
