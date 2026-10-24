import Foundation
import SQLite3

enum EntryKind: String, CaseIterable, Codable, Identifiable {
    case word, exception, rule, candidate, phrase, banned
    var id: String { rawValue }
}

enum EntrySource: String, Codable { case manual, learned, accepted }

struct UserEntry: Identifiable, Codable, Hashable {
    var id: Int64 = 0
    var word: String
    var lang: Lang
    var kind: EntryKind
    var target: String?        // rule: replacement text
    var targetLang: Lang?      // rule: layout of replacement
    var uses: Int = 0
    var undos: Int = 0
    var created: Date = Date()
    var lastUsed: Date = Date()
    var source: EntrySource = .manual
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Local user dictionary, exceptions, rules and learning stats. SQLite (WAL) — crash-safe.
final class UserStore: ObservableObject {
    static let shared = UserStore()
    private var db: OpaquePointer?
    @Published private(set) var entries: [UserEntry] = []
    private var index: [String: Int] = [:]   // key(kind,lang,word) -> entries index

    static var dir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExoKey", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var dbURL: URL { dir.appendingPathComponent("user.sqlite") }

    private init() {
        open()
        load()
    }

    private func open() {
        guard sqlite3_open(Self.dbURL.path, &db) == SQLITE_OK else { db = nil; return }
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        exec("""
        CREATE TABLE IF NOT EXISTS entries(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          word TEXT NOT NULL, lang TEXT NOT NULL, kind TEXT NOT NULL,
          target TEXT, target_lang TEXT,
          uses INTEGER NOT NULL DEFAULT 0, undos INTEGER NOT NULL DEFAULT 0,
          created REAL NOT NULL, last_used REAL NOT NULL, source TEXT NOT NULL,
          UNIQUE(kind, lang, word));
        """)
        exec("CREATE TABLE IF NOT EXISTS ngrams(key TEXT PRIMARY KEY, count INTEGER NOT NULL DEFAULT 0)")
        exec("CREATE TABLE IF NOT EXISTS style(id INTEGER PRIMARY KEY AUTOINCREMENT, app TEXT, lang TEXT, text TEXT UNIQUE, at REAL)")
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func key(_ k: EntryKind, _ l: Lang, _ w: String) -> String { "\(k.rawValue)|\(l.rawValue)|\(w)" }

    private func load() {
        var out: [UserEntry] = []
        var st: OpaquePointer?
        let sql = "SELECT id,word,lang,kind,target,target_lang,uses,undos,created,last_used,source FROM entries"
        if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW {
                func s(_ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }
                guard let w = s(1), let l = Lang(rawValue: s(2) ?? ""), let k = EntryKind(rawValue: s(3) ?? "") else { continue }
                out.append(UserEntry(id: sqlite3_column_int64(st, 0), word: w, lang: l, kind: k,
                                     target: s(4), targetLang: s(5).flatMap(Lang.init(rawValue:)),
                                     uses: Int(sqlite3_column_int(st, 6)), undos: Int(sqlite3_column_int(st, 7)),
                                     created: Date(timeIntervalSince1970: sqlite3_column_double(st, 8)),
                                     lastUsed: Date(timeIntervalSince1970: sqlite3_column_double(st, 9)),
                                     source: EntrySource(rawValue: s(10) ?? "") ?? .manual))
            }
        }
        sqlite3_finalize(st)
        entries = out
        rebuildIndex()
    }

    private func rebuildIndex() {
        index = [:]
        for (i, e) in entries.enumerated() { index[Self.key(e.kind, e.lang, e.word)] = i }
        wordsByLang = [:]
        for e in entries where e.kind == .word { wordsByLang[e.lang, default: []].append(e.word) }
    }
    private var wordsByLang: [Lang: [String]] = [:]

    // MARK: queries (hot path, in memory)

    func find(_ kind: EntryKind, _ lang: Lang, _ word: String) -> UserEntry? {
        index[Self.key(kind, lang, word)].map { entries[$0] }
    }

    func isWord(_ w: String, _ l: Lang) -> Bool { find(.word, l, w) != nil }
    func isException(_ w: String, _ l: Lang) -> Bool { find(.exception, l, w) != nil }
    func hasPrefix(_ p: String, _ l: Lang) -> Bool { wordsByLang[l]?.contains { $0.hasPrefix(p) } ?? false }

