// The history on disk: one plain SQLite database in WAL mode and two folders of content-addressed files, all in one
// removable folder (~/.local/share/copia). No SwiftData: it needs macOS 14, and Maccy's SwiftData store grew to 1.89 GB
// in 11 days from orphaned rows (issue #1496); here a representation row dies with its entry (ON DELETE CASCADE) and
// a file is removed once no row names it. Used from the main thread only.
import AppKit
import SQLite3

/// How long the history is kept: STT's scale (0.3, his decision 2026-11-12: one scale in all his apps, short to long,
/// Apple's words) without its «Don't Keep», which a clipboard history has no use for (his word 2026-11-14, Copia 0.6).
/// Raw values of 0.4-0.5 («30d», «1y», «forever») kept, so a stored choice stays as it was.
enum Keep: String, CaseIterable {
    case day1 = "1d", days7 = "7d", days30 = "30d", year1 = "1y", forever = "forever"
    var seconds: TimeInterval? {
        switch self {
        case .day1: 86400; case .days7: 7 * 86400; case .days30: 30 * 86400; case .year1: 365 * 86400; case .forever: nil
        }
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
        let path = dir.appendingPathComponent("copia.sqlite").path
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
              concealed INTEGER NOT NULL DEFAULT 0, url TEXT, picture TEXT);
            CREATE INDEX IF NOT EXISTS entries_digest ON entries(digest);
            CREATE INDEX IF NOT EXISTS entries_copied ON entries(copied);
            CREATE TABLE IF NOT EXISTS reps(
              entry INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE, item INTEGER NOT NULL,
              type TEXT NOT NULL, data BLOB, file TEXT, PRIMARY KEY(entry, item, type)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS originals(
              entry INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE, item INTEGER NOT NULL,
              type TEXT NOT NULL, data BLOB, file TEXT, PRIMARY KEY(entry, item, type)) WITHOUT ROWID;
            """)
        // Version 2 (2026-11-14): a link's own address and the page picture it carried (link.swift).
        if query("PRAGMA user_version", [], { int($0, 0) }).first ?? 0 < 2 {
            let cols = Set(query("PRAGMA table_info(entries)", [], { text($0, 1) ?? "" }))
            for c in ["url", "picture"] where !cols.contains(c) { try exec("ALTER TABLE entries ADD COLUMN \(c) TEXT") }
            try exec("PRAGMA user_version = 2")
        }
        // Version 3 (0.5): the content key (contentKey in model.swift), filled for every entry already kept, and the
        // twins it finds merged into their newest copy, as a copy made today would be.
        if query("PRAGMA user_version", [], { int($0, 0) }).first ?? 0 < 3 {
            let cols = Set(query("PRAGMA table_info(entries)", [], { text($0, 1) ?? "" }))
            if !cols.contains("ckey") { try exec("ALTER TABLE entries ADD COLUMN ckey TEXT") }
            try exec("CREATE INDEX IF NOT EXISTS entries_ckey ON entries(ckey)")
            run("BEGIN")
            for id in query("SELECT id FROM entries", [], { int($0, 0) }) {
                let k = contentKey(reps(id)) { self.data($0) }
                run("UPDATE entries SET ckey = ? WHERE id = ?", [k, id])
            }
            mergeTwins()
            run("PRAGMA user_version = 3")
            run("COMMIT")
        }
    }

    /// Entries with the same content key become one: the newest copy stays (a live one before one in Recently
    /// Deleted), with the latest date of the group; the rest are removed.
    private func mergeTwins() {
        let groups = query("SELECT ckey FROM entries WHERE ckey IS NOT NULL GROUP BY ckey HAVING COUNT(*) > 1", [], { text($0, 0) ?? "" })
        for k in groups {
            let rows = query("SELECT id, copied FROM entries WHERE ckey = ? ORDER BY deleted IS NOT NULL, copied DESC, id DESC", [k],
                             { (int($0, 0), sqlite3_column_double($0, 1)) })
            guard let keep = rows.first else { continue }
            let latest = rows.map(\.1).max() ?? keep.1
            run("UPDATE entries SET copied = ? WHERE id = ?", [latest, keep.0])
            for r in rows.dropFirst() { run("DELETE FROM entries WHERE id = ?", [r.0]) }
        }
    }

    deinit { sqlite3_close_v2(db) }

    // MARK: entries

    /// Adds a copy, or, when the same thing is already there (the same content key, else the same digest), moves that
    /// entry to now: copying a thing again, from anywhere, brings it to the top instead of making a twin, and brings it
    /// back from Recently Deleted. The new copy's types replace the old ones (it is what the clipboard holds now: the
    /// same text copied from Safari after Notes comes back with Safari's rich text); an edit's original stays.
    @discardableResult
    func add(_ e: Entry, _ items: [[Rep]]) -> Int64 {
        let found = e.key.flatMap { k in query("SELECT id, digest FROM entries WHERE ckey = ? ORDER BY copied DESC LIMIT 1", [k],
                                                { (int($0, 0), text($0, 1) ?? "") }).first }
            ?? query("SELECT id, digest FROM entries WHERE digest = ? ORDER BY copied DESC LIMIT 1", [e.digest], { (int($0, 0), text($0, 1) ?? "") }).first
        if let (id, digest) = found {
            run("BEGIN")
            run("UPDATE entries SET copied = ?, app = COALESCE(?, app), deleted = NULL WHERE id = ?",
                [e.copied.timeIntervalSince1970, e.app, id])
            if digest != e.digest {
                run("DELETE FROM reps WHERE entry = ?", [id])
                insertReps(id, items)
                run("""
                    UPDATE entries SET kind = ?, title = ?, text = ?, bytes = ?, count = ?, width = ?, height = ?, thumb = ?,
                    digest = ?, concealed = ?, url = ?, picture = ?, ckey = ? WHERE id = ?
                    """, [e.kind.rawValue, e.title, e.text, e.bytes, e.count, e.width, e.height, e.thumb, e.digest,
                          e.concealed ? 1 : 0, e.url, e.picture, e.key, id])
            }
            run("COMMIT")
            return id
        }
        run("BEGIN")
        run("""
            INSERT INTO entries(copied, app, kind, title, text, bytes, count, width, height, thumb, digest, concealed, url, picture, ckey)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [e.copied.timeIntervalSince1970, e.app, e.kind.rawValue, e.title, e.text, e.bytes, e.count, e.width,
                  e.height, e.thumb, e.digest, e.concealed ? 1 : 0, e.url, e.picture, e.key])
        let id = sqlite3_last_insert_rowid(db)
        insertReps(id, items)
        run("COMMIT")
        return id
    }

    private func insertReps(_ id: Int64, _ items: [[Rep]]) {
        for (i, reps) in items.enumerated() {
            for r in reps { run("INSERT OR REPLACE INTO reps(entry, item, type, data, file) VALUES (?,?,?,?,?)", [id, i, r.type, r.data, r.file]) }
        }
    }

    /// Used: copied back from Copia (⌘C, a double click, Return, Copy as Plain Text, a drag out). The entries move to
    /// the top with the time of use, as a copy made anywhere else does; among themselves they keep the order they had,
    /// so ⌘A ⌘C lifts the whole list without shuffling it.
    func touch(_ ids: [Int64], now: Date = Date()) {
        guard !ids.isEmpty else { return }
        let list = ids.map { "\($0)" }.joined(separator: ",")
        let old = query("SELECT id FROM entries WHERE id IN (\(list)) ORDER BY copied ASC, id ASC", [], { int($0, 0) })
        run("BEGIN")
        for (i, id) in old.enumerated() {
            // A millisecond apart: the newest keeps the top, and «now» is still now to a person.
            run("UPDATE entries SET copied = ? WHERE id = ?", [now.timeIntervalSince1970 - Double(old.count - 1 - i) * 0.001, id])
        }
        run("COMMIT")
    }

    /// Newest first.
    func entries(deleted: Bool = false) -> [Entry] {
        query("""
            SELECT id, copied, app, kind, title, text, bytes, count, width, height, thumb, digest, deleted, concealed, url, picture, ckey
            FROM entries WHERE deleted IS \(deleted ? "NOT NULL" : "NULL") ORDER BY copied DESC, id DESC
            """, []) { s in
            Entry(id: int(s, 0), copied: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)), app: text(s, 2),
                  kind: Kind(rawValue: text(s, 3) ?? "") ?? .other, title: text(s, 4) ?? "", text: text(s, 5) ?? "",
                  bytes: Int(int(s, 6)), count: Int(int(s, 7)), width: Int(int(s, 8)), height: Int(int(s, 9)),
                  thumb: text(s, 10), digest: text(s, 11) ?? "",
                  deleted: sqlite3_column_type(s, 12) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 12)),
                  concealed: int(s, 13) != 0, url: text(s, 14), picture: text(s, 15), key: text(s, 16))
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
        // A link's icon (thumb) and page picture are files no representation names: the entry itself does.
        let used = Set(query("""
            SELECT file FROM reps WHERE file IS NOT NULL UNION SELECT file FROM originals WHERE file IS NOT NULL
            UNION SELECT thumb FROM entries WHERE thumb IS NOT NULL UNION SELECT picture FROM entries WHERE picture IS NOT NULL
            """, [], { text($0, 0) ?? "" }))
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

    /// Removes for good (Recently Deleted's «Delete Immediately…»); the files no row names any more go at the next purge.
    func erase(_ ids: [Int64]) {
        run("BEGIN")
        for id in ids { run("DELETE FROM entries WHERE id = ?", [id]) }
        run("COMMIT")
    }

    // MARK: editing (the Space preview)

    /// An edited text replaces the entry's first item: RTF when it carries styling, always the plain text. The copy
    /// as it was is kept once, the first time, so «Revert to Original» can bring it back (ClipBook's Restore). The
    /// entry stays where it was in the list; its title, text, size and digest follow the new content.
    func edit(_ id: Int64, plain: String, rtf: Data?) {
        guard let old = entries().first(where: { $0.id == id }) else { return }
        run("BEGIN")
        if !hasOriginal(id) { run("INSERT INTO originals SELECT entry, item, type, data, file FROM reps WHERE entry = ?", [id]) }
        run("DELETE FROM reps WHERE entry = ? AND item = 0", [id])
        var reps = [Rep(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(plain.utf8))]
        if let rtf { reps.append(Rep(type: NSPasteboard.PasteboardType.rtf.rawValue, data: rtf)) }
        for r in reps { run("INSERT INTO reps(entry, item, type, data, file) VALUES (?,?,?,?,?)", [id, 0, r.type, r.data, nil]) }
        run("COMMIT")
        refresh(id, from: self.reps(id), app: old.app)
    }

    func hasOriginal(_ id: Int64) -> Bool {
        !query("SELECT 1 FROM originals WHERE entry = ? LIMIT 1", [id], { _ in 1 }).isEmpty
    }

    /// Puts the copy back as it was copied.
    func revert(_ id: Int64) {
        guard hasOriginal(id), let old = entries().first(where: { $0.id == id }) else { return }
        run("BEGIN")
        run("DELETE FROM reps WHERE entry = ?", [id])
        run("INSERT INTO reps SELECT entry, item, type, data, file FROM originals WHERE entry = ?", [id])
        run("DELETE FROM originals WHERE entry = ?", [id])
        run("COMMIT")
        refresh(id, from: self.reps(id), app: old.app)
    }

    /// The display fields of an entry made again from its items, through the same path a copy takes.
    private func refresh(_ id: Int64, from items: [[Rep]], app: String?) {
        let loaded = items.map { $0.map { Rep(type: $0.type, data: data($0)) } }
        guard let (e, _) = prepare(Snapshot(items: loaded, source: app), dir: dir) else { return }
        run("UPDATE entries SET kind = ?, title = ?, text = ?, bytes = ?, digest = ?, url = ?, picture = ?, ckey = ? WHERE id = ?",
            [e.kind.rawValue, e.title, e.text, e.bytes, e.digest, e.url, e.picture, e.key, id])
        if e.kind == .link { run("UPDATE entries SET thumb = ? WHERE id = ?", [e.thumb, id]) }
    }

    // MARK: settings

    /// Entries, kept or in Recently Deleted, that a shorter keep period would remove for good.
    func olderThan(_ k: Keep, now: Date = Date()) -> Int {
        guard let s = k.seconds else { return 0 }
        return query("SELECT COUNT(*) FROM entries WHERE copied < ?", [now.timeIntervalSince1970 - s], { int($0, 0) }).first.map(Int.init) ?? 0
    }

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
