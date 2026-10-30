import Foundation

/// Local counters shown in the menu: suggestions guessed / missed, typo fixes, layout corrections.
enum Stats {
    enum Key: String {
        case aiShown = "stat:ai_shown", aiHitWords = "stat:ai_hit", aiAccepted = "stat:ai_accept"
        case spellShown = "stat:spell_shown", spellAccepted = "stat:spell_ok", spellUndone = "stat:spell_undo"
        case layoutFixed = "stat:fix", layoutUndone = "stat:fix_undo"
    }
    static func add(_ k: Key, _ n: Int = 1) {
        for _ in 0..<max(0, n) { UserStore.shared.bump(k.rawValue) }
        if UserDefaults.standard.object(forKey: "statsSince") == nil { UserDefaults.standard.set(Date(), forKey: "statsSince") }
    }
    static func get(_ k: Key) -> Int { UserStore.shared.count(k.rawValue) }
    static var since: Date? { UserDefaults.standard.object(forKey: "statsSince") as? Date }
    static func reset() {
        UserStore.shared.clearStats()
        UserDefaults.standard.removeObject(forKey: "statsSince")
    }
    static func pct(_ a: Int, _ b: Int) -> String { b > 0 ? "\(Int((Double(a) / Double(b) * 100).rounded()))%" : "—" }
}
