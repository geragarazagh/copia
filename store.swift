// The history on disk: one plain SQLite database in WAL mode and two folders of content-addressed files, all in one
// removable folder (~/.local/share/clip). No SwiftData: it needs macOS 14, and Maccy's SwiftData store grew to 1.89 GB
// in 11 days from orphaned rows (issue #1496); here a representation row dies with its entry (ON DELETE CASCADE) and
// a file is removed once no row names it. Used from the main thread only.
import Foundation
import SQLite3

/// How long the history is kept, as Apple orders such lists (Messages: 30 Days, 1 Year, Forever).
enum Keep: String, CaseIterable {
    case days30 = "30d", year1 = "1y", forever = "forever"
    var seconds: TimeInterval? {
        switch self { case .days30: 30 * 86400; case .year1: 365 * 86400; case .forever: nil }
    }
}

/// Recently Deleted keeps what was deleted for 30 days, as Notes, Photos and Voice Memos do.
let recentlyDeletedDays: TimeInterval = 30

final class Store {
    let dir: URL
    private var db: OpaquePointer?

    init(dir: URL) throws {
        self.dir = dir
        let fm = FileManager.default
        for sub in ["", "images", "blobs", "paste"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])   // a history holds passwords too
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)   // also when the folder was there
        let path = dir.appendingPathComponent("clip.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw StoreError(message: String(cString: sqlite3_errmsg(db)))
        }
        chmod(path, 0o600)
        // auto_vacuum must be set before the first table exists; incremental, so a purge gives the space back
        // in small steps instead of rewriting the whole file (ClipBook's SQLiteHistoryStore does the same).
        try exec("PRAGMA auto_vacuum = INCREMENTAL")
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
        try exec("PRAGMA foreign_keys = ON")
        try exec("PRAGMA journal_size_limit = 4194304")
        try exec("""
            CREATE TABLE IF NOT EXISTS entries(
              id INTEGER PRIMARY KEY, copied REAL NOT NULL, app TEXT, kind TEXT NOT NULL, title TEXT NOT NULL,
              text TEXT NOT NULL, bytes INTEGER NOT NULL, count INTEGER NOT NULL, width INTEGER NOT NULL DEFAULT 0,
              height INTEGER NOT NULL DEFAULT 0, thumb TEXT, digest TEXT NOT NULL, deleted REAL,
              concealed INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS entries_digest ON entries(digest);
            CREATE INDEX IF NOT EXISTS entries_copied ON entries(copied);
            CREATE TABLE IF NOT EXISTS reps(
              entry INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE, item INTEGER NOT NULL,
              type TEXT NOT NULL, data BLOB, file TEXT, PRIMARY KEY(entry, item, type)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            PRAGMA user_version = 1;
            """)
    }

    deinit { sqlite3_close_v2(db) }

    // MARK: entries

    /// Adds a copy, or, when the same content is already there (the same digest), moves that entry to now: copying
    /// a thing again brings it to the top instead of making a twin, and brings it back from Recently Deleted.
    @discardableResult
    func add(_ e: Entry, _ items: [[Rep]]) -> Int64 {
        if let id = query("SELECT id FROM entries WHERE digest = ? ORDER BY copied DESC LIMIT 1", [e.digest], { int($0, 0) }).first {
            run("UPDATE entries SET copied = ?, app = COALESCE(?, app), deleted = NULL WHERE id = ?",
                [e.copied.timeIntervalSince1970, e.app, id])
            return id
        }
        run("BEGIN")
        run("""
            INSERT INTO entries(copied, app, kind, title, text, bytes, count, width, height, thumb, digest, concealed)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """, [e.copied.timeIntervalSince1970, e.app, e.kind.rawValue, e.title, e.text, e.bytes, e.count, e.width,
                  e.height, e.thumb, e.digest, e.concealed ? 1 : 0])
        let id = sqlite3_last_insert_rowid(db)
        for (i, reps) in items.enumerated() {
            for r in reps { run("INSERT OR REPLACE INTO reps(entry, item, type, data, file) VALUES (?,?,?,?,?)", [id, i, r.type, r.data, r.file]) }
        }
        run("COMMIT")
        return id
    }

    /// Newest first.
    func entries(deleted: Bool = false) -> [Entry] {
        query("""
            SELECT id, copied, app, kind, title, text, bytes, count, width, height, thumb, digest, deleted, concealed
            FROM entries WHERE deleted IS \(deleted ? "NOT NULL" : "NULL") ORDER BY copied DESC, id DESC
            """, []) { s in
            Entry(id: int(s, 0), copied: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)), app: text(s, 2),
                  kind: Kind(rawValue: text(s, 3) ?? "") ?? .other, title: text(s, 4) ?? "", text: text(s, 5) ?? "",
                  bytes: Int(int(s, 6)), count: Int(int(s, 7)), width: Int(int(s, 8)), height: Int(int(s, 9)),
                  thumb: text(s, 10), digest: text(s, 11) ?? "",
                  deleted: sqlite3_column_type(s, 12) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 12)),
                  concealed: int(s, 13) != 0)
        }
    }

    /// The items of an entry in their order, each with its types.
    func reps(_ id: Int64) -> [[Rep]] {
        var out: [[Rep]] = []
        for (i, r) in query("SELECT item, type, data, file FROM reps WHERE entry = ? ORDER BY item, type", [id], { s in
            (Int(int(s, 0)), Rep(type: text(s, 1) ?? "", data: blob(s, 2), file: text(s, 3)))
        }) {
            while out.count <= i { out.append([]) }
            out[i].append(r)
        }
        return out
    }

    /// The bytes of a representation, from the database or from its file.
    func data(_ r: Rep) -> Data? {
        if let d = r.data { return d }
        return r.file.flatMap { try? Data(contentsOf: dir.appendingPathComponent($0)) }
    }

    /// Into Recently Deleted (kept 30 days); nothing is removed from disk yet, so ⌘Z only clears the date.
    func delete(_ ids: [Int64], at date: Date = Date()) {
        run("BEGIN")
        for id in ids { run("UPDATE entries SET deleted = ? WHERE id = ?", [date.timeIntervalSince1970, id]) }
        run("COMMIT")
    }

    func undelete(_ ids: [Int64]) {
        run("BEGIN")
        for id in ids { run("UPDATE entries SET deleted = NULL WHERE id = ?", [id]) }
        run("COMMIT")
    }

    /// Removes for good what Recently Deleted has kept 30 days and what is older than the keep-history setting, then
    /// every image or blob file no row names any more. Run at launch and every hour.
    func purge(now: Date = Date()) {
        let t = now.timeIntervalSince1970
        run("DELETE FROM entries WHERE deleted IS NOT NULL AND deleted < ?", [t - recentlyDeletedDays * 86400])
        if let s = keep.seconds { run("DELETE FROM entries WHERE copied < ?", [t - s]) }
        let used = Set(query("SELECT DISTINCT file FROM reps WHERE file IS NOT NULL", [], { text($0, 0) ?? "" }))
        let fm = FileManager.default
        for sub in ["images", "blobs"] {
            for f in (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent(sub).path)) ?? [] where !used.contains(sub + "/" + f) {
                // A file written in the last ten minutes may belong to a copy still on its way into the database
                // (files are written off the main thread, rows on it).
                let u = dir.appendingPathComponent(sub).appendingPathComponent(f)
                let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if now.timeIntervalSince(m) > 600 { try? fm.removeItem(at: u) }
            }
        }
        run("PRAGMA incremental_vacuum")
    }

    // MARK: settings

    var keep: Keep {
        get { query("SELECT value FROM settings WHERE key = 'keep'", [], { text($0, 0) }).first.flatMap { $0.flatMap(Keep.init) } ?? .days30 }
        set { run("INSERT OR REPLACE INTO settings(key, value) VALUES ('keep', ?)", [newValue.rawValue]) }
    }

    /// A plain setting by key (the panel's place per screen, …): nil when never set.
    func setting(_ key: String) -> String? {
        query("SELECT value FROM settings WHERE key = ?", [key], { text($0, 0) }).first ?? nil
    }

    func setSetting(_ key: String, _ value: String) {
        run("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", [key, value])
    }

    // MARK: SQLite plumbing

    struct StoreError: Error { let message: String }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError(message: String(cString: sqlite3_errmsg(db))) }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func statement(_ sql: String, _ args: [Any?]) -> OpaquePointer? {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else {
            FileHandle.standardError.write(Data("SQLite: \(String(cString: sqlite3_errmsg(db))) in \(sql)\n".utf8))
            return nil
        }
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(s, n)
            case let v as Int64: sqlite3_bind_int64(s, n, v)
            case let v as Int: sqlite3_bind_int64(s, n, Int64(v))
            case let v as Double: sqlite3_bind_double(s, n, v)
            case let v as String: sqlite3_bind_text(s, n, v, -1, Self.transient)
            case let v as Data where v.isEmpty: sqlite3_bind_zeroblob(s, n, 0)   // an empty marker type is still a type
            case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(s, n, $0.baseAddress, Int32(v.count), Self.transient) }
            default: sqlite3_bind_null(s, n)
            }
        }
        return s
    }

    @discardableResult
    private func run(_ sql: String, _ args: [Any?] = []) -> Bool {
        guard let s = statement(sql, args) else { return false }
        defer { sqlite3_finalize(s) }
        var rc = sqlite3_step(s)
        while rc == SQLITE_ROW { rc = sqlite3_step(s) }
        if rc != SQLITE_DONE { FileHandle.standardError.write(Data("SQLite: \(String(cString: sqlite3_errmsg(db))) in \(sql)\n".utf8)) }
        return rc == SQLITE_DONE
    }

    private func query<T>(_ sql: String, _ args: [Any?], _ row: (OpaquePointer) -> T) -> [T] {
        guard let s = statement(sql, args) else { return [] }
        defer { sqlite3_finalize(s) }
        var out: [T] = []
        while sqlite3_step(s) == SQLITE_ROW { out.append(row(s)) }
        return out
    }
}

private func int(_ s: OpaquePointer, _ i: Int32) -> Int64 { sqlite3_column_int64(s, i) }
private func text(_ s: OpaquePointer, _ i: Int32) -> String? {
    sqlite3_column_type(s, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(s, i))
}
private func blob(_ s: OpaquePointer, _ i: Int32) -> Data? {
    guard sqlite3_column_type(s, i) != SQLITE_NULL else { return nil }
    let n = Int(sqlite3_column_bytes(s, i))
    guard n > 0, let p = sqlite3_column_blob(s, i) else { return Data() }
    return Data(bytes: p, count: n)
}