    // MARK: mutations

    /// Insert or replace an entry. Returns error text on conflict.
    @discardableResult
    func upsert(_ e: UserEntry) -> String? {
        var st: OpaquePointer?
        let sql = """
        INSERT INTO entries(word,lang,kind,target,target_lang,uses,undos,created,last_used,source)
        VALUES(?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(kind,lang,word) DO UPDATE SET target=excluded.target, target_lang=excluded.target_lang,
          uses=excluded.uses, undos=excluded.undos, last_used=excluded.last_used, source=excluded.source
        """
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return lastError }
        defer { sqlite3_finalize(st) }
        bind(st, 1, e.word); bind(st, 2, e.lang.rawValue); bind(st, 3, e.kind.rawValue)
        bind(st, 4, e.target); bind(st, 5, e.targetLang?.rawValue)
        sqlite3_bind_int(st, 6, Int32(e.uses)); sqlite3_bind_int(st, 7, Int32(e.undos))
        sqlite3_bind_double(st, 8, e.created.timeIntervalSince1970)
        sqlite3_bind_double(st, 9, e.lastUsed.timeIntervalSince1970)
        bind(st, 10, e.source.rawValue)
        guard sqlite3_step(st) == SQLITE_DONE else { return lastError }
        load()
        return nil
    }

