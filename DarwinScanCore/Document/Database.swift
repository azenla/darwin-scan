import Foundation
import SQLite3
import os.lock

/// SQLite manifest for a `.darwinscan` bundle. Schema v2 (bundle format v4) —
/// incompatible with the previous JSON/v3 layouts; old bundles fail to open.
///
/// ## Why the rewrite
///
/// The old layout stuffed the whole `ScanItem` into a JSON `payload` blob with
/// only `category` and `owning_bundle_path` indexed. Anything else cost an
/// O(N) decode pass through the JSON. The new layout promotes every field a
/// query is likely to filter or sort on to a real column with an index, and
/// adds dedicated tables for symbols, tags, architectures, relationships,
/// blobs, snapshots, plus FTS5 virtual tables for full-text search over
/// symbols and extracted strings.
///
/// ## Tables
///
/// | Table             | Purpose                                                            |
/// |-------------------|--------------------------------------------------------------------|
/// | `meta`            | Key/value bag: schema_version, last-scan timestamps                |
/// | `snapshots`       | Append-only scan history. Latest row is the "current" snapshot.    |
/// | `snapshot_items`  | Membership: which items belong to which snapshot.                  |
/// | `items`           | One row per (path, sha256). Hot fields as columns, rest as payload.|
/// | `tags`            | Free-form tag chips, one row per (item, tag).                      |
/// | `architectures`   | Mach-O architectures, one row per (item, arch).                    |
/// | `relationships`   | Outgoing graph edges (linksDylib / ownedByBundle / etc).           |
/// | `symbols`         | Function / Obj-C class / Swift class names per item.               |
/// | `symbols_fts`     | FTS5 virtual table mirroring `symbols.name` + `symbols.demangled`. |
/// | `strings_fts`     | FTS5 virtual table holding `/usr/bin/strings` output per item.     |
/// | `blobs`           | Registry of content-addressed blobs stored on disk under `blobs/`. |
///
/// All non-FTS tables are written through prepared statements. The FTS tables
/// are populated by the inspector pipeline (symbols by `SymbolInspector`,
/// strings by `StringsExtractor`) — Database doesn't try to mirror them off
/// the `symbols`/blob tables via triggers because the source data lives off
/// the SQLite row (strings text is in a blob file).
///
/// ## Concurrency
///
/// `Database` is `final class @unchecked Sendable` because it carries an
/// `OpaquePointer` (sqlite3*) plus a pile of prepared statements. Writes are
/// serialized through an internal `os_unfair_lock`. Reads are also gated
/// through the lock so transactions don't interleave. SQLite is compiled
/// `SERIALIZED` on Apple platforms; the lock is belt-and-suspenders.
public nonisolated final class Database: @unchecked Sendable {
    /// Bump when schema changes. Persisted under `meta.schema_version`.
    public static let currentSchemaVersion: Int = 3

    private var db: OpaquePointer?
    private var lock = os_unfair_lock_s()

    // Prepared statements — cached for the connection lifetime.
    private var stmts: PreparedStatements = .init()

    private struct PreparedStatements {
        var upsertItem: OpaquePointer?
        var deleteItem: OpaquePointer?
        var clearItems: OpaquePointer?
        var allItems: OpaquePointer?
        var itemByID: OpaquePointer?
        var itemByPath: OpaquePointer?

        var deleteTagsForItem: OpaquePointer?
        var insertTag: OpaquePointer?

        var deleteArchsForItem: OpaquePointer?
        var insertArch: OpaquePointer?

        var deleteRelsForItem: OpaquePointer?
        var insertRel: OpaquePointer?
        var outgoingTargets: OpaquePointer?

        var insertSymbol: OpaquePointer?
        var deleteSymbolsForItem: OpaquePointer?
        var clearSymbols: OpaquePointer?

        var insertBlob: OpaquePointer?
        var clearBlobs: OpaquePointer?

        var insertSnapshot: OpaquePointer?
        var insertSnapshotItem: OpaquePointer?
        var clearSnapshots: OpaquePointer?
        var clearSnapshotItems: OpaquePointer?

        var insertStringsFTS: OpaquePointer?
        var deleteStringsFTSForItem: OpaquePointer?

        var setMeta: OpaquePointer?
        var getMeta: OpaquePointer?
    }

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

    public enum DBError: Error, CustomStringConvertible {
        case open(String)
        case prepare(String)
        case step(String)
        case schemaTooOld(Int)
        case schemaTooNew(Int)

        public var description: String {
            switch self {
            case .open(let m):           return "Database.open: \(m)"
            case .prepare(let m):        return "Database.prepare: \(m)"
            case .step(let m):           return "Database.step: \(m)"
            case .schemaTooOld(let v):   return "Database: schema v\(v) is from a prior version of DarwinScan and is not supported. Bundle format v5 (schema v\(Database.currentSchemaVersion)) is required — re-scan to produce a new bundle."
            case .schemaTooNew(let v):   return "Database: schema v\(v) is from a newer DarwinScan than this build supports."
            }
        }
    }

    public init(at url: URL) throws {
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
        try execRaw("PRAGMA temp_store=MEMORY;")
        try execRaw("PRAGMA cache_size=-32000;") // 32 MB page cache

        try runDDL()
        try prepareStatements()
        try writeOrCheckSchemaVersion()
    }

    deinit {
        finalizeAllStatements()
        if let db {
            sqlite3_close_v2(db)
        }
    }

    public func close() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        finalizeAllStatements()
        if let db {
            sqlite3_close_v2(db)
        }
        db = nil
    }

    // MARK: - Items

    public func upsertItem(_ item: ScanItem) throws {
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

    /// Bulk insert/update in a single transaction. A scan flush is ~256 items;
    /// running each upsert as its own transaction would dominate write time.
    public func upsertItems(_ items: [ScanItem]) throws {
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

    public func deleteItem(id: UUID) throws {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let key = id.uuidString.lowercased()
        try beginTransaction()
        do {
            try bindAndStep(stmts.deleteTagsForItem, label: "deleteTagsForItem") { sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT) }
            try bindAndStep(stmts.deleteArchsForItem, label: "deleteArchsForItem") { sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT) }
            try bindAndStep(stmts.deleteRelsForItem, label: "deleteRelsForItem") { sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT) }
            try bindAndStep(stmts.deleteSymbolsForItem, label: "deleteSymbolsForItem") { sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT) }
            try bindAndStep(stmts.deleteStringsFTSForItem, label: "deleteStringsFTSForItem") { sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT) }
            try bindAndStep(stmts.deleteItem, label: "deleteItem") { sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT) }
            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }

    public func clearItems() throws {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        try beginTransaction()
        do {
            try execLocked("DELETE FROM tags;")
            try execLocked("DELETE FROM architectures;")
            try execLocked("DELETE FROM relationships;")
            // `DELETE FROM symbols` fires the AFTER DELETE trigger that
            // removes matching rowids from symbols_fts, so we don't need an
            // explicit FTS5 'delete-all' command for the symbol index.
            try execLocked("DELETE FROM symbols;")
            // strings_fts is contentless — rows have no source table that a
            // trigger could mirror. Drop+recreate is the only safe global
            // clear, and the cheapest way to do it within a transaction.
            try execLocked("DROP TABLE strings_fts;")
            try execLocked("""
                CREATE VIRTUAL TABLE strings_fts USING fts5(
                    item_id UNINDEXED,
                    item_path UNINDEXED,
                    content,
                    tokenize='unicode61'
                );
                """)
            try execLocked("DELETE FROM blobs;")
            try execLocked("DELETE FROM snapshot_items;")
            try execLocked("DELETE FROM snapshots;")
            try execLocked("DELETE FROM items;")
            try commitTransaction()
            // Rebuilding strings_fts invalidates the prepared statement that
            // points at the previous virtual table — re-prepare it.
            try reprepareStringsFTSStatements()
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }

    private func reprepareStringsFTSStatements() throws {
        if let p = stmts.insertStringsFTS { sqlite3_finalize(p) }
        if let p = stmts.deleteStringsFTSForItem { sqlite3_finalize(p) }
        stmts.insertStringsFTS = try prepare("INSERT INTO strings_fts(item_id, item_path, content) VALUES (?, ?, ?)")
        stmts.deleteStringsFTSForItem = try prepare("DELETE FROM strings_fts WHERE item_id = ?")
    }

    public func item(id: UUID) throws -> ScanItem? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let stmt = stmts.itemByID else { throw DBError.prepare("itemByID statement nil") }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, id.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else {
            throw DBError.step("itemByID sqlite3_step -> \(rc): \(lastError())")
        }
        return try decodePayloadColumn(stmt: stmt, column: 0)
    }

    public func item(atPath path: String) throws -> ScanItem? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let stmt = stmts.itemByPath else { throw DBError.prepare("itemByPath statement nil") }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else {
            throw DBError.step("itemByPath sqlite3_step -> \(rc): \(lastError())")
        }
        return try decodePayloadColumn(stmt: stmt, column: 0)
    }

    public func outgoingTargets(sourceID: UUID) throws -> [String] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let stmt = stmts.outgoingTargets else { throw DBError.prepare("outgoingTargets statement nil") }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, sourceID.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
        var results: [String] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw DBError.step("outgoingTargets sqlite3_step -> \(rc): \(lastError())")
            }
            if let cstr = sqlite3_column_text(stmt, 0) {
                results.append(String(cString: cstr))
            }
        }
        return results
    }

    /// Streams every item row back as a `ScanItem`. Called once on document
    /// open; for very large scans we could switch this to a cursor-based
    /// generator but the JSON decode dominates anyway.
    public func allItems() throws -> [ScanItem] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let stmt = stmts.allItems else { throw DBError.prepare("allItems statement nil") }
        sqlite3_reset(stmt)
        var result: [ScanItem] = []
        result.reserveCapacity(1024)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw DBError.step("allItems sqlite3_step -> \(rc): \(lastError())")
            }
            do {
                if let item = try decodePayloadColumn(stmt: stmt, column: 0) {
                    result.append(item)
                }
            } catch {
                // Skip rows that don't decode — schema drift inside the JSON
                // payload would be the only plausible cause and we'd rather
                // show partial data than refuse the whole bundle.
                print("[Database] Skipping undecodable item row: \(error)")
            }
        }
        return result
    }

    // MARK: - Symbols

    /// Bulk insert symbols for an item. Symbols are append-only per (item, name,
    /// kind) — re-scanning replaces the lot via `deleteSymbols(forItem:)`.
    public func insertSymbols(_ rows: [SymbolRow]) throws {
        guard !rows.isEmpty else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        try beginTransaction()
        do {
            for row in rows {
                try bindAndStep(stmts.insertSymbol, label: "insertSymbol") { stmt in
                    sqlite3_bind_text(stmt, 1, row.itemID.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, row.name, -1, SQLITE_TRANSIENT)
                    if let dem = row.demangled {
                        sqlite3_bind_text(stmt, 3, dem, -1, SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_null(stmt, 3)
                    }
                    sqlite3_bind_text(stmt, 4, row.kind.rawValue, -1, SQLITE_TRANSIENT)
                    if let ord = row.libraryOrdinal {
                        sqlite3_bind_int(stmt, 5, Int32(ord))
                    } else {
                        sqlite3_bind_null(stmt, 5)
                    }
                }
            }
            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }

    public func deleteSymbols(forItem itemID: UUID) throws {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        try bindAndStep(stmts.deleteSymbolsForItem, label: "deleteSymbolsForItem") { stmt in
            sqlite3_bind_text(stmt, 1, itemID.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
        }
    }

    public func symbolCount(forItem itemID: UUID) throws -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        defer { if let stmt { sqlite3_finalize(stmt) } }
        let sql = "SELECT COUNT(*) FROM symbols WHERE item_id = ?;"
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw DBError.prepare("symbolCount prepare -> \(rc): \(lastError())")
        }
        sqlite3_bind_text(stmt, 1, itemID.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// All symbols for a single item, used by the detail view.
    public func symbols(forItem itemID: UUID, limit: Int = 5000) throws -> [SymbolRow] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { if let stmt { sqlite3_finalize(stmt) } }
        let sql = "SELECT name, demangled, kind, library_ordinal FROM symbols WHERE item_id = ? ORDER BY kind, name LIMIT ?;"
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw DBError.prepare("symbols(forItem) prepare -> \(rc): \(lastError())")
        }
        sqlite3_bind_text(stmt, 1, itemID.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [SymbolRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let nameC = sqlite3_column_text(stmt, 0) else { continue }
            let name = String(cString: nameC)
            let demangled: String? = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            guard let kindC = sqlite3_column_text(stmt, 2),
                  let kind = SymbolRow.Kind(rawValue: String(cString: kindC)) else { continue }
            let ord: Int? = (sqlite3_column_type(stmt, 3) == SQLITE_NULL)
                ? nil
                : Int(sqlite3_column_int(stmt, 3))
            out.append(SymbolRow(itemID: itemID, name: name, demangled: demangled, kind: kind, libraryOrdinal: ord))
        }
        return out
    }

    /// FTS5 symbol search. `query` is a raw FTS5 MATCH expression — callers
    /// are responsible for escaping (`SearchQuery` builds these). Returns
    /// `(itemID, name, kind)` triples, ordered by FTS rank.
    public func searchSymbols(query: String, limit: Int = 500) throws -> [SymbolHit] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { if let stmt { sqlite3_finalize(stmt) } }
        let sql = """
            SELECT symbols.item_id, symbols.name, symbols.demangled, symbols.kind
            FROM symbols_fts
            JOIN symbols ON symbols.id = symbols_fts.rowid
            WHERE symbols_fts MATCH ?
            ORDER BY rank
            LIMIT ?;
            """
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw DBError.prepare("searchSymbols prepare -> \(rc): \(lastError())")
        }
        sqlite3_bind_text(stmt, 1, query, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [SymbolHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0),
                  let nameC = sqlite3_column_text(stmt, 1) else { continue }
            let idStr = String(cString: idC)
            guard let id = UUID(uuidString: idStr) else { continue }
            let name = String(cString: nameC)
            let dem: String? = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let kindStr: String = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "function"
            let kind = SymbolRow.Kind(rawValue: kindStr) ?? .function
            out.append(SymbolHit(itemID: id, name: name, demangled: dem, kind: kind))
        }
        return out
    }

    // MARK: - Strings FTS

    /// Insert a strings-dump chunk into `strings_fts`. The blob bytes live in
    /// the BlobStore; this just lets a query find which items had a given
    /// substring in their strings dump.
    public func indexStrings(itemID: UUID, itemPath: String, content: String) throws {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        try bindAndStep(stmts.insertStringsFTS, label: "insertStringsFTS") { stmt in
            sqlite3_bind_text(stmt, 1, itemID.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, itemPath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, content, -1, SQLITE_TRANSIENT)
        }
    }

    /// FTS5 strings search. Returns `(itemID, itemPath, snippet)` triples.
    public func searchStrings(query: String, limit: Int = 200) throws -> [StringsHit] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { if let stmt { sqlite3_finalize(stmt) } }
        let sql = """
            SELECT item_id, item_path, snippet(strings_fts, 2, '«', '»', '…', 12)
            FROM strings_fts
            WHERE strings_fts MATCH ?
            ORDER BY rank
            LIMIT ?;
            """
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw DBError.prepare("searchStrings prepare -> \(rc): \(lastError())")
        }
        sqlite3_bind_text(stmt, 1, query, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [StringsHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0),
                  let id = UUID(uuidString: String(cString: idC)),
                  let pathC = sqlite3_column_text(stmt, 1) else { continue }
            let snippet: String = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            out.append(StringsHit(itemID: id, itemPath: String(cString: pathC), snippet: snippet))
        }
        return out
    }

    // MARK: - Blobs

    public func registerBlob(ref: String, sha256: String, size: Int, kind: String?) throws {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        try bindAndStep(stmts.insertBlob, label: "insertBlob") { stmt in
            sqlite3_bind_text(stmt, 1, ref, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, sha256, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, Int64(size))
            if let kind {
                sqlite3_bind_text(stmt, 4, kind, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
        }
    }

    // MARK: - Snapshots

    /// Create a new snapshot row. Pass `parentID` to chain off the previous
    /// snapshot for incremental scans. `systemInfo` should be the captured
    /// sw_vers / hardware / SIP-state blob (encoded JSON); it's stored on the
    /// snapshot row so a future diff command can show "macOS 26.5.1 →
    /// 26.5.2" even when no items changed enough to retain the snapshot.
    /// Returns the new snapshot's id.
    @discardableResult
    public func insertSnapshot(parentID: Int64?, label: String?, startedAt: Date, completedAt: Date?, systemInfo: Data? = nil) throws -> Int64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let db else { throw DBError.prepare("db is nil") }
        try bindAndStep(stmts.insertSnapshot, label: "insertSnapshot") { stmt in
            if let parentID {
                sqlite3_bind_int64(stmt, 1, parentID)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            if let label {
                sqlite3_bind_text(stmt, 2, label, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_double(stmt, 3, startedAt.timeIntervalSince1970)
            if let completedAt {
                sqlite3_bind_double(stmt, 4, completedAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            if let systemInfo {
                _ = systemInfo.withUnsafeBytes { raw -> Int32 in
                    if let base = raw.baseAddress {
                        return sqlite3_bind_blob(stmt, 5, base, Int32(systemInfo.count), SQLITE_TRANSIENT)
                    } else {
                        return sqlite3_bind_zeroblob(stmt, 5, 0)
                    }
                }
            } else {
                sqlite3_bind_null(stmt, 5)
            }
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// Remove a snapshot row and its membership entries. Used by the
    /// "scan produced no changes — discard the empty snapshot" path. Items
    /// shared with other snapshots stay in place; only this snapshot's
    /// `snapshot_items` rows are dropped.
    public func deleteSnapshot(id: Int64) throws {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        try beginTransaction()
        do {
            guard let db else { throw DBError.prepare("db is nil") }
            var s1: OpaquePointer?; defer { if let s1 { sqlite3_finalize(s1) } }
            let rc1 = sqlite3_prepare_v2(db, "DELETE FROM snapshot_items WHERE snapshot_id = ?;", -1, &s1, nil)
            guard rc1 == SQLITE_OK, let s1 else { throw DBError.prepare("deleteSnapshot.items prepare -> \(rc1)") }
            sqlite3_bind_int64(s1, 1, id)
            let r1 = sqlite3_step(s1)
            guard r1 == SQLITE_DONE else { throw DBError.step("deleteSnapshot.items step -> \(r1)") }

            var s2: OpaquePointer?; defer { if let s2 { sqlite3_finalize(s2) } }
            let rc2 = sqlite3_prepare_v2(db, "DELETE FROM snapshots WHERE id = ?;", -1, &s2, nil)
            guard rc2 == SQLITE_OK, let s2 else { throw DBError.prepare("deleteSnapshot.row prepare -> \(rc2)") }
            sqlite3_bind_int64(s2, 1, id)
            let r2 = sqlite3_step(s2)
            guard r2 == SQLITE_DONE else { throw DBError.step("deleteSnapshot.row step -> \(r2)") }
            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }

    public func addItemToSnapshot(snapshotID: Int64, itemID: UUID) throws {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        try bindAndStep(stmts.insertSnapshotItem, label: "insertSnapshotItem") { stmt in
            sqlite3_bind_int64(stmt, 1, snapshotID)
            sqlite3_bind_text(stmt, 2, itemID.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
        }
    }

    public func addItemsToSnapshot(snapshotID: Int64, itemIDs: [UUID]) throws {
        guard !itemIDs.isEmpty else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        try beginTransaction()
        do {
            for itemID in itemIDs {
                try bindAndStep(stmts.insertSnapshotItem, label: "insertSnapshotItem") { stmt in
                    sqlite3_bind_int64(stmt, 1, snapshotID)
                    sqlite3_bind_text(stmt, 2, itemID.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
                }
            }
            try commitTransaction()
        } catch {
            try? rollbackTransaction()
            throw error
        }
    }

    /// Mark a snapshot as completed. Idempotent — a re-call just overwrites
    /// the timestamp, which is what you want when a scan resumes after a
    /// crash and finishes the second time around.
    public func completeSnapshot(id: Int64, at completedAt: Date) throws {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let db else { throw DBError.prepare("db is nil") }
        var stmt: OpaquePointer?
        defer { if let stmt { sqlite3_finalize(stmt) } }
        let sql = "UPDATE snapshots SET completed_at = ? WHERE id = ?;"
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw DBError.prepare("completeSnapshot prepare -> \(rc)")
        }
        sqlite3_bind_double(stmt, 1, completedAt.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 2, id)
        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_DONE else {
            throw DBError.step("completeSnapshot step -> \(stepRC)")
        }
    }

    /// Rowid of the most-recent snapshot, or nil for a fresh bundle.
    public func latestSnapshotID() throws -> Int64? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let db else { return nil }
        var stmt: OpaquePointer?
        defer { if let stmt { sqlite3_finalize(stmt) } }
        let sql = "SELECT id FROM snapshots ORDER BY id DESC LIMIT 1;"
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { return nil }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        return nil
    }

    /// Full snapshot history. Returned newest-first so the UI doesn't need
    /// to reverse it. Used by future diff / history views.
    public func allSnapshots() throws -> [SnapshotRecord] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { if let stmt { sqlite3_finalize(stmt) } }
        let sql = "SELECT id, parent_id, label, started_at, completed_at, system_info FROM snapshots ORDER BY id DESC;"
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { return [] }
        var out: [SnapshotRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let parent: Int64? = (sqlite3_column_type(stmt, 1) == SQLITE_NULL) ? nil : sqlite3_column_int64(stmt, 1)
            let label: String? = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let started = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let completed: Date? = (sqlite3_column_type(stmt, 4) == SQLITE_NULL)
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            var sysInfo: SystemInfo? = nil
            if sqlite3_column_type(stmt, 5) != SQLITE_NULL,
               let blob = sqlite3_column_blob(stmt, 5) {
                let len = Int(sqlite3_column_bytes(stmt, 5))
                let data = Data(bytes: blob, count: len)
                sysInfo = try? decoder.decode(SystemInfo.self, from: data)
            }
            out.append(SnapshotRecord(id: id, parentID: parent, label: label, startedAt: started, completedAt: completed, systemInfo: sysInfo))
        }
        return out
    }

    /// Items belonging to a snapshot, hydrated from `items.payload` joined
    /// on `snapshot_items`. Used by `ScanStore.load` to show "the latest
    /// snapshot" rather than every version ever recorded.
    public func itemsForSnapshot(_ snapshotID: Int64) throws -> [ScanItem] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { if let stmt { sqlite3_finalize(stmt) } }
        let sql = """
            SELECT i.payload FROM items i
            JOIN snapshot_items si ON si.item_id = i.id
            WHERE si.snapshot_id = ?;
            """
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { return [] }
        sqlite3_bind_int64(stmt, 1, snapshotID)
        var out: [ScanItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
            let len = Int(sqlite3_column_bytes(stmt, 0))
            let data = Data(bytes: blob, count: len)
            if let item = try? decoder.decode(ScanItem.self, from: data) {
                out.append(item)
            }
        }
        return out
    }

    /// Set membership of a snapshot: the item IDs of everything it contains.
    /// Future diff code: `itemsInSnapshot(a) symmetric-difference itemsInSnapshot(b)`.
    public func itemsInSnapshot(_ snapshotID: Int64) throws -> Set<UUID> {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let db else { return [] }
        var stmt: OpaquePointer?
        defer { if let stmt { sqlite3_finalize(stmt) } }
        let sql = "SELECT item_id FROM snapshot_items WHERE snapshot_id = ?;"
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { return [] }
        sqlite3_bind_int64(stmt, 1, snapshotID)
        var out: Set<UUID> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0),
               let uuid = UUID(uuidString: String(cString: c)) {
                out.insert(uuid)
            }
        }
        return out
    }

    // MARK: - Meta

    public func setMeta(_ key: String, json: Data) throws {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        try setMetaLocked(key: key, blob: json)
    }

    public func meta(_ key: String) throws -> Data? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let stmt = stmts.getMeta else { return nil }
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

    public func setMeta<T: Encodable>(_ key: String, value: T) throws {
        let data = try encoder.encode(value)
        try setMeta(key, json: data)
    }

    public func meta<T: Decodable>(_ key: String, as: T.Type) throws -> T? {
        guard let data = try meta(key) else { return nil }
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Checkpoint

    public func checkpoint() throws {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let db else { return }
        let rc = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        guard rc == SQLITE_OK else {
            throw DBError.step("wal_checkpoint -> \(rc): \(lastError())")
        }
    }

    // MARK: - Locked helpers

    private func upsertItemLocked(_ item: ScanItem) throws {
        let idKey = item.id.uuidString.lowercased()
        let payload = try encoder.encode(item)

        try bindAndStep(stmts.upsertItem, label: "upsertItem") { stmt in
            sqlite3_bind_text(stmt, 1, idKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, item.path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, item.name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, item.category.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 5, item.size)
            if let m = item.modifiedAt {
                sqlite3_bind_double(stmt, 6, m.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            bindOptText(stmt, 7, item.sha256)
            sqlite3_bind_int(stmt, 8, item.insideBundle ? 1 : 0)
            bindOptText(stmt, 9, item.owningBundlePath)
            bindOptText(stmt, 10, item.context)
            bindOptText(stmt, 11, item.executable?.kind.rawValue)
            bindOptText(stmt, 12, item.executable?.platform)
            bindOptText(stmt, 13, item.executable?.minOS)
            bindOptText(stmt, 14, item.executable?.sdkVersion)
            sqlite3_bind_int(stmt, 15, (item.executable?.isFatBinary ?? false) ? 1 : 0)
            sqlite3_bind_int(stmt, 16, (item.executable?.isApple ?? false) ? 1 : 0)
            sqlite3_bind_int(stmt, 17, (item.executable?.isCrossPlatformTool ?? false) ? 1 : 0)
            bindOptText(stmt, 18, item.executable?.usageLine)
            bindOptText(stmt, 19, item.application?.bundleIdentifier ?? item.framework?.bundleIdentifier)
            bindOptText(stmt, 20, item.application?.shortVersionString ?? item.framework?.shortVersionString)
            bindOptText(stmt, 21, item.application?.bundleVersion)
            bindOptText(stmt, 22, item.application?.displayName)
            bindOptText(stmt, 23, item.application?.executableName ?? item.framework?.executableName)
            sqlite3_bind_int(stmt, 24, (item.framework?.isPrivate ?? false) ? 1 : 0)
            bindOptText(stmt, 25, item.localization?.language)
            bindOptText(stmt, 26, item.application?.iconRef ?? item.icon?.previewBlobRef)
            bindOptText(stmt, 27, item.executable?.stringsBlobRef)
            bindOptText(stmt, 28, item.fileBlobRef)
            _ = payload.withUnsafeBytes { raw -> Int32 in
                if let base = raw.baseAddress {
                    return sqlite3_bind_blob(stmt, 29, base, Int32(payload.count), SQLITE_TRANSIENT)
                } else {
                    return sqlite3_bind_zeroblob(stmt, 29, 0)
                }
            }
        }

        // Per-item child rows: rebuild rather than diff. Cheaper for our
        // typical N (≤ ~40 tags/archs/relationships per item).
        try bindAndStep(stmts.deleteTagsForItem, label: "deleteTagsForItem") { stmt in
            sqlite3_bind_text(stmt, 1, idKey, -1, SQLITE_TRANSIENT)
        }
        for tag in item.tags {
            try bindAndStep(stmts.insertTag, label: "insertTag") { stmt in
                sqlite3_bind_text(stmt, 1, idKey, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, tag, -1, SQLITE_TRANSIENT)
            }
        }

        try bindAndStep(stmts.deleteArchsForItem, label: "deleteArchsForItem") { stmt in
            sqlite3_bind_text(stmt, 1, idKey, -1, SQLITE_TRANSIENT)
        }
        for arch in item.executable?.architectures ?? [] {
            try bindAndStep(stmts.insertArch, label: "insertArch") { stmt in
                sqlite3_bind_text(stmt, 1, idKey, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, arch, -1, SQLITE_TRANSIENT)
            }
        }

        try bindAndStep(stmts.deleteRelsForItem, label: "deleteRelsForItem") { stmt in
            sqlite3_bind_text(stmt, 1, idKey, -1, SQLITE_TRANSIENT)
        }
        for rel in item.relationships {
            try bindAndStep(stmts.insertRel, label: "insertRel") { stmt in
                sqlite3_bind_text(stmt, 1, idKey, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, rel.kind.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, rel.targetPath, -1, SQLITE_TRANSIENT)
                sqlite3_bind_null(stmt, 4) // target_id resolved at scan-finalize time
                if let note = rel.note {
                    sqlite3_bind_text(stmt, 5, note, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
            }
        }
    }

    private func setMetaLocked(key: String, blob: Data) throws {
        try bindAndStep(stmts.setMeta, label: "setMeta") { stmt in
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            _ = blob.withUnsafeBytes { raw -> Int32 in
                if let base = raw.baseAddress {
                    return sqlite3_bind_blob(stmt, 2, base, Int32(blob.count), SQLITE_TRANSIENT)
                } else {
                    return sqlite3_bind_zeroblob(stmt, 2, 0)
                }
            }
        }
    }

    private func decodePayloadColumn(stmt: OpaquePointer, column: Int32) throws -> ScanItem? {
        guard let blob = sqlite3_column_blob(stmt, column) else { return nil }
        let len = Int(sqlite3_column_bytes(stmt, column))
        let data = Data(bytes: blob, count: len)
        return try decoder.decode(ScanItem.self, from: data)
    }

    // MARK: - Setup

    private func runDDL() throws {
        try execRaw("""
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value BLOB NOT NULL
            );

            CREATE TABLE IF NOT EXISTS snapshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                parent_id INTEGER,
                label TEXT,
                started_at REAL NOT NULL,
                completed_at REAL,
                system_info BLOB,
                FOREIGN KEY (parent_id) REFERENCES snapshots(id)
            );

            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY,
                path TEXT NOT NULL,
                name TEXT NOT NULL,
                category TEXT NOT NULL,
                size INTEGER NOT NULL,
                modified_at REAL,
                sha256 TEXT,
                inside_bundle INTEGER NOT NULL DEFAULT 0,
                owning_bundle_path TEXT,
                context TEXT,
                macho_kind TEXT,
                macho_platform TEXT,
                macho_min_os TEXT,
                macho_sdk TEXT,
                macho_is_fat INTEGER NOT NULL DEFAULT 0,
                macho_is_apple INTEGER NOT NULL DEFAULT 0,
                macho_is_xplat INTEGER NOT NULL DEFAULT 0,
                macho_usage TEXT,
                bundle_identifier TEXT,
                bundle_short_version TEXT,
                bundle_version TEXT,
                bundle_display_name TEXT,
                bundle_exec_name TEXT,
                is_private_bundle INTEGER NOT NULL DEFAULT 0,
                language TEXT,
                icon_blob_ref TEXT,
                strings_blob_ref TEXT,
                file_blob_ref TEXT,
                payload BLOB NOT NULL
            );
            -- items.path is NOT UNIQUE: multi-version items live here. Two
            -- rows can share a path if their content (sha256) differs, with
            -- a different deterministic id distinguishing them. The current
            -- snapshot's snapshot_items entry decides which one a UI shows.
            CREATE INDEX IF NOT EXISTS items_path_idx               ON items(path);
            CREATE INDEX IF NOT EXISTS items_category_idx           ON items(category);
            CREATE INDEX IF NOT EXISTS items_owning_bundle_idx      ON items(owning_bundle_path);
            CREATE INDEX IF NOT EXISTS items_sha256_idx             ON items(sha256);
            CREATE INDEX IF NOT EXISTS items_bundle_id_idx          ON items(bundle_identifier);
            CREATE INDEX IF NOT EXISTS items_language_idx           ON items(language);

            CREATE TABLE IF NOT EXISTS snapshot_items (
                snapshot_id INTEGER NOT NULL,
                item_id TEXT NOT NULL,
                PRIMARY KEY (snapshot_id, item_id)
            );
            CREATE INDEX IF NOT EXISTS snapshot_items_item_idx ON snapshot_items(item_id);

            CREATE TABLE IF NOT EXISTS tags (
                item_id TEXT NOT NULL,
                tag TEXT NOT NULL,
                PRIMARY KEY (item_id, tag)
            );
            CREATE INDEX IF NOT EXISTS tags_tag_idx ON tags(tag);

            CREATE TABLE IF NOT EXISTS architectures (
                item_id TEXT NOT NULL,
                arch TEXT NOT NULL,
                PRIMARY KEY (item_id, arch)
            );
            CREATE INDEX IF NOT EXISTS architectures_arch_idx ON architectures(arch);

            CREATE TABLE IF NOT EXISTS relationships (
                source_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                target_path TEXT NOT NULL,
                target_id TEXT,
                note TEXT,
                PRIMARY KEY (source_id, kind, target_path)
            );
            CREATE INDEX IF NOT EXISTS rel_target_path_idx ON relationships(target_path);
            CREATE INDEX IF NOT EXISTS rel_target_id_idx   ON relationships(target_id);

            CREATE TABLE IF NOT EXISTS symbols (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                item_id TEXT NOT NULL,
                name TEXT NOT NULL,
                demangled TEXT,
                kind TEXT NOT NULL,
                library_ordinal INTEGER
            );
            CREATE INDEX IF NOT EXISTS symbols_item_idx ON symbols(item_id);
            CREATE INDEX IF NOT EXISTS symbols_name_idx ON symbols(name);
            CREATE INDEX IF NOT EXISTS symbols_kind_idx ON symbols(kind);

            CREATE TABLE IF NOT EXISTS blobs (
                ref TEXT PRIMARY KEY,
                sha256 TEXT NOT NULL,
                size INTEGER NOT NULL,
                kind TEXT
            );
            CREATE INDEX IF NOT EXISTS blobs_sha256_idx ON blobs(sha256);
            """)

        // FTS5 virtual tables.
        //
        // - `symbols_fts` uses `content='symbols'` so its rowid maps 1:1 with
        //   the symbols table. We populate it via triggers (sqlite handles the
        //   rebuild on DELETE inside the AFTER DELETE trigger using the
        //   `delete` command).
        // - `strings_fts` is contentless (`content=''`) because the source
        //   strings text lives in a blob file on disk; SQLite stores only the
        //   inverted index and `item_id`/`item_path` snippets.
        try execRaw("""
            CREATE VIRTUAL TABLE IF NOT EXISTS symbols_fts USING fts5(
                name,
                demangled,
                content='symbols',
                content_rowid='id',
                tokenize='unicode61'
            );

            CREATE TRIGGER IF NOT EXISTS symbols_ai AFTER INSERT ON symbols BEGIN
                INSERT INTO symbols_fts(rowid, name, demangled)
                VALUES (new.id, new.name, new.demangled);
            END;

            CREATE TRIGGER IF NOT EXISTS symbols_ad AFTER DELETE ON symbols BEGIN
                INSERT INTO symbols_fts(symbols_fts, rowid, name, demangled)
                VALUES ('delete', old.id, old.name, old.demangled);
            END;

            CREATE VIRTUAL TABLE IF NOT EXISTS strings_fts USING fts5(
                item_id UNINDEXED,
                item_path UNINDEXED,
                content,
                tokenize='unicode61'
            );
            """)
    }

    private func writeOrCheckSchemaVersion() throws {
        // If meta is empty we own the schema; stamp the current version.
        // Otherwise verify it matches — older bundles fail loudly so the user
        // knows the format changed.
        if let raw = try? meta("schema_version"),
           let str = String(data: raw, encoding: .utf8),
           let v = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if v < Self.currentSchemaVersion { throw DBError.schemaTooOld(v) }
            if v > Self.currentSchemaVersion { throw DBError.schemaTooNew(v) }
        } else {
            let bytes = Data("\(Self.currentSchemaVersion)".utf8)
            try setMeta("schema_version", json: bytes)
        }
    }

    private func prepareStatements() throws {
        stmts.upsertItem = try prepare("""
            INSERT INTO items (
                id, path, name, category, size, modified_at, sha256,
                inside_bundle, owning_bundle_path, context,
                macho_kind, macho_platform, macho_min_os, macho_sdk,
                macho_is_fat, macho_is_apple, macho_is_xplat, macho_usage,
                bundle_identifier, bundle_short_version, bundle_version,
                bundle_display_name, bundle_exec_name, is_private_bundle,
                language, icon_blob_ref, strings_blob_ref, file_blob_ref,
                payload
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                path=excluded.path, name=excluded.name, category=excluded.category,
                size=excluded.size, modified_at=excluded.modified_at, sha256=excluded.sha256,
                inside_bundle=excluded.inside_bundle, owning_bundle_path=excluded.owning_bundle_path,
                context=excluded.context,
                macho_kind=excluded.macho_kind, macho_platform=excluded.macho_platform,
                macho_min_os=excluded.macho_min_os, macho_sdk=excluded.macho_sdk,
                macho_is_fat=excluded.macho_is_fat, macho_is_apple=excluded.macho_is_apple,
                macho_is_xplat=excluded.macho_is_xplat, macho_usage=excluded.macho_usage,
                bundle_identifier=excluded.bundle_identifier,
                bundle_short_version=excluded.bundle_short_version,
                bundle_version=excluded.bundle_version,
                bundle_display_name=excluded.bundle_display_name,
                bundle_exec_name=excluded.bundle_exec_name,
                is_private_bundle=excluded.is_private_bundle,
                language=excluded.language,
                icon_blob_ref=excluded.icon_blob_ref,
                strings_blob_ref=excluded.strings_blob_ref,
                file_blob_ref=excluded.file_blob_ref,
                payload=excluded.payload
            """)
        stmts.deleteItem = try prepare("DELETE FROM items WHERE id = ?")
        stmts.clearItems = try prepare("DELETE FROM items")
        stmts.allItems = try prepare("SELECT payload FROM items")
        stmts.itemByID = try prepare("SELECT payload FROM items WHERE id = ?")
        stmts.itemByPath = try prepare("SELECT payload FROM items WHERE path = ?")

        stmts.deleteTagsForItem = try prepare("DELETE FROM tags WHERE item_id = ?")
        stmts.insertTag = try prepare("INSERT OR IGNORE INTO tags (item_id, tag) VALUES (?, ?)")

        stmts.deleteArchsForItem = try prepare("DELETE FROM architectures WHERE item_id = ?")
        stmts.insertArch = try prepare("INSERT OR IGNORE INTO architectures (item_id, arch) VALUES (?, ?)")

        stmts.deleteRelsForItem = try prepare("DELETE FROM relationships WHERE source_id = ?")
        stmts.insertRel = try prepare("INSERT OR REPLACE INTO relationships (source_id, kind, target_path, target_id, note) VALUES (?, ?, ?, ?, ?)")
        stmts.outgoingTargets = try prepare("SELECT target_path FROM relationships WHERE source_id = ?")

        stmts.insertSymbol = try prepare("INSERT INTO symbols (item_id, name, demangled, kind, library_ordinal) VALUES (?, ?, ?, ?, ?)")
        stmts.deleteSymbolsForItem = try prepare("DELETE FROM symbols WHERE item_id = ?")
        stmts.clearSymbols = try prepare("DELETE FROM symbols")

        stmts.insertBlob = try prepare("INSERT OR REPLACE INTO blobs (ref, sha256, size, kind) VALUES (?, ?, ?, ?)")
        stmts.clearBlobs = try prepare("DELETE FROM blobs")

        stmts.insertSnapshot = try prepare("INSERT INTO snapshots (parent_id, label, started_at, completed_at, system_info) VALUES (?, ?, ?, ?, ?)")
        stmts.insertSnapshotItem = try prepare("INSERT OR IGNORE INTO snapshot_items (snapshot_id, item_id) VALUES (?, ?)")
        stmts.clearSnapshots = try prepare("DELETE FROM snapshots")
        stmts.clearSnapshotItems = try prepare("DELETE FROM snapshot_items")

        stmts.insertStringsFTS = try prepare("INSERT INTO strings_fts(item_id, item_path, content) VALUES (?, ?, ?)")
        stmts.deleteStringsFTSForItem = try prepare("DELETE FROM strings_fts WHERE item_id = ?")

        stmts.setMeta = try prepare("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        stmts.getMeta = try prepare("SELECT value FROM meta WHERE key = ?")
    }

    private func finalizeAllStatements() {
        let mirror = Mirror(reflecting: stmts)
        for child in mirror.children {
            if let p = child.value as? OpaquePointer {
                sqlite3_finalize(p)
            }
        }
        stmts = .init()
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

    /// Like `execRaw` but assumes the lock is already held — for use inside
    /// transactions in already-locked code paths.
    private func execLocked(_ sql: String) throws {
        try execRaw(sql)
    }

    private func beginTransaction() throws { try execRaw("BEGIN IMMEDIATE TRANSACTION;") }
    private func commitTransaction() throws { try execRaw("COMMIT;") }
    private func rollbackTransaction() throws { try execRaw("ROLLBACK;") }

    private func lastError() -> String {
        guard let db else { return "no db" }
        return String(cString: sqlite3_errmsg(db))
    }
}

// MARK: - Helper bindings

nonisolated private func bindOptText(_ stmt: OpaquePointer, _ idx: Int32, _ s: String?) {
    if let s {
        sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
    } else {
        sqlite3_bind_null(stmt, idx)
    }
}

// MARK: - Public row types

/// Row in the `symbols` table. Inspector code builds these and hands them to
/// `Database.insertSymbols(_:)`.
public nonisolated struct SymbolRow: Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case function          // LC_SYMTAB / dyld export trie function symbol
        case data              // LC_SYMTAB data symbol
        case objcClass         // `_OBJC_CLASS_$_Foo` or `__objc_classname` entry
        case objcMetaClass     // `_OBJC_METACLASS_$_Foo`
        case objcProtocol      // `__objc_protolist` entry
        case swiftClass        // demangles to a Swift class
        case swiftStruct       // demangles to a Swift struct/enum/protocol
        case undefined         // imported (external) symbol
    }

    public var itemID: UUID
    public var name: String
    public var demangled: String?
    public var kind: Kind
    public var libraryOrdinal: Int?

    public init(itemID: UUID, name: String, demangled: String? = nil, kind: Kind, libraryOrdinal: Int? = nil) {
        self.itemID = itemID
        self.name = name
        self.demangled = demangled
        self.kind = kind
        self.libraryOrdinal = libraryOrdinal
    }
}

/// FTS hit returned by `Database.searchSymbols(query:)`.
public nonisolated struct SymbolHit: Sendable, Hashable {
    public var itemID: UUID
    public var name: String
    public var demangled: String?
    public var kind: SymbolRow.Kind
}

/// FTS hit returned by `Database.searchStrings(query:)`.
public nonisolated struct StringsHit: Sendable, Hashable {
    public var itemID: UUID
    public var itemPath: String
    public var snippet: String
}

/// Snapshot history row. Each scan run produces one of these; `parentID`
/// chains to the previous run, enabling a future diff UI to walk the
/// chain backwards. `label` is reserved for user-supplied names (e.g.
/// "macOS 26.5 GM") once the UI exposes a rename affordance — the scan
/// pipeline never sets it directly.
public nonisolated struct SnapshotRecord: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var parentID: Int64?
    public var label: String?
    public var startedAt: Date
    public var completedAt: Date?
    /// sw_vers + uname + hardware info captured at scan start. Nil for
    /// pre-v3 snapshot rows.
    public var systemInfo: SystemInfo?
}

// SQLite's SQLITE_TRANSIENT macro isn't bridged to Swift — declare the
// equivalent destructor manually. Tells SQLite to copy bound values.
nonisolated let SQLITE_TRANSIENT = unsafeBitCast(
    OpaquePointer(bitPattern: -1),
    to: sqlite3_destructor_type.self
)
