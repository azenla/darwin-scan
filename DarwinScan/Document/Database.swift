import Foundation
import SQLite3
import os.lock

/// Thin SQLite wrapper for the scan manifest. Backs `data.db` inside a
/// `.darwinscan` directory package. The store keeps its in-memory dictionary as
/// the source of truth during a session — this database mirrors every write so
/// crashes and incremental saves don't lose work and future lazy-loading has a
/// solid foundation.
///
/// ## Schema (v1)
///
/// ```sql
/// PRAGMA journal_mode=WAL;
/// PRAGMA synchronous=NORMAL;
///
/// CREATE TABLE meta (
///     key   TEXT PRIMARY KEY,
///     value BLOB NOT NULL
/// );
///
/// CREATE TABLE items (
///     id                 TEXT PRIMARY KEY,   -- UUID lowercased
///     path               TEXT UNIQUE NOT NULL,
///     category           TEXT NOT NULL,
///     owning_bundle_path TEXT,
///     payload            BLOB NOT NULL        -- JSON of full ScanItem
/// );
/// CREATE INDEX items_category       ON items(category);
/// CREATE INDEX items_owning_bundle  ON items(owning_bundle_path);
///
/// CREATE TABLE relationships (
///     source_id   TEXT NOT NULL,
///     kind        TEXT NOT NULL,
///     target_path TEXT NOT NULL,
///     note        TEXT,
///     PRIMARY KEY (source_id, kind, target_path)
/// );
/// CREATE INDEX rel_target  ON relationships(target_path);
/// CREATE INDEX rel_source  ON relationships(source_id);
/// ```
///
/// `meta` keys: `schema_version`, `system_info`, `options`,
/// `last_scan_started`, `last_scan_completed`.
///
/// ## Concurrency
///
/// `Database` is `final class @unchecked Sendable` because it carries an
/// `OpaquePointer` (the `sqlite3*` handle) plus prepared statements. Writes are
/// serialized through an internal `os_unfair_lock`. Reads are expected from
/// `MainActor` only. SQLite is compiled with serialized threading mode by
/// default on Apple platforms, but we still gate writes through the lock so
/// transactions don't interleave.
nonisolated final class Database: @unchecked Sendable {
    /// Bump when schema changes. Persisted under `meta.schema_version`.
    static let currentSchemaVersion: Int = 1

    private var db: OpaquePointer?
    private var lock = os_unfair_lock_s()

    // Prepared statements — cached for the lifetime of the connection.
    private var upsertItemStmt: OpaquePointer?
    private var deleteRelStmt: OpaquePointer?
    private var insertRelStmt: OpaquePointer?
    private var deleteItemStmt: OpaquePointer?
    private var clearItemsStmt: OpaquePointer?
    private var clearRelsStmt: OpaquePointer?
    private var allItemsStmt: OpaquePointer?
    private var setMetaStmt: OpaquePointer?
    private var getMetaStmt: OpaquePointer?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    enum DBError: Error, CustomStringConvertible {
        case open(String)
        case prepare(String)
        case step(String)
        case bind(String)

        var description: String {
            switch self {
            case .open(let m):    return "Database.open: \(m)"
            case .prepare(let m): return "Database.prepare: \(m)"
            case .step(let m):    return "Database.step: \(m)"
            case .bind(let m):    return "Database.bind: \(m)"
            }
        }
    }

    init(at url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close_v2(handle) }
            throw DBError.open("sqlite3_open_v2(\(url.path)) -> \(rc): \(msg)")
        }
        self.db = handle

        try execRaw("PRAGMA journal_mode=WAL;")
        try execRaw("PRAGMA synchronous=NORMAL;")
        try execRaw("PRAGMA foreign_keys=OFF;")

        try runDDL()
        try writeSchemaVersionIfAbsent()
        try prepareStatements()
    }

    deinit {
        // Best-effort: finalize statements and close the handle. We don't throw
        // from deinit; if anything failed earlier the OS will reap the file
        // descriptor when the process exits.
        finalizeAllStatements()
        if let db {
            sqlite3_close_v2(db)
        }
    }

    func close() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        finalizeAllStatements()
        if let db {
            sqlite3_close_v2(db)
        }
        db = nil
    }

    // MARK: - Items

    func upsertItem(_ item: ScanItem) throws {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        try beginTransaction()
        do {
            try upsertItemLocked(item)
            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }

    /// Bulk insert/update in a single transaction. Cheap when N is small (one
    /// scan batch is ~256 items) and crucial when N is large (initial seed
    /// from a legacy JSON manifest).
    func upsertItems(_ items: [ScanItem]) throws {
        guard !items.isEmpty else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        try beginTransaction()
        do {
            for item in items {
                try upsertItemLocked(item)
            }
            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }

    func deleteItem(id: UUID) throws {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let key = id.uuidString.lowercased()
        try beginTransaction()
        do {
            try bindAndStep(deleteItemStmt, label: "deleteItem") { stmt in
                sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            }
            try bindAndStep(deleteRelStmt, label: "deleteRel") { stmt in
                sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            }
            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }

    func clearItems() throws {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        try beginTransaction()
        do {
            try bindAndStep(clearRelsStmt, label: "clearRels") { _ in }
            try bindAndStep(clearItemsStmt, label: "clearItems") { _ in }
            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }

    /// Read every row back as a `ScanItem`. Called once on document open; in
    /// the future we'd swap this for streamed / paginated reads.
    func allItems() throws -> [ScanItem] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let stmt = allItemsStmt else {
            throw DBError.prepare("allItems statement nil")
        }
        sqlite3_reset(stmt)
        var result: [ScanItem] = []
        result.reserveCapacity(1024)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw DBError.step("allItems sqlite3_step -> \(rc): \(lastError())")
            }
            guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let len = Int(sqlite3_column_bytes(stmt, 0))
            let data = Data(bytes: blob, count: len)
            do {
                let item = try decoder.decode(ScanItem.self, from: data)
                result.append(item)
            } catch {
                // Skip rows that don't decode — schema drift is the only
                // plausible cause and we'd rather show partial data than fail
                // open of an entire bundle.
                print("[Database] Skipping undecodable item row: \(error)")
            }
        }
        return result
    }

    // MARK: - Meta

    func setMeta(_ key: String, json: Data) throws {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        try setMetaLocked(key: key, blob: json)
    }

    func meta(_ key: String) throws -> Data? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let stmt = getMetaStmt else { return nil }
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else {
            throw DBError.step("meta sqlite3_step -> \(rc): \(lastError())")
        }
        guard let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        let len = Int(sqlite3_column_bytes(stmt, 0))
        return Data(bytes: blob, count: len)
    }

    /// Encode a Codable value and stash it under `key`. Convenience wrapper.
    func setMeta<T: Encodable>(_ key: String, value: T) throws {
        let data = try encoder.encode(value)
        try setMeta(key, json: data)
    }

    /// Decode the value stored under `key` if present.
    func meta<T: Decodable>(_ key: String, as: T.Type) throws -> T? {
        guard let data = try meta(key) else { return nil }
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Checkpoint

    /// Force WAL contents into the main database file. Called before the save
    /// FileWrapper is built so the bytes the OS hands to the document writer
    /// include every committed write.
    func checkpoint() throws {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let db else { return }
        let rc = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        guard rc == SQLITE_OK else {
            throw DBError.step("wal_checkpoint -> \(rc): \(lastError())")
        }
    }

    // MARK: - Locked helpers (caller already holds `lock`)

    private func upsertItemLocked(_ item: ScanItem) throws {
        let idKey = item.id.uuidString.lowercased()
        let payload = try encoder.encode(item)

        // Upsert the row in `items` …
        try bindAndStep(upsertItemStmt, label: "upsertItem") { stmt in
            sqlite3_bind_text(stmt, 1, idKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, item.path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, item.category.rawValue, -1, SQLITE_TRANSIENT)
            if let owning = item.owningBundlePath {
                sqlite3_bind_text(stmt, 4, owning, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            payload.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    sqlite3_bind_blob(stmt, 5, base, Int32(payload.count), SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_zeroblob(stmt, 5, 0)
                }
            }
        }

        // … then rebuild this item's relationships. Cheaper than diffing for
        // the row sizes we see (a few edges per item).
        try bindAndStep(deleteRelStmt, label: "deleteRel") { stmt in
            sqlite3_bind_text(stmt, 1, idKey, -1, SQLITE_TRANSIENT)
        }
        for rel in item.relationships {
            try bindAndStep(insertRelStmt, label: "insertRel") { stmt in
                sqlite3_bind_text(stmt, 1, idKey, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, rel.kind.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, rel.targetPath, -1, SQLITE_TRANSIENT)
                if let note = rel.note {
                    sqlite3_bind_text(stmt, 4, note, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
            }
        }
    }

    private func setMetaLocked(key: String, blob: Data) throws {
        try bindAndStep(setMetaStmt, label: "setMeta") { stmt in
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            blob.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    sqlite3_bind_blob(stmt, 2, base, Int32(blob.count), SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_zeroblob(stmt, 2, 0)
                }
            }
        }
    }

    // MARK: - Setup

    private func runDDL() throws {
        try execRaw("""
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY,
                path TEXT UNIQUE NOT NULL,
                category TEXT NOT NULL,
                owning_bundle_path TEXT,
                payload BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS items_category ON items(category);
            CREATE INDEX IF NOT EXISTS items_owning_bundle ON items(owning_bundle_path);
            CREATE TABLE IF NOT EXISTS relationships (
                source_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                target_path TEXT NOT NULL,
                note TEXT,
                PRIMARY KEY (source_id, kind, target_path)
            );
            CREATE INDEX IF NOT EXISTS rel_target ON relationships(target_path);
            CREATE INDEX IF NOT EXISTS rel_source ON relationships(source_id);
            """)
    }

    private func writeSchemaVersionIfAbsent() throws {
        // If meta is empty, write the schema version. We don't migrate older
        // versions yet — there's only v1.
        let existing = try? meta("schema_version")
        if existing == nil {
            let bytes = Data("\(Self.currentSchemaVersion)".utf8)
            try setMeta("schema_version", json: bytes)
        }
    }

    private func prepareStatements() throws {
        upsertItemStmt = try prepare("""
            INSERT INTO items (id, path, category, owning_bundle_path, payload)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                path=excluded.path,
                category=excluded.category,
                owning_bundle_path=excluded.owning_bundle_path,
                payload=excluded.payload
            """)

        deleteRelStmt   = try prepare("DELETE FROM relationships WHERE source_id = ?")
        insertRelStmt   = try prepare("INSERT OR REPLACE INTO relationships (source_id, kind, target_path, note) VALUES (?, ?, ?, ?)")
        deleteItemStmt  = try prepare("DELETE FROM items WHERE id = ?")
        clearItemsStmt  = try prepare("DELETE FROM items")
        clearRelsStmt   = try prepare("DELETE FROM relationships")
        allItemsStmt    = try prepare("SELECT payload FROM items")
        setMetaStmt     = try prepare("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        getMetaStmt     = try prepare("SELECT value FROM meta WHERE key = ?")
    }

    private func finalizeAllStatements() {
        let all: [OpaquePointer?] = [
            upsertItemStmt, deleteRelStmt, insertRelStmt, deleteItemStmt,
            clearItemsStmt, clearRelsStmt, allItemsStmt, setMetaStmt, getMetaStmt
        ]
        for stmt in all {
            if let stmt { sqlite3_finalize(stmt) }
        }
        upsertItemStmt = nil
        deleteRelStmt = nil
        insertRelStmt = nil
        deleteItemStmt = nil
        clearItemsStmt = nil
        clearRelsStmt = nil
        allItemsStmt = nil
        setMetaStmt = nil
        getMetaStmt = nil
    }

    // MARK: - SQL plumbing

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw DBError.prepare("db is nil") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw DBError.prepare("sqlite3_prepare_v2 -> \(rc): \(lastError()) [\(sql)]")
        }
        return stmt
    }

    /// Reset + bind + step + check. Statements are reused, so reset after each
    /// use is required.
    private func bindAndStep(_ stmt: OpaquePointer?, label: String, bind: (OpaquePointer) -> Void) throws {
        guard let stmt else { throw DBError.prepare("\(label) statement nil") }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        bind(stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError.step("\(label) sqlite3_step -> \(rc): \(lastError())")
        }
    }

    private func execRaw(_ sql: String) throws {
        guard let db else { throw DBError.prepare("db is nil") }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        defer { if let err { sqlite3_free(err) } }
        guard rc == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            throw DBError.step("sqlite3_exec -> \(rc): \(msg) [\(sql)]")
        }
    }

    private func beginTransaction() throws { try execRaw("BEGIN IMMEDIATE TRANSACTION;") }
    private func commitTransaction() throws { try execRaw("COMMIT;") }
    private func rollbackTransaction() throws { try execRaw("ROLLBACK;") }

    private func lastError() -> String {
        guard let db else { return "no db" }
        return String(cString: sqlite3_errmsg(db))
    }
}

// SQLite's SQLITE_TRANSIENT macro isn't bridged to Swift — declare the
// equivalent destructor manually. Tells SQLite to copy bound values.
nonisolated let SQLITE_TRANSIENT = unsafeBitCast(
    OpaquePointer(bitPattern: -1),
    to: sqlite3_destructor_type.self
)
