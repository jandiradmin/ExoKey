import Foundation

/// Inline calculator: typing "2+2=" appends "4".
enum Calculator {
    static let allowed = Set("0123456789+-*/×÷^%()., ")

    /// Evaluates expression, nil if it is not a real calculation.
    static func evaluate(_ raw: String) -> String? {
        let expr = raw.trimmingCharacters(in: .whitespaces)
        guard expr.count >= 3, expr.contains(where: \.isNumber) else { return nil }
        let hasOp = expr.dropFirst().contains { "+-*/×÷^%".contains($0) }
        guard hasOp else { return nil }
        // dates like 12/10/2026 or phone numbers 050-307-27-27: skip
        if expr.allSatisfy({ $0.isNumber || $0 == "/" }) && expr.filter({ $0 == "/" }).count >= 2 { return nil }
        if expr.allSatisfy({ $0.isNumber || $0 == "-" }) && expr.filter({ $0 == "-" }).count >= 2 { return nil }
        let comma = expr.contains(",") && !expr.contains(".")
        var p = Parser(Array(expr.replacingOccurrences(of: ",", with: ".").filter { $0 != " " }))
        guard let v = p.parseExpr(), p.atEnd, v.isFinite else { return nil }
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

    private struct Parser {
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
            var s = ""
            while let ch = peek(), ch.isNumber || ch == "." { s.append(ch); i += 1 }
            return Double(s)
        }
    }
}
