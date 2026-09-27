import Foundation
import SQLite3

/// The decision database: one row per judged song, same table as the
/// Windows app's library.db. Skips are never stored.
public final class LibraryStore {
    private var db: OpaquePointer?

    public init(url: URL = Paths.databaseURL()) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw StoreError(message: "Couldn't open \(url.path): \(message)")
        }
        try exec("""
            CREATE TABLE IF NOT EXISTS sorted (
              key TEXT PRIMARY KEY, decision TEXT, title TEXT,
              src TEXT, copied TEXT, ts REAL);
            -- the songs in the library folder (the Library page), refreshed by scanning it
            CREATE TABLE IF NOT EXISTS library (
              id TEXT PRIMARY KEY, path TEXT NOT NULL, title TEXT, artist TEXT, album TEXT,
              duration REAL, size INTEGER, mtime REAL, added REAL, art TEXT);
            -- every time a library song played to its end (Leaderboard, Trends)
            CREATE TABLE IF NOT EXISTS plays (id TEXT, at REAL);
            CREATE INDEX IF NOT EXISTS plays_id ON plays(id);
            -- a library song left early for another one (Trends' skip magnets)
            CREATE TABLE IF NOT EXISTS skips (id TEXT, at REAL);
            -- lyrics in the Python app's segment format; source: whisper, lrc or none
            CREATE TABLE IF NOT EXISTS lyrics (id TEXT PRIMARY KEY, segments TEXT, source TEXT, made REAL);
            -- a song's karaoke timing nudge, in seconds (positive = words light up earlier)
            CREATE TABLE IF NOT EXISTS timing (id TEXT PRIMARY KEY, seconds REAL);
            """)
    }

    deinit { sqlite3_close(db) }

    public struct StoreError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Every judged key, in one query -- a folder is filtered against this
    /// set instead of asking once per file.
    public func allKeys() -> Set<String> {
        var keys = Set<String>()
        query("SELECT key FROM sorted") { keys.insert(Self.text($0, 0) ?? "") }
        return keys
    }

    public func decision(for key: String) -> String? {
        var result: String?
        query("SELECT decision FROM sorted WHERE key=?", [key]) { result = Self.text($0, 0) }
        return result
    }

    /// Writes (or replaces) a decision.
    public func record(key: String, decision: Decision, title: String, source: String, copied: String?) throws {
        try run("REPLACE INTO sorted (key, decision, title, src, copied, ts) VALUES (?,?,?,?,?,?)",
                [key, decision.rawValue, title, source, copied, Date().timeIntervalSince1970])
    }

    /// Deletes a decision, returning the library copy's path if it was a keep.
    @discardableResult
    public func forget(key: String) throws -> String? {
        var copied: String?
        query("SELECT copied FROM sorted WHERE key=?", [key]) { copied = Self.text($0, 0) }
        try run("DELETE FROM sorted WHERE key=?", [key])
        return copied
    }

    /// Where a kept song's library copy was made.
    public func copiedPath(for key: String) -> String? {
        var result: String?
        query("SELECT copied FROM sorted WHERE key=?", [key]) { result = Self.text($0, 0) }
        return result
    }

    /// Lifetime totals, e.g. ["keep": 12, "pass": 30].
    public func counts() -> [String: Int] {
        var out: [String: Int] = [:]
        query("SELECT decision, COUNT(*) FROM sorted GROUP BY decision") { row in
            out[Self.text(row, 0) ?? ""] = Int(sqlite3_column_int64(row, 1))
        }
        return out
    }

    public func keptPaths() -> [String] {
        var out: [String] = []
        query("SELECT copied FROM sorted WHERE decision='keep' AND copied IS NOT NULL ORDER BY ts DESC") {
            if let p = Self.text($0, 0) { out.append(p) }
        }
        return out
    }

    // MARK: - the library index

    public struct LibraryRow: Sendable, Equatable {
        public var id: String
        public var path: String
        public var title: String?
        public var artist: String?
        public var album: String?
        public var duration: Double
        public var size: Int
        public var mtime: Double
        public var added: Double
        public var art: String?        // a short hash of its cover art, for picking album covers
        public init(id: String, path: String, title: String?, artist: String?, album: String?, duration: Double,
                    size: Int, mtime: Double, added: Double, art: String?) {
            self.id = id
            self.path = path
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
            self.size = size
            self.mtime = mtime
            self.added = added
            self.art = art
        }
    }

    /// Every indexed song, oldest first.
    public func libraryRows() -> [LibraryRow] {
        var rows: [LibraryRow] = []
        query("SELECT id, path, title, artist, album, duration, size, mtime, added, art FROM library ORDER BY added, rowid") { r in
            rows.append(LibraryRow(id: Self.text(r, 0) ?? "", path: Self.text(r, 1) ?? "", title: Self.text(r, 2),
                                   artist: Self.text(r, 3), album: Self.text(r, 4), duration: sqlite3_column_double(r, 5),
                                   size: Int(sqlite3_column_int64(r, 6)), mtime: sqlite3_column_double(r, 7),
                                   added: sqlite3_column_double(r, 8), art: Self.text(r, 9)))
        }
        return rows
    }

    public func saveLibrary(_ rows: [LibraryRow]) throws {
        try transaction {
            for r in rows {
                try run("REPLACE INTO library (id, path, title, artist, album, duration, size, mtime, added, art) VALUES (?,?,?,?,?,?,?,?,?,?)",
                        [r.id, r.path, r.title, r.artist, r.album, r.duration, r.size, r.mtime, r.added, r.art])
            }
        }
    }

    public func removeLibrary(ids: [String]) throws {
        try transaction {
            for id in ids { try run("DELETE FROM library WHERE id=?", [id]) }
        }
    }

    // MARK: - plays and skips

    public func recordPlay(id: String, at: Date = Date()) throws {
        try run("INSERT INTO plays (id, at) VALUES (?,?)", [id, at.timeIntervalSince1970])
    }

    public func recordSkip(id: String, at: Date = Date()) throws {
        try run("INSERT INTO skips (id, at) VALUES (?,?)", [id, at.timeIntervalSince1970])
    }

    public struct PlayStats: Sendable, Equatable {
        public var plays = 0
        public var skips = 0
        public var lastPlayed: Double?
    }

    public func playStats() -> [String: PlayStats] {
        var out: [String: PlayStats] = [:]
        query("SELECT id, COUNT(*), MAX(at) FROM plays GROUP BY id") { r in
            let id = Self.text(r, 0) ?? ""
            out[id, default: PlayStats()].plays = Int(sqlite3_column_int64(r, 1))
            out[id, default: PlayStats()].lastPlayed = sqlite3_column_double(r, 2)
        }
        query("SELECT id, COUNT(*) FROM skips GROUP BY id") { r in
            out[Self.text(r, 0) ?? "", default: PlayStats()].skips = Int(sqlite3_column_int64(r, 1))
        }
        return out
    }

    /// Every play, as (song, when).
    public func playLog() -> [(String, Double)] {
        var out: [(String, Double)] = []
        query("SELECT id, at FROM plays") { out.append((Self.text($0, 0) ?? "", sqlite3_column_double($0, 1))) }
        return out
    }

    // MARK: - lyrics

    public func lyrics(id: String) -> (segments: String, source: String)? {
        var out: (String, String)?
        query("SELECT segments, source FROM lyrics WHERE id=?", [id]) { out = (Self.text($0, 0) ?? "[]", Self.text($0, 1) ?? "") }
        return out
    }

    public func saveLyrics(id: String, segments: String, source: String) throws {
        try run("REPLACE INTO lyrics (id, segments, source, made) VALUES (?,?,?,?)",
                [id, segments, source, Date().timeIntervalSince1970])
    }

    public func deleteLyrics(id: String) throws {
        try run("DELETE FROM lyrics WHERE id=?", [id])
    }

    /// Forgets every song's lyrics that came from these sources (to write them
    /// again with another model), and says which songs they were.
    @discardableResult
    public func forgetLyrics(sources: [String]) throws -> [String] {
        let marks = sources.map { _ in "?" }.joined(separator: ",")
        var ids: [String] = []
        query("SELECT id FROM lyrics WHERE source IN (\(marks)) ORDER BY id", sources) { ids.append(Self.text($0, 0) ?? "") }
        try run("DELETE FROM lyrics WHERE source IN (\(marks))", sources)
        return ids
    }

    /// Which songs have a lyrics row, and where it came from ("none" = no words found).
    public func lyricsSources() -> [String: String] {
        var out: [String: String] = [:]
        query("SELECT id, source FROM lyrics") { out[Self.text($0, 0) ?? ""] = Self.text($0, 1) ?? "" }
        return out
    }

    /// Every song's lyrics that have words (for searching).
    public func allLyrics() -> [(id: String, segments: String)] {
        var out: [(String, String)] = []
        query("SELECT id, segments FROM lyrics WHERE source != 'none'") { out.append((Self.text($0, 0) ?? "", Self.text($0, 1) ?? "[]")) }
        return out
    }

    public func timing(id: String) -> Double {
        var out = 0.0
        query("SELECT seconds FROM timing WHERE id=?", [id]) { out = sqlite3_column_double($0, 0) }
        return out
    }

    public func setTiming(id: String, seconds: Double) throws {
        try run("REPLACE INTO timing (id, seconds) VALUES (?,?)", [id, seconds])
    }

    // MARK: - backup and restore

    /// A consistent copy of the whole database at `url`, safe while it's in use
    /// (written under a temporary name first).
    public func snapshot(to url: URL) throws {
        let part = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".part")
        try? FileManager.default.removeItem(at: part)
        try run("VACUUM INTO ?", [part.path])
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.moveItem(at: part, to: url)
    }

    public struct MergeSummary: Codable, Sendable, Equatable {
        public var decisions = 0, songs = 0, plays = 0, skips = 0, lyrics = 0
    }

    /// Brings back the history in another copy of this database (a backup's):
    /// decisions, when songs arrived, plays, skips, lyrics and timing nudges.
    /// Nothing already here is changed, and running it twice adds nothing.
    public func merge(from url: URL) throws -> MergeSummary {
        try run("ATTACH DATABASE ? AS saved", [url.path])
        defer { try? exec("DETACH DATABASE saved") }
        var m = MergeSummary()
        try transaction {
            func add(_ sql: String) throws -> Int { try exec(sql); return Int(sqlite3_changes(db)) }
            m.decisions = try add("INSERT OR IGNORE INTO sorted SELECT key, decision, title, src, copied, ts FROM saved.sorted")
            m.songs = try add("INSERT OR IGNORE INTO library SELECT id, path, title, artist, album, duration, size, mtime, added, art FROM saved.library")
            m.plays = try add("INSERT INTO plays SELECT id, at FROM saved.plays s WHERE NOT EXISTS (SELECT 1 FROM plays p WHERE p.id = s.id AND p.at = s.at)")
            m.skips = try add("INSERT INTO skips SELECT id, at FROM saved.skips s WHERE NOT EXISTS (SELECT 1 FROM skips p WHERE p.id = s.id AND p.at = s.at)")
            m.lyrics = try add("INSERT OR IGNORE INTO lyrics SELECT id, segments, source, made FROM saved.lyrics")
            _ = try add("INSERT OR IGNORE INTO timing SELECT id, seconds FROM saved.timing")
        }
        return m
    }

    // MARK: - SQLite plumbing

    public func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func text(_ row: OpaquePointer, _ col: Int32) -> String? {
        guard let c = sqlite3_column_text(row, col) else { return nil }
        return String(cString: c)
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func lastError() -> StoreError {
        StoreError(message: String(cString: sqlite3_errmsg(db)))
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw lastError() }
        for (i, arg) in args.enumerated() {
            let n = Int32(i + 1)
            switch arg {
            case let s as String: sqlite3_bind_text(stmt, n, s, -1, Self.transient)
            case let d as Double: sqlite3_bind_double(stmt, n, d)
            case let v as Int: sqlite3_bind_int64(stmt, n, Int64(v))
            default: sqlite3_bind_null(stmt, n)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ args: [Any?]) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
    }

    private func query(_ sql: String, _ args: [Any?] = [], row: (OpaquePointer) -> Void) {
        guard let stmt = try? prepare(sql, args) else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }
}
