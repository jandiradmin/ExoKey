import Foundation

/// "1 pound in kg =", "5 miles to km =", "100 F in C =", "25 usd/uah =", "100 € в грн =".
/// Units are converted locally; currency rates are downloaded at most every 12 hours (only the rate table).
enum Converter {
    private enum Kind { case length, mass, volume, area, speed, temp, money }
    private struct Unit { let kind: Kind; let factor: Double }   // to the base unit (m, kg, l, m², m/s)

    private static let units: [String: Unit] = {
        var u: [String: Unit] = [:]
        func add(_ k: Kind, _ f: Double, _ names: String) { for n in names.split(separator: " ") { u[String(n)] = Unit(kind: k, factor: f) } }
        add(.length, 0.001, "mm мм миллиметр миллиметра миллиметров міліметр")
        add(.length, 0.01, "cm см сантиметр сантиметра сантиметров")
        add(.length, 1, "m м meter meters metre метр метра метров метри")
        add(.length, 1000, "km км kilometer kilometers километр километра километров кілометр кілометри кілометрів")
        add(.length, 0.0254, "in inch inches дюйм дюйма дюймов дюйми дюймів")
        add(.length, 0.3048, "ft foot feet фут фута футов фути футів")
        add(.length, 0.9144, "yd yard yards ярд ярда ярдов")
        add(.length, 1609.344, "mi mile miles миля мили миль милі")
        add(.length, 1852, "nmi морская")
        add(.mass, 1e-6, "mg мг")
        add(.mass, 0.001, "g г gram grams грамм грамма граммов грам грами грамів")
        add(.mass, 1, "kg кг kilogram kilograms килограмм килограмма килограммов кілограм кілограми кілограмів")
        add(.mass, 1000, "t т ton tons tonne tonnes тонна тонны тонн тонни")
        add(.mass, 0.45359237, "lb lbs pound pounds фунт фунта фунтов фунти фунтів")
        add(.mass, 0.028349523125, "oz ounce ounces унция унции унций унція")
        add(.volume, 0.001, "ml мл")
        add(.volume, 1, "l л liter liters litre litres литр литра литров літр літри літрів")
        add(.volume, 3.785411784, "gal gallon gallons галлон галлона галлонов галон")
        add(.volume, 0.946352946, "qt quart quarts")
        add(.volume, 0.0295735295625, "floz")
        add(.volume, 1000, "m3 м3 м³")
        add(.area, 1, "m2 м2 м²")
        add(.area, 1e6, "km2 км2 км²")
        add(.area, 1e4, "ha га гектар гектара гектаров")
        add(.area, 4046.8564224, "acre acres акр акра акров")
        add(.area, 0.09290304, "sqft ft2")
        add(.speed, 1, "m/s м/с")
        add(.speed, 1 / 3.6, "km/h kmh kph км/ч км/год")
        add(.speed, 0.44704, "mph")
        add(.speed, 0.514444, "kn knot knots узел узла узлов вузол")
        for t in ["c", "°c", "с", "°с", "celsius", "цельсий", "f", "°f", "fahrenheit", "фаренгейт", "k", "kelvin", "кельвин"] {
            u[t] = Unit(kind: .temp, factor: 0)
        }
        return u
    }()

    /// Currency words and symbols → ISO code.
    private static let money: [String: String] = {
        var m: [String: String] = [:]
        func add(_ code: String, _ names: String) { for n in names.split(separator: " ") { m[String(n)] = code } }
        add("USD", "usd $ доллар доллара долларов долар долари доларів бакс баксов")
        add("EUR", "eur € евро євро")
        add("UAH", "uah ₴ грн гривна гривны гривен гривня гривні гривень")
        add("GBP", "gbp £ стерлинг")
        add("PLN", "pln злотый злотых злотий")
        add("CAD", "cad")
        add("CNY", "cny юань юаня юаней")
        add("JPY", "jpy ¥ иена иен")
        add("CHF", "chf франк франков")
        add("TRY", "try лира лир")
        add("CZK", "czk крона крон")
        add("KZT", "kzt тенге")
        add("GEL", "gel лари")
        add("AED", "aed дирхам")
        return m
    }()