    func delete(_ e: UserEntry) {
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM entries WHERE kind=? AND lang=? AND word=?", -1, &st, nil) == SQLITE_OK {
            bind(st, 1, e.kind.rawValue); bind(st, 2, e.lang.rawValue); bind(st, 3, e.word)
            sqlite3_step(st)
        }
        sqlite3_finalize(st)
        load()
    }

    func deleteAll(kind: EntryKind? = nil, source: EntrySource? = nil) {
        var conds: [String] = []
        if let k = kind { conds.append("kind='\(k.rawValue)'") }
        if let s = source { conds.append("source='\(s.rawValue)'") }
        exec("DELETE FROM entries" + (conds.isEmpty ? "" : " WHERE " + conds.joined(separator: " AND ")))
        load()
    }

    /// Learning: reset counters of learned rules/candidates.
    func resetLearning() {
        exec("DELETE FROM entries WHERE source='learned'; UPDATE entries SET uses=0, undos=0;")
        load()
    }

    // MARK: n-gram counters (phrases typed / suggestions accepted / rejected) — no reload, cheap

    private var ngramCache: [String: Int]?

    /// Increments a counter and returns the new value.
    @discardableResult
    func bump(_ key: String) -> Int {
        if ngramCache == nil { loadNgrams() }
        let n = (ngramCache?[key] ?? 0) + 1
        ngramCache?[key] = n
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO ngrams(key,count) VALUES(?,1) ON CONFLICT(key) DO UPDATE SET count=count+1", -1, &st, nil) == SQLITE_OK {
            bind(st, 1, key)
            sqlite3_step(st)
        }
        sqlite3_finalize(st)
        return n
    }

    private func loadNgrams() {
        var m: [String: Int] = [:]
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT key,count FROM ngrams", -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW {
                if let k = sqlite3_column_text(st, 0) { m[String(cString: k)] = Int(sqlite3_column_int(st, 1)) }
            }
        }
        sqlite3_finalize(st)
        ngramCache = m
    }

    /// Clears personalization of autocomplete: learned/accepted phrases and counters.
    func clearPersonalization() {
        exec("DELETE FROM ngrams; DELETE FROM entries WHERE kind IN ('phrase','banned') AND source != 'manual';")
        ngramCache = [:]
        load()
    }

    var phrases: [UserEntry] { entries.filter { $0.kind == .phrase } }
    var banned: [UserEntry] { entries.filter { $0.kind == .banned } }

    /// User dictionary words starting with prefix, most used first.
    func userCompletions(_ prefix: String, _ l: Lang) -> [String] {
        (wordsByLang[l] ?? []).filter { $0.hasPrefix(prefix) && $0 != prefix }
    }

    // MARK: writing style (opt-in): the user's own finished sentences

    func styleAdd(_ text: String, app: String, lang: Lang) {
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO style(app,lang,text,at) VALUES(?,?,?,?)", -1, &st, nil) == SQLITE_OK {
            bind(st, 1, app); bind(st, 2, lang.rawValue); bind(st, 3, text)
            sqlite3_bind_double(st, 4, Date().timeIntervalSince1970)
            sqlite3_step(st)
        }
        sqlite3_finalize(st)
        exec("DELETE FROM style WHERE id NOT IN (SELECT id FROM style ORDER BY at DESC LIMIT 400)")
    }

    /// Newest sentences: same app first, then same language.
    func styleExamples(app: String?, lang: Lang, limit: Int) -> [String] {
        var out: [String] = []
        var st: OpaquePointer?
        let sql = "SELECT text FROM style WHERE lang=? ORDER BY (app=?) DESC, at DESC LIMIT ?"
        if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK {
            bind(st, 1, lang.rawValue); bind(st, 2, app ?? "")
            sqlite3_bind_int(st, 3, Int32(limit))
            while sqlite3_step(st) == SQLITE_ROW {
                if let t = sqlite3_column_text(st, 0) { out.append(String(cString: t)) }
            }
        }
        sqlite3_finalize(st)
        return out.reversed()
    }

    func styleCount() -> Int {
        var st: OpaquePointer?
        var n = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM style", -1, &st, nil) == SQLITE_OK, sqlite3_step(st) == SQLITE_ROW {
            n = Int(sqlite3_column_int(st, 0))
        }
        sqlite3_finalize(st)
        return n
    }

    func styleClear() { exec("DELETE FROM style") }

    private var lastError: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database" }

    private func bind(_ st: OpaquePointer?, _ i: Int32, _ v: String?) {
        if let v = v { sqlite3_bind_text(st, i, v, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(st, i) }
    }

    // MARK: learning helpers

    func touch(_ kind: EntryKind, _ lang: Lang, _ word: String, uses: Int = 0, undos: Int = 0,
               target: String? = nil, targetLang: Lang? = nil, source: EntrySource = .learned) -> UserEntry {
        var e = find(kind, lang, word) ?? UserEntry(word: word, lang: lang, kind: kind, source: source)
        e.uses += uses
        e.undos += undos
        if let t = target { e.target = t }
        if let tl = targetLang { e.targetLang = tl }
        e.lastUsed = Date()
        upsert(e)
        return e
    }

    // MARK: import / export

    func exportJSON(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(entries).write(to: url, options: .atomic)
    }

    @discardableResult
    func importJSON(from url: URL) throws -> Int {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let list = try dec.decode([UserEntry].self, from: Data(contentsOf: url))
        exec("BEGIN")
        var n = 0
        for e in list where upsertNoReload(e) { n += 1 }
        exec("COMMIT")
        load()
        return n
    }

    private func upsertNoReload(_ e: UserEntry) -> Bool {
        var st: OpaquePointer?
        let sql = """
        INSERT OR REPLACE INTO entries(word,lang,kind,target,target_lang,uses,undos,created,last_used,source)
        VALUES(?,?,?,?,?,?,?,?,?,?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        bind(st, 1, e.word); bind(st, 2, e.lang.rawValue); bind(st, 3, e.kind.rawValue)
        bind(st, 4, e.target); bind(st, 5, e.targetLang?.rawValue)
        sqlite3_bind_int(st, 6, Int32(e.uses)); sqlite3_bind_int(st, 7, Int32(e.undos))
        sqlite3_bind_double(st, 8, e.created.timeIntervalSince1970)
        sqlite3_bind_double(st, 9, e.lastUsed.timeIntervalSince1970)
        bind(st, 10, e.source.rawValue)
        return sqlite3_step(st) == SQLITE_DONE
    }

    func backup(to url: URL) throws {
        exec("PRAGMA wal_checkpoint(FULL)")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.copyItem(at: Self.dbURL, to: url)
    }

    func restore(from url: URL) throws {
        sqlite3_close(db); db = nil
        for ext in ["", "-wal", "-shm"] {
            let p = URL(fileURLWithPath: Self.dbURL.path + ext)
            try? FileManager.default.removeItem(at: p)
        }
        try FileManager.default.copyItem(at: url, to: Self.dbURL)
        open()
        load()
    }
}
