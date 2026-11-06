import AppKit
import ApplicationServices

/// Inline calculator: typing "2+2=" appends "4".
enum Calculator {
    static let allowed = Set("0123456789+-*/×÷^%()., :")

    /// Text of the current line before the caret, via Accessibility (sees edits the key buffer can't).
    static func lineBeforeCaret() -> String? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.15)
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &f) == .success,
              let v = f, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let e = v as! AXUIElement
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXValueAttribute as CFString, &val) == .success,
              let full = val as? String else { return nil }
        var rr: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, &rr) == .success,
              let r = rr, CFGetTypeID(r) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        AXValueGetValue(r as! AXValue, .cfRange, &range)
        let ns = full as NSString
        guard range.length == 0, range.location > 0, range.location <= ns.length else { return nil }
        let start = max(0, range.location - 300)
        let before = ns.substring(with: NSRange(location: start, length: range.location - start))
        return before.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init)
    }

    /// The expression at the end of a line: after the last "=" (chains like 600*2=1200+200=), digits and operators only.
    static func tail(_ line: String) -> String {
        var s = Substring(line)
        if let i = s.lastIndex(of: "=") { s = s[s.index(after: i)...] }
        var chars: [Character] = []
        // digits, operators and Latin function names (sin, sqrt, pi…)
        for ch in s.reversed() {
            if allowed.contains(ch) || ch == "°" || ch == "π" || (ch.isASCII && ch.isLetter) { chars.append(ch) } else { break }
        }
        var e = String(chars.reversed())
        // drop leading words that are not functions ("total sin(1)" → "sin(1)")
        while true {
            while let c = e.first, !(c.isNumber || c == "(" || c == "-" || c == "π" || c.isLetter) { e.removeFirst() }
            let word = String(e.prefix { $0.isLetter })
            if word.isEmpty || Parser.names.contains(word.lowercased()) { break }
            e.removeFirst(word.count)
        }
        return e
    }

    /// Times: "10:00:00+12:00:00" → "22:00:00", "1:30*3" → "4:30", "18:45-9:30" → "9:15".
    static func evaluateTime(_ expr: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\\b(\\d{1,3}):(\\d{2})(?::(\\d{2}))?\\b") else { return nil }
        let ns = expr as NSString
        let ms = re.matches(in: expr, range: NSRange(location: 0, length: ns.length))
        guard !ms.isEmpty else { return nil }
        var withSeconds = false
        var out = expr
        for m in ms.reversed() {
            let h = Int(ns.substring(with: m.range(at: 1))) ?? 0, mi = Int(ns.substring(with: m.range(at: 2))) ?? 0
            var sec = 0
            if m.range(at: 3).location != NSNotFound { sec = Int(ns.substring(with: m.range(at: 3))) ?? 0; withSeconds = true }
            guard mi < 60, sec < 60 else { return nil }
            out = (out as NSString).replacingCharacters(in: m.range, with: String(h * 3600 + mi * 60 + sec))
        }
        guard out.contains(where: { "+-*/×÷".contains($0) }), !out.contains(":") else { return nil }
        var p = Parser(Array(out.replacingOccurrences(of: ",", with: ".").filter { $0 != " " }))
        guard let v = p.parseExpr(), p.atEnd, v.isFinite else { return nil }
        let total = Int(v.rounded())
        let a = abs(total)
        let hh = a / 3600, mm = (a % 3600) / 60, ss = a % 60
        let sign = total < 0 ? "-" : ""
        return withSeconds || ss != 0 ? String(format: "%@%d:%02d:%02d", sign, hh, mm, ss) : String(format: "%@%d:%02d", sign, hh, mm)
    }

    /// Evaluates expression, nil if it is not a real calculation.
    static func evaluate(_ raw: String) -> String? {
        if raw.contains(":") { return evaluateTime(raw.trimmingCharacters(in: .whitespaces)) }
        let expr = raw.trimmingCharacters(in: .whitespaces)
        let lower = expr.lowercased()
        let hasFunc = Parser.names.contains { lower.contains($0 + "(") } || lower.contains("π") || lower.contains("pi")
        guard expr.count >= 3 || hasFunc, expr.contains(where: \.isNumber) || hasFunc else { return nil }
        let hasOp = expr.dropFirst().contains { "+-*/×÷^%".contains($0) }
        guard hasOp || hasFunc else { return nil }
        // dates like 12/10/2026 or phone numbers 050-307-27-27: skip
        if expr.allSatisfy({ $0.isNumber || $0 == "/" }) && expr.filter({ $0 == "/" }).count >= 2 { return nil }
        if expr.allSatisfy({ $0.isNumber || $0 == "-" }) && expr.filter({ $0 == "-" }).count >= 2 { return nil }
        let comma = expr.contains(",") && !expr.contains(".")
        var p = Parser(Array(expr.replacingOccurrences(of: ",", with: ".").filter { $0 != " " }))
        guard var v = p.parseExpr(), p.atEnd, v.isFinite else { return nil }
        if abs(v) < 1e-12 { v = 0 }                       // sin(π) = 0, not 1.2e-16
        return format(v, comma: comma)
    }

    static func format(_ v: Double, comma: Bool) -> String {
        var s: String
        if v == v.rounded(), abs(v) < 1e15 {
            s = String(Int64(v))
        } else {
            s = String(format: "%.10g", v)
            if s.contains("."), !s.contains("e") {
                while s.hasSuffix("0") { s.removeLast() }
                if s.hasSuffix(".") { s.removeLast() }
            }
        }
        return comma ? s.replacingOccurrences(of: ".", with: ",") : s
    }

    struct Parser {
        static let functions: [String: (Double) -> Double] = [
            "sin": sin, "cos": cos, "tan": tan, "tg": tan, "asin": asin, "acos": acos, "atan": atan,
            "sqrt": sqrt, "ln": log, "log": log10, "lg": log10, "exp": exp, "abs": { Swift.abs($0) },
            "round": { $0.rounded() }, "floor": floor, "ceil": ceil,
        ]
        static let constants: [String: Double] = ["pi": .pi, "e": M_E]
        static let names = Set(functions.keys).union(constants.keys)
        let c: [Character]
        var i = 0
        init(_ c: [Character]) { self.c = c }
        var atEnd: Bool { i == c.count }
        func peek() -> Character? { i < c.count ? c[i] : nil }

        mutating func parseExpr() -> Double? {
            guard var v = parseTerm() else { return nil }
            while let ch = peek(), ch == "+" || ch == "-" {
                i += 1
                guard var r = parseTerm() else { return nil }
                if peek() == "%" { i += 1; r = v * r / 100 }   // 200+10% = 220
                v = ch == "+" ? v + r : v - r
            }
            return v
        }

        mutating func parseTerm() -> Double? {
            guard var v = parsePow() else { return nil }
            while let ch = peek(), "*/×÷".contains(ch) {
                i += 1
                guard var r = parsePow() else { return nil }
                if peek() == "%" { i += 1; r /= 100 }
                if ch == "*" || ch == "×" { v *= r } else { if r == 0 { return nil }; v /= r }
            }
            return v
        }

        mutating func parsePow() -> Double? {
            guard let b = parseUnary() else { return nil }
            if peek() == "^" {
                i += 1
                guard let e = parsePow() else { return nil }
                return pow(b, e)
            }
            return b
        }

        mutating func parseUnary() -> Double? {
            if peek() == "-" { i += 1; return parseUnary().map { -$0 } }
            if peek() == "+" { i += 1; return parseUnary() }
            return parseAtom()
        }

        mutating func parseAtom() -> Double? {
            if peek() == "(" {
                i += 1
                guard let v = parseExpr(), peek() == ")" else { return nil }
                i += 1
                return v
            }
            if peek() == "π" { i += 1; return .pi }
            if let ch = peek(), ch.isLetter {
                var name = ""
                while let ch = peek(), ch.isLetter { name.append(ch); i += 1 }
                name = name.lowercased()
                if let k = Self.constants[name] { return k }
                guard let f = Self.functions[name], peek() == "(" else { return nil }
                guard let arg = parseAtom() else { return nil }      // "(…)"
                return f(arg)
            }
            var s = ""
            while let ch = peek(), ch.isNumber || ch == "." { s.append(ch); i += 1 }
            guard var v = Double(s) else { return nil }
            if peek() == "°" { i += 1; v *= .pi / 180 }               // sin(30°)
            return v
        }
    }
}