    // "25 usd/uah", "1 pound in kg", "100 € в грн", "5 miles to km", "100 F -> C"
    private static let re = try! NSRegularExpression(
        pattern: "(-?\\d+(?:[.,]\\d+)?)\\s*([^\\d\\s=/]+(?:/[hчсгод]+)?)\\s*(?:/|\\bin\\b|\\bto\\b|\\bв\\b|\\bу\\b|->|→)\\s*([^\\d\\s=]+(?:/[hчсгод]+)?)\\s*$",
        options: [.caseInsensitive])

    /// Async because currency rates may need downloading. `done(nil)` = not a conversion.
    static func evaluate(_ line: String, done: @escaping (String?) -> Void) {
        let ns = line as NSString
        guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { done(nil); return }
        let numText = ns.substring(with: m.range(at: 1))
        let fromRaw = ns.substring(with: m.range(at: 2)), toRaw = ns.substring(with: m.range(at: 3))
        let from = fromRaw.lowercased().trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "$€£₴¥°/")))
        let to = toRaw.lowercased().trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "$€£₴¥°/")))
        let comma = numText.contains(",")
        guard let value = Double(numText.replacingOccurrences(of: ",", with: ".")) else { done(nil); return }

        if let a = money[from] ?? (from.count == 3 && from.allSatisfy(\.isASCII) ? from.uppercased() : nil),
           let b = money[to] ?? (to.count == 3 && to.allSatisfy(\.isASCII) ? to.uppercased() : nil),
           units[from] == nil || money[from] != nil {
            rates { r in
                guard let r = r, let ra = r[a], let rb = r[b], ra > 0 else { done(nil); return }
                let v = value / ra * rb
                done(fmt(v, digits: 2, comma: comma) + " " + toRaw)
            }
            return
        }
        guard let ua = units[from], let ub = units[to], ua.kind == ub.kind else { done(nil); return }
        let v: Double
        if ua.kind == .temp {
            func toC(_ x: Double, _ u: String) -> Double { u.contains("f") || u.hasPrefix("фар") ? (x - 32) * 5 / 9 : (u.hasPrefix("k") || u.hasPrefix("кел") ? x - 273.15 : x) }
            func fromC(_ c: Double, _ u: String) -> Double { u.contains("f") || u.hasPrefix("фар") ? c * 9 / 5 + 32 : (u.hasPrefix("k") || u.hasPrefix("кел") ? c + 273.15 : c) }
            v = fromC(toC(value, from), to)
        } else {
            v = value * ua.factor / ub.factor
        }
        done(fmt(v, digits: abs(v) >= 100 ? 2 : 4, comma: comma) + " " + toRaw)
    }

    private static func fmt(_ v: Double, digits: Int, comma: Bool) -> String {
        var s = String(format: "%.\(digits)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return comma ? s.replacingOccurrences(of: ".", with: ",") : s
    }

    // MARK: currency rates (per 1 USD), cached for 12 hours

    private static func rates(_ done: @escaping ([String: Double]?) -> Void) {
        let d = UserDefaults.standard
        if let r = d.dictionary(forKey: "fxRates") as? [String: Double],
           let at = d.object(forKey: "fxRatesAt") as? Date, Date().timeIntervalSince(at) < 12 * 3600 {
            done(r); return
        }
        var req = URLRequest(url: URL(string: "https://open.er-api.com/v6/latest/USD")!)
        req.timeoutInterval = 6
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let r = obj?["rates"] as? [String: Double]
            DispatchQueue.main.async {
                if let r = r {
                    d.set(r, forKey: "fxRates"); d.set(Date(), forKey: "fxRatesAt")
                    done(r)
                } else {
                    done(d.dictionary(forKey: "fxRates") as? [String: Double])   // offline: last known rates
                }
            }
        }.resume()
    }
}
