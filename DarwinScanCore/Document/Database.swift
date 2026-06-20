import Foundation
import SQLite3
import os.lock

/// SQLite manifest for a `.darwinscan` bundle. **Schema v6** — incompatible
/// with everything that came before; older bundles fail to open with a clear
/// re-scan error rather than attempting in-place migration.
///
/// v6 introduces the **two-phase model**: import (fast — find + capture file
/// bytes) and analysis (re-runnable — classify + extract symbols, strings,
/// bundle metadata). Both phases write through the same `Database`, and
/// re-running analysis on a snapshot is a first-class operation.
///
/// ## Tables
///
/// | Table             | Purpose |
/// |-------------------|---------|
/// | `meta`            | Key/value bag. |
/// | `snapshots`       | One row per `import` operation. Carries source provenance (current OS or IPSW) and analysis bookkeeping. |
/// | `snapshot_items`  | Membership: which items belong to which snapshot. |
/// | `items`           | One row per (path, sha256). Identity is deterministic. Analysis state lives here so per-item re-analysis is cheap to track. |
/// | `tags`            | Free-form tag chips. Rebuilt during analysis. |
/// | `architectures`   | Mach-O arch lookup. Rebuilt during analysis. |
/// | `relationships`   | Outgoing graph edges. Rebuilt during analysis. |
/// | `symbols`         | Function / class / undefined-import rows. Rebuilt during analysis. |
/// | `symbols_fts`     | FTS5 mirror of `symbols.name` + `symbols.demangled`. |
/// | `strings_fts`     | FTS5 index over per-item strings dumps. |
/// | `blobs`           | Registry of every blob in `blobs/<prefix>/`. |
///
/// ## Concurrency — connection pool
///
/// `Database` owns **one writer connection** (all mutations, serialized by
/// `writeLock`) and a **pool of read-only connections** leased one-per-query.
/// In WAL mode SQLite supports a single writer concurrent with many readers,
/// so UI reads (header listing, scroll lookups, search, detail views) run in
/// parallel with each other *and* with the background analyzer's writes —
/// none of them serialize behind a single global mutex. A long read (e.g. the
/// list view's full-snapshot filter walk) holds just one reader; the rest of
/// the pool stays free for snappy scroll/detail lookups.
///
/// Each `SQLiteConnection` is single-threaded-at-a-time by construction (the
/// writer behind `writeLock`, each reader leased to one caller), so its
/// prepared-statement cache and JSON coders need no further synchronization.
public nonisolated final class Database: @unchecked Sendable {
    /// Bump when schema changes. Persisted under `meta.schema_version`.
    public static let currentSchemaVersion: Int = 6
    /// Current analyzer version stamped on items + snapshots when analysis
    /// completes. Treated opaquely; the UI shows it as-is and the analyzer
    /// uses it to decide whether a snapshot needs re-analysis after a
    /// `darwin-scan` upgrade.
    public static let currentAnalyzerVersion: String = "1"

    // The single writer. Every mutation runs on this connection under
    // `writeLock`; WAL allows it to proceed concurrently with the readers.
    private let writer: SQLiteConnection
    private var writeLock = os_unfair_lock_s()

    // Read-only connection pool. `readerSem` counts available connections;
    // `freeReaders` is the LIFO free-list guarded by `readerPoolLock`.
    private let readers: [SQLiteConnection]
    private let readerSem: DispatchSemaphore
    private var readerPoolLock = os_unfair_lock_s()
    private var freeReaders: [SQLiteConnection]

    public enum DBError: Error, CustomStringConvertible {
        case open(String)
        case prepare(String)
        case step(String)
        case schemaTooOld(Int)
        case schemaTooNew(Int)

        public var description: String {
            switch self {
            case .open(let m):         return "Database.open: \(m)"
            case .prepare(let m):      return "Database.prepare: \(m)"
            case .step(let m):         return "Database.step: \(m)"
            case .schemaTooOld(let v): return "Database: schema v\(v) is from a prior DarwinScan and is not supported. Bundle format v6 (schema v\(Database.currentSchemaVersion)) is required — re-import to produce a new bundle."
            case .schemaTooNew(let v): return "Database: schema v\(v) is from a newer DarwinScan than this build supports."
            }
        }
    }

    public init(at url: URL) throws {
        // Writer first: it creates the file, sets WAL, and runs the DDL — so
        // the tables + WAL/-shm exist before any read-only connection attaches.
        let w: SQLiteConnection
        do {
            w = try SQLiteConnection(path: url.path, readOnly: false)
            try Self.configureWriter(w)
            try w.exec(Self.ddlCore)
            try w.exec(Self.ddlFTS)
        } catch let e as SQLiteConnection.ConnError {
            throw DBError.open("\(e)")
        }

        // Reader pool. Sized to cores but bounded so per-connection page
        // caches + mmap don't balloon memory. Two is enough to keep a long
        // filter walk from starving quick scroll/detail reads.
        let count = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 1))
        var rs: [SQLiteConnection] = []
        do {
            for _ in 0..<count {
                let r = try SQLiteConnection(path: url.path, readOnly: true)
                try Self.configureReader(r)
                rs.append(r)
            }
        } catch let e as SQLiteConnection.ConnError {
            throw DBError.open("\(e)")
        }

        self.writer = w
        self.readers = rs
        self.freeReaders = rs
        self.readerSem = DispatchSemaphore(value: rs.count)

        // self is fully initialized below this line.
        try writeOrCheckSchemaVersion()
    }

    deinit { closeAll() }

    public func close() { closeAll() }

    private func closeAll() {
        os_unfair_lock_lock(&writeLock); defer { os_unfair_lock_unlock(&writeLock) }
        writer.close()
        for r in readers { r.close() }
    }

    // MARK: - Connection leasing

    /// Run `body` on the writer connection, serialized against other writers.
    private func withWriter<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        os_unfair_lock_lock(&writeLock); defer { os_unfair_lock_unlock(&writeLock) }
        return try body(writer)
    }

    /// Lease a read-only connection for the duration of `body`. Blocks only if
    /// every reader is currently in use. `body` MUST NOT call back into another
    /// Database read whose lease could be needed before this one returns when
    /// the pool is exhausted — keep read closures self-contained.
    private func withReader<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        readerSem.wait()
        os_unfair_lock_lock(&readerPoolLock)
        let conn = freeReaders.removeLast()
        os_unfair_lock_unlock(&readerPoolLock)
        defer {
            os_unfair_lock_lock(&readerPoolLock)
            freeReaders.append(conn)
            os_unfair_lock_unlock(&readerPoolLock)
            readerSem.signal()
        }
        return try body(conn)
    }

    // MARK: - Items (writes)

    public func upsertItem(_ item: ScanItem) throws {
        try withWriter { conn in
            try conn.exec("BEGIN IMMEDIATE TRANSACTION;")
            do {
                try upsertItemLocked(item, on: conn)
                try conn.exec("COMMIT;")
            } catch {
                try? conn.exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func upsertItems(_ items: [ScanItem]) throws {
        guard !items.isEmpty else { return }
        try withWriter { conn in
            try conn.exec("BEGIN IMMEDIATE TRANSACTION;")
            do {
                for item in items { try upsertItemLocked(item, on: conn) }
                try conn.exec("COMMIT;")
            } catch {
                try? conn.exec("ROLLBACK;")
                throw error
            }
        }
    }

    /// Stamp the analysis state of a single item.
    public func setItemAnalysisState(
        itemID: UUID,
        state: AnalysisState,
        analyzedAt: Date?,
        analyzerVersion: String?
    ) throws {
        try withWriter { conn in
            try stampAnalysisLocked(itemID: itemID, state: state, analyzedAt: analyzedAt, analyzerVersion: analyzerVersion, on: conn)
        }
    }

    public func deleteItem(id: UUID) throws {
        let key = id.uuidString.lowercased()
        try withWriter { conn in
            try conn.exec("BEGIN IMMEDIATE TRANSACTION;")
            do {
                try write(conn, Self.deleteTagsSQL, "delTags") { sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT) }
                try write(conn, Self.deleteArchsSQL, "delArchs") { sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT) }
                try write(conn, Self.deleteRelsSQL, "delRels") { sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT) }
                try write(conn, Self.deleteSymbolsSQL, "delSymbols") { sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT) }
                try write(conn, Self.deleteStringsFTSSQL, "delStrFTS") { sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT) }
                try write(conn, Self.deleteItemSQL, "delItem") { sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT) }
                try conn.exec("COMMIT;")
            } catch {
                try? conn.exec("ROLLBACK;")
                throw error
            }
        }
    }

    /// Drop the analysis-derived rows for an item without touching the item
    /// itself — symbols, strings_fts, tags, architectures, relationships.
    public func clearAnalysisOutputForItem(_ itemID: UUID) throws {
        try withWriter { conn in
            try conn.exec("BEGIN IMMEDIATE TRANSACTION;")
            do {
                try clearAnalysisOutputLocked(key: itemID.uuidString.lowercased(), on: conn)
                try conn.exec("COMMIT;")
            } catch {
                try? conn.exec("ROLLBACK;")
                throw error
            }
        }
    }

    /// Apply one item's full analysis output in a **single** transaction:
    /// clear stale analysis-derived rows, upsert the refined item, stamp its
    /// analysis state, insert its symbols, then upsert + attach any additional
    /// items the analyzer produced (with their own symbols).
    ///
    /// The analysis worker previously issued four-plus independent
    /// transactions per item. Across a /System-scale snapshot that is millions
    /// of COMMITs and WAL frames. Batching per item into one transaction
    /// collapses that overhead and makes each item's analysis atomic.
    public func applyAnalysis(
        item: ScanItem,
        symbols: [SymbolRow],
        additionalItems: [ScanItem],
        additionalSymbols: [SymbolRow],
        snapshotID: Int64,
        analyzedAt: Date,
        analyzerVersion: String
    ) throws {
        try withWriter { conn in
            try conn.exec("BEGIN IMMEDIATE TRANSACTION;")
            do {
                try clearAnalysisOutputLocked(key: item.id.uuidString.lowercased(), on: conn)
                try upsertItemLocked(item, on: conn)
                try stampAnalysisLocked(itemID: item.id, state: .done, analyzedAt: analyzedAt, analyzerVersion: analyzerVersion, on: conn)
                for row in symbols { try insertSymbolLocked(row, on: conn) }
                for extra in additionalItems {
                    try upsertItemLocked(extra, on: conn)
                    try write(conn, Self.insertSnapshotItemSQL, "insertSnapshotItem") { stmt in
                        sqlite3_bind_int64(stmt, 1, snapshotID)
                        sqlite3_bind_text(stmt, 2, extra.id.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
                    }
                }
                for row in additionalSymbols { try insertSymbolLocked(row, on: conn) }
                try conn.exec("COMMIT;")
            } catch {
                try? conn.exec("ROLLBACK;")
                throw error
            }
        }
    }

    // MARK: - Items (reads)

    public func item(id: UUID) throws -> ScanItem? {
        try withReader { conn in
            let stmt = try conn.prepared(Self.itemByIDSQL)
            defer { sqlite3_reset(stmt) }
            sqlite3_bind_text(stmt, 1, id.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return nil }
            guard rc == SQLITE_ROW else { throw DBError.step("itemByID -> \(rc): \(conn.lastErrorMessage)") }
            return try decodePayload(conn, stmt: stmt, column: 0)
        }
    }

    public func outgoingTargets(sourceID: UUID) throws -> [String] {
        try withReader { conn in
            let stmt = try conn.prepared(Self.outgoingTargetsSQL)
            defer { sqlite3_reset(stmt) }
            sqlite3_bind_text(stmt, 1, sourceID.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
            var results: [String] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw DBError.step("outgoingTargets -> \(rc): \(conn.lastErrorMessage)") }
                if let c = sqlite3_column_text(stmt, 0) { results.append(String(cString: c)) }
            }
            return results
        }
    }

    public func allItems() throws -> [ScanItem] {
        try withReader { conn in
            let stmt = try conn.prepared("SELECT payload FROM items")
            defer { sqlite3_reset(stmt) }
            var result: [ScanItem] = []
            result.reserveCapacity(1024)
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw DBError.step("allItems -> \(rc): \(conn.lastErrorMessage)") }
                do {
                    if let item = try decodePayload(conn, stmt: stmt, column: 0) {
                        result.append(item)
                    }
                } catch {
                    print("[Database] Skipping undecodable item row: \(error)")
                }
            }
            return result
        }
    }

    // MARK: - Symbols

    public func insertSymbols(_ rows: [SymbolRow]) throws {
        guard !rows.isEmpty else { return }
        try withWriter { conn in
            try conn.exec("BEGIN IMMEDIATE TRANSACTION;")
            do {
                for row in rows { try insertSymbolLocked(row, on: conn) }
                try conn.exec("COMMIT;")
            } catch {
                try? conn.exec("ROLLBACK;")
                throw error
            }
        }
    }

    /// Insert one symbol row. Caller must hold the writer + an open transaction.
    private func insertSymbolLocked(_ row: SymbolRow, on conn: SQLiteConnection) throws {
        try write(conn, Self.insertSymbolSQL, "insertSymbol") { stmt in
            sqlite3_bind_text(stmt, 1, row.itemID.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, row.name, -1, SQLITE_TRANSIENT)
            if let d = row.demangled {
                sqlite3_bind_text(stmt, 3, d, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_text(stmt, 4, row.kind.rawValue, -1, SQLITE_TRANSIENT)
            if let ord = row.libraryOrdinal {
                sqlite3_bind_int64(stmt, 5, Int64(ord))
            } else {
                sqlite3_bind_null(stmt, 5)
            }
        }
    }

    public func deleteSymbols(forItem itemID: UUID) throws {
        try withWriter { conn in
            try write(conn, Self.deleteSymbolsSQL, "deleteSymbolsForItem") { stmt in
                sqlite3_bind_text(stmt, 1, itemID.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
            }
        }
    }

    public func symbolCount(forItem itemID: UUID) throws -> Int {
        try withReader { conn in
            let stmt = try conn.prepared("SELECT COUNT(*) FROM symbols WHERE item_id = ?;")
            defer { sqlite3_reset(stmt) }
            sqlite3_bind_text(stmt, 1, itemID.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    public func symbols(forItem itemID: UUID, limit: Int = 5000) throws -> [SymbolRow] {
        try withReader { conn in
            let stmt = try conn.prepared("SELECT name, demangled, kind, library_ordinal FROM symbols WHERE item_id = ? ORDER BY kind, name LIMIT ?;")
            defer { sqlite3_reset(stmt) }
            sqlite3_bind_text(stmt, 1, itemID.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(limit))
            var out: [SymbolRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let nameC = sqlite3_column_text(stmt, 0) else { continue }
                let name = String(cString: nameC)
                let dem: String? = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                guard let kindC = sqlite3_column_text(stmt, 2),
                      let kind = SymbolRow.Kind(rawValue: String(cString: kindC)) else { continue }
                let ord: Int? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 3))
                out.append(SymbolRow(itemID: itemID, name: name, demangled: dem, kind: kind, libraryOrdinal: ord))
            }
            return out
        }
    }

    public func searchSymbols(query: String, limit: Int = 500) throws -> [SymbolHit] {
        try withReader { conn in
            let sql = """
                SELECT symbols.item_id, symbols.name, symbols.demangled, symbols.kind
                FROM symbols_fts JOIN symbols ON symbols.id = symbols_fts.rowid
                WHERE symbols_fts MATCH ? ORDER BY rank LIMIT ?;
                """
            let stmt = try conn.prepared(sql)
            defer { sqlite3_reset(stmt) }
            sqlite3_bind_text(stmt, 1, query, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(limit))
            var out: [SymbolHit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idC = sqlite3_column_text(stmt, 0),
                      let nameC = sqlite3_column_text(stmt, 1) else { continue }
                guard let id = UUID(uuidString: String(cString: idC)) else { continue }
                let name = String(cString: nameC)
                let dem: String? = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let kindStr: String = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "function"
                let kind = SymbolRow.Kind(rawValue: kindStr) ?? .function
                out.append(SymbolHit(itemID: id, name: name, demangled: dem, kind: kind))
            }
            return out
        }
    }

    // MARK: - Strings FTS

    public func indexStrings(itemID: UUID, itemPath: String, content: String) throws {
        try withWriter { conn in
            try write(conn, Self.insertStringsFTSSQL, "insertStringsFTS") { stmt in
                sqlite3_bind_text(stmt, 1, itemID.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, itemPath, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, content, -1, SQLITE_TRANSIENT)
            }
        }
    }

    public func searchStrings(query: String, limit: Int = 200) throws -> [StringsHit] {
        try withReader { conn in
            let sql = """
                SELECT item_id, item_path, snippet(strings_fts, 2, '«', '»', '…', 12)
                FROM strings_fts WHERE strings_fts MATCH ? ORDER BY rank LIMIT ?;
                """
            let stmt = try conn.prepared(sql)
            defer { sqlite3_reset(stmt) }
            sqlite3_bind_text(stmt, 1, query, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(limit))
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
    }

    // MARK: - Blobs

    public func registerBlob(ref: String, sha256: String, size: Int, kind: String?) throws {
        try withWriter { conn in
            try write(conn, Self.insertBlobSQL, "insertBlob") { stmt in
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
    }

    // MARK: - Snapshots

    @discardableResult
    public func insertSnapshot(
        parentID: Int64?,
        label: String?,
        sourceKind: SnapshotSourceKind,
        sourceRef: String?,
        startedAt: Date,
        systemInfo: Data? = nil,
        optionsJSON: Data? = nil
    ) throws -> Int64 {
        try withWriter { conn in
            try write(conn, Self.insertSnapshotSQL, "insertSnapshot") { stmt in
                if let parentID { sqlite3_bind_int64(stmt, 1, parentID) } else { sqlite3_bind_null(stmt, 1) }
                if let label { sqlite3_bind_text(stmt, 2, label, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 2) }
                sqlite3_bind_text(stmt, 3, sourceKind.rawValue, -1, SQLITE_TRANSIENT)
                if let sourceRef { sqlite3_bind_text(stmt, 4, sourceRef, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 4) }
                sqlite3_bind_double(stmt, 5, startedAt.timeIntervalSince1970)
                sqlite3_bind_null(stmt, 6) // import_completed_at
                sqlite3_bind_text(stmt, 7, ImportState.running.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 8, AnalysisState.none.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_null(stmt, 9)  // analyzed_at
                sqlite3_bind_null(stmt, 10) // analyzer_version
                bindOptBlob(stmt, 11, systemInfo)
                bindOptBlob(stmt, 12, optionsJSON)
            }
            return sqlite3_last_insert_rowid(conn.handle)
        }
    }

    public func deleteSnapshot(id: Int64) throws {
        try withWriter { conn in
            try conn.exec("BEGIN IMMEDIATE TRANSACTION;")
            do {
                try write(conn, "DELETE FROM snapshot_items WHERE snapshot_id = ?;", "delSnapItems") {
                    sqlite3_bind_int64($0, 1, id)
                }
                // Items orphaned by this delete — those whose only remaining
                // snapshot membership was the one we just removed — should be
                // cleaned up along with their analysis-derived rows. Compute
                // the orphan id set once into a temp table, then delete by
                // joining against it (a single anti-join instead of six full
                // `NOT IN` scans of snapshot_items).
                try conn.exec("DROP TABLE IF EXISTS _orphans;")
                try conn.exec("""
                    CREATE TEMP TABLE _orphans AS
                    SELECT id FROM items
                    WHERE NOT EXISTS (SELECT 1 FROM snapshot_items si WHERE si.item_id = items.id);
                    """)
                try conn.exec("DELETE FROM tags          WHERE item_id   IN (SELECT id FROM _orphans);")
                try conn.exec("DELETE FROM architectures  WHERE item_id   IN (SELECT id FROM _orphans);")
                try conn.exec("DELETE FROM relationships  WHERE source_id IN (SELECT id FROM _orphans);")
                try conn.exec("DELETE FROM symbols        WHERE item_id   IN (SELECT id FROM _orphans);")
                // strings_fts has no delete trigger, so clear its rows by
                // item_id before dropping the orphan items.
                try conn.exec("DELETE FROM strings_fts    WHERE item_id   IN (SELECT id FROM _orphans);")
                try conn.exec("DELETE FROM items          WHERE id        IN (SELECT id FROM _orphans);")
                try conn.exec("DROP TABLE IF EXISTS _orphans;")
                try write(conn, "DELETE FROM snapshots WHERE id = ?;", "delSnapshot") {
                    sqlite3_bind_int64($0, 1, id)
                }
                try conn.exec("COMMIT;")
            } catch {
                try? conn.exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func addItemsToSnapshot(snapshotID: Int64, itemIDs: [UUID]) throws {
        guard !itemIDs.isEmpty else { return }
        try withWriter { conn in
            try conn.exec("BEGIN IMMEDIATE TRANSACTION;")
            do {
                for itemID in itemIDs {
                    try write(conn, Self.insertSnapshotItemSQL, "insertSnapshotItem") { stmt in
                        sqlite3_bind_int64(stmt, 1, snapshotID)
                        sqlite3_bind_text(stmt, 2, itemID.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
                    }
                }
                try conn.exec("COMMIT;")
            } catch {
                try? conn.exec("ROLLBACK;")
                throw error
            }
        }
    }

    public func markImportComplete(snapshotID: Int64, at completedAt: Date) throws {
        try withWriter { conn in
            try write(conn, "UPDATE snapshots SET import_completed_at = ?, import_state = ? WHERE id = ?;", "markImportComplete") { stmt in
                sqlite3_bind_double(stmt, 1, completedAt.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 2, ImportState.done.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 3, snapshotID)
            }
        }
    }

    public func markSnapshotAnalysis(
        snapshotID: Int64,
        state: AnalysisState,
        analyzedAt: Date?,
        analyzerVersion: String?
    ) throws {
        try withWriter { conn in
            try write(conn, "UPDATE snapshots SET analysis_state = ?, analyzed_at = ?, analyzer_version = ? WHERE id = ?;", "markSnapshotAnalysis") { stmt in
                sqlite3_bind_text(stmt, 1, state.rawValue, -1, SQLITE_TRANSIENT)
                if let analyzedAt { sqlite3_bind_double(stmt, 2, analyzedAt.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 2) }
                if let analyzerVersion { sqlite3_bind_text(stmt, 3, analyzerVersion, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 3) }
                sqlite3_bind_int64(stmt, 4, snapshotID)
            }
        }
    }

    public func latestSnapshotID() throws -> Int64? {
        try withReader { conn in
            let stmt = try conn.prepared("SELECT id FROM snapshots ORDER BY id DESC LIMIT 1;")
            defer { sqlite3_reset(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
        }
    }

    public func allSnapshots() throws -> [SnapshotRecord] {
        try withReader { conn in
            let sql = """
                SELECT id, parent_id, label, source_kind, source_ref, started_at,
                       import_completed_at, import_state, analysis_state,
                       analyzed_at, analyzer_version, system_info
                FROM snapshots ORDER BY id DESC;
                """
            let stmt = try conn.prepared(sql)
            defer { sqlite3_reset(stmt) }
            var out: [SnapshotRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let parent: Int64? = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 1)
                let label: String? = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let sourceKindStr: String = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "currentSystem"
                let sourceKind = SnapshotSourceKind(rawValue: sourceKindStr) ?? .currentSystem
                let sourceRef: String? = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let started = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                let importCompleted: Date? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                let importStateStr: String = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "done"
                let importState = ImportState(rawValue: importStateStr) ?? .done
                let analysisStateStr: String = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? "none"
                let analysisState = AnalysisState(rawValue: analysisStateStr) ?? .none
                let analyzedAt: Date? = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
                let analyzerVersion: String? = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
                var sysInfo: SystemInfo? = nil
                if sqlite3_column_type(stmt, 11) != SQLITE_NULL,
                   let blob = sqlite3_column_blob(stmt, 11) {
                    let len = Int(sqlite3_column_bytes(stmt, 11))
                    let data = Data(bytes: blob, count: len)
                    sysInfo = try? conn.decoder.decode(SystemInfo.self, from: data)
                }
                out.append(SnapshotRecord(
                    id: id, parentID: parent, label: label, sourceKind: sourceKind,
                    sourceRef: sourceRef, startedAt: started, importCompletedAt: importCompleted,
                    importState: importState, analysisState: analysisState,
                    analyzedAt: analyzedAt, analyzerVersion: analyzerVersion, systemInfo: sysInfo
                ))
            }
            return out
        }
    }

    // MARK: - Headers

    /// Standard column set every `ItemHeader` read pulls. Centralised so
    /// callers (single-id lookup, in-snapshot listing, bundle-contents,
    /// referenced-by) all share the same hydration logic.
    private static let headerColumns = """
        i.id, i.path, i.name, i.category, i.size, i.modified_at, i.sha256,
        i.inside_bundle, i.owning_bundle_path, i.context,
        i.macho_kind, i.macho_platform, i.macho_min_os,
        i.macho_is_fat, i.macho_is_apple, i.macho_is_xplat, i.macho_usage,
        i.bundle_identifier, i.language, i.is_private_bundle,
        i.file_blob_ref, i.analysis_state
        """

    /// Build an `ItemHeader` from the columns at offset 0..21 of `stmt`.
    private static func hydrateHeader(stmt: OpaquePointer) -> ItemHeader? {
        guard let idC = sqlite3_column_text(stmt, 0),
              let id = UUID(uuidString: String(cString: idC)) else { return nil }
        let path: String = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let name: String = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let categoryStr: String = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "other"
        let category = ItemCategory(rawValue: categoryStr) ?? .other
        let size = sqlite3_column_int64(stmt, 4)
        let mtime: Date? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
        let sha: String? = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
        let insideBundle = sqlite3_column_int(stmt, 7) != 0
        let owningBundle: String? = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        let context: String? = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
        let machoPlatform: String? = sqlite3_column_text(stmt, 11).map { String(cString: $0) }
        let machoMinOS: String? = sqlite3_column_text(stmt, 12).map { String(cString: $0) }
        let isFat = sqlite3_column_int(stmt, 13) != 0
        let isApple = sqlite3_column_int(stmt, 14) != 0
        let isXplat = sqlite3_column_int(stmt, 15) != 0
        let machoUsage: String? = sqlite3_column_text(stmt, 16).map { String(cString: $0) }
        let bundleId: String? = sqlite3_column_text(stmt, 17).map { String(cString: $0) }
        let language: String? = sqlite3_column_text(stmt, 18).map { String(cString: $0) }
        let isPrivateBundle = sqlite3_column_int(stmt, 19) != 0
        let fileBlobRef: String? = sqlite3_column_text(stmt, 20).map { String(cString: $0) }
        let analysisStateStr: String = sqlite3_column_text(stmt, 21).map { String(cString: $0) } ?? "pending"
        let analysisState = AnalysisState(rawValue: analysisStateStr) ?? .pending

        var header = ItemHeader(from: ScanItem(
            id: id, path: path, name: name, category: category, size: size,
            modifiedAt: mtime, sha256: sha, insideBundle: insideBundle,
            owningBundlePath: owningBundle, fileBlobRef: fileBlobRef,
            tags: [], context: context, relationships: []
        ))
        header.platform = machoPlatform
        header.minOS = machoMinOS
        header.isFatBinary = isFat
        header.isApple = isApple
        header.isCrossPlatformTool = isXplat
        header.usageLine = machoUsage
        header.bundleIdentifier = bundleId
        header.language = language
        header.isPrivateFramework = isPrivateBundle
        header.analysisState = analysisState
        return header
    }

    /// Header lookup by path, scoped to a snapshot. `items.path` is not
    /// unique (multi-version items share a path with different sha256s),
    /// so the snapshot scope is what picks the right row.
    public func itemHeader(atPath path: String, inSnapshot snapshotID: Int64) throws -> ItemHeader? {
        try withReader { conn in
            let sql = """
                SELECT \(Self.headerColumns)
                FROM items i
                JOIN snapshot_items si ON si.item_id = i.id
                WHERE i.path = ? AND si.snapshot_id = ?
                LIMIT 1;
                """
            let stmt = try conn.prepared(sql)
            defer { sqlite3_reset(stmt) }
            sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, snapshotID)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Self.hydrateHeader(stmt: stmt)
        }
    }

    /// Single header by id, with the same column-only fast path everything
    /// else uses.
    public func itemHeader(id: UUID) throws -> ItemHeader? {
        try withReader { conn in
            let stmt = try conn.prepared("SELECT \(Self.headerColumns) FROM items i WHERE i.id = ?;")
            defer { sqlite3_reset(stmt) }
            sqlite3_bind_text(stmt, 1, id.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Self.hydrateHeader(stmt: stmt)
        }
    }

    /// Bulk fetch of headers for a known id set. Returns a map so callers can
    /// render rows in their own preferred order. SQL `IN` lists are
    /// size-limited; we chunk at 256.
    public func itemHeaders(forIDs ids: [UUID]) throws -> [UUID: ItemHeader] {
        guard !ids.isEmpty else { return [:] }
        return try withReader { conn in
            var out: [UUID: ItemHeader] = [:]
            out.reserveCapacity(ids.count)
            var idx = 0
            let chunkSize = 256
            while idx < ids.count {
                let end = min(idx + chunkSize, ids.count)
                let placeholders = Array(repeating: "?", count: end - idx).joined(separator: ",")
                let sql = "SELECT \(Self.headerColumns) FROM items i WHERE i.id IN (\(placeholders));"
                let stmt = try conn.prepared(sql)
                for (offset, id) in ids[idx..<end].enumerated() {
                    sqlite3_bind_text(stmt, Int32(offset + 1), id.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let h = Self.hydrateHeader(stmt: stmt) { out[h.id] = h }
                }
                sqlite3_reset(stmt)
                idx = end
            }
            return out
        }
    }

    /// Stream every header in a snapshot through `body`. Used by the list view
    /// to filter without materialising the full header array. `body` runs
    /// while a pooled reader is leased — it MUST NOT call back into the
    /// database (keep filtering logic pure); other reads use other readers and
    /// proceed concurrently.
    public func forEachHeader(
        inSnapshot snapshotID: Int64,
        category: ItemCategory? = nil,
        body: (ItemHeader) -> Bool
    ) throws {
        try withReader { conn in
            let categoryFilter = category != nil ? "AND i.category = ?" : ""
            let sql = """
                SELECT \(Self.headerColumns)
                FROM items i
                JOIN snapshot_items si ON si.item_id = i.id
                WHERE si.snapshot_id = ? \(categoryFilter)
                ORDER BY i.name COLLATE NOCASE, i.path COLLATE NOCASE;
                """
            let stmt = try conn.prepared(sql)
            defer { sqlite3_reset(stmt) }
            sqlite3_bind_int64(stmt, 1, snapshotID)
            if let category {
                sqlite3_bind_text(stmt, 2, category.rawValue, -1, SQLITE_TRANSIENT)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let h = Self.hydrateHeader(stmt: stmt) else { continue }
                if !body(h) { break }
            }
        }
    }

    /// Count of items per category in a snapshot.
    public func categoryCounts(inSnapshot snapshotID: Int64) throws -> [ItemCategory: Int] {
        try withReader { conn in
            let sql = """
                SELECT i.category, COUNT(*)
                FROM items i
                JOIN snapshot_items si ON si.item_id = i.id
                WHERE si.snapshot_id = ?
                GROUP BY i.category;
                """
            let stmt = try conn.prepared(sql)
            defer { sqlite3_reset(stmt) }
            sqlite3_bind_int64(stmt, 1, snapshotID)
            var out: [ItemCategory: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let categoryC = sqlite3_column_text(stmt, 0) else { continue }
                let categoryStr = String(cString: categoryC)
                guard let category = ItemCategory(rawValue: categoryStr) else { continue }
                out[category] = Int(sqlite3_column_int64(stmt, 1))
            }
            return out
        }
    }

    /// Headers whose items live inside a given bundle.
    public func headers(inBundleAtPath bundlePath: String, inSnapshot snapshotID: Int64) throws -> [ItemHeader] {
        try withReader { conn in
            let sql = """
                SELECT \(Self.headerColumns)
                FROM items i
                JOIN snapshot_items si ON si.item_id = i.id
                WHERE si.snapshot_id = ? AND i.owning_bundle_path = ?
                ORDER BY i.path COLLATE NOCASE;
                """
            let stmt = try conn.prepared(sql)
            defer { sqlite3_reset(stmt) }
            sqlite3_bind_int64(stmt, 1, snapshotID)
            sqlite3_bind_text(stmt, 2, bundlePath, -1, SQLITE_TRANSIENT)
            var out: [ItemHeader] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let h = Self.hydrateHeader(stmt: stmt) { out.append(h) }
            }
            return out
        }
    }

    /// Headers that reference a given path via an outgoing relationship — the
    /// "Referenced By" panel. Bounded by `limit`, plus an unbounded count.
    public func headersReferencing(path: String, inSnapshot snapshotID: Int64, limit: Int) throws -> (total: Int, headers: [ItemHeader]) {
        try withReader { conn in
            let countSQL = """
                SELECT COUNT(DISTINCT r.source_id)
                FROM relationships r
                JOIN snapshot_items si ON si.item_id = r.source_id
                WHERE r.target_path = ? AND si.snapshot_id = ?;
                """
            var total = 0
            let cs = try conn.prepared(countSQL)
            sqlite3_bind_text(cs, 1, path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(cs, 2, snapshotID)
            if sqlite3_step(cs) == SQLITE_ROW { total = Int(sqlite3_column_int64(cs, 0)) }
            sqlite3_reset(cs)

            let sql = """
                SELECT \(Self.headerColumns)
                FROM items i
                JOIN relationships r ON r.source_id = i.id
                JOIN snapshot_items si ON si.item_id = i.id
                WHERE r.target_path = ? AND si.snapshot_id = ?
                GROUP BY i.id
                ORDER BY i.path COLLATE NOCASE
                LIMIT ?;
                """
            let stmt = try conn.prepared(sql)
            defer { sqlite3_reset(stmt) }
            sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, snapshotID)
            sqlite3_bind_int64(stmt, 3, Int64(limit))
            var out: [ItemHeader] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let h = Self.hydrateHeader(stmt: stmt) { out.append(h) }
            }
            return (total, out)
        }
    }

    /// Member item IDs for a snapshot, as an ordered array.
    public func orderedItemIDs(inSnapshot snapshotID: Int64) throws -> [UUID] {
        try withReader { conn in
            let stmt = try conn.prepared("SELECT item_id FROM snapshot_items WHERE snapshot_id = ? ORDER BY ROWID;")
            defer { sqlite3_reset(stmt) }
            sqlite3_bind_int64(stmt, 1, snapshotID)
            var out: [UUID] = []
            out.reserveCapacity(1024)
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let c = sqlite3_column_text(stmt, 0),
                      let u = UUID(uuidString: String(cString: c)) else { continue }
                out.append(u)
            }
            return out
        }
    }

    /// Number of items in a snapshot — without materializing any payload.
    public func itemCountInSnapshot(_ snapshotID: Int64) throws -> Int {
        try withReader { conn in
            let stmt = try conn.prepared("SELECT COUNT(*) FROM snapshot_items WHERE snapshot_id = ?;")
            defer { sqlite3_reset(stmt) }
            sqlite3_bind_int64(stmt, 1, snapshotID)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    public func itemsForSnapshot(_ snapshotID: Int64) throws -> [ScanItem] {
        try withReader { conn in
            let sql = """
                SELECT i.payload FROM items i
                JOIN snapshot_items si ON si.item_id = i.id
                WHERE si.snapshot_id = ?;
                """
            let stmt = try conn.prepared(sql)
            defer { sqlite3_reset(stmt) }
            sqlite3_bind_int64(stmt, 1, snapshotID)
            var out: [ScanItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
                let len = Int(sqlite3_column_bytes(stmt, 0))
                let data = Data(bytes: blob, count: len)
                if let item = try? conn.decoder.decode(ScanItem.self, from: data) { out.append(item) }
            }
            return out
        }
    }

    public func itemsInSnapshot(_ snapshotID: Int64) throws -> Set<UUID> {
        try withReader { conn in
            let stmt = try conn.prepared("SELECT item_id FROM snapshot_items WHERE snapshot_id = ?;")
            defer { sqlite3_reset(stmt) }
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
    }

    /// Snapshot membership joined with each item's per-row analysis state.
    public func analysisStatesInSnapshot(_ snapshotID: Int64) throws -> [(UUID, AnalysisState)] {
        try withReader { conn in
            let sql = """
                SELECT i.id, i.analysis_state FROM items i
                JOIN snapshot_items si ON si.item_id = i.id
                WHERE si.snapshot_id = ?;
                """
            let stmt = try conn.prepared(sql)
            defer { sqlite3_reset(stmt) }
            sqlite3_bind_int64(stmt, 1, snapshotID)
            var out: [(UUID, AnalysisState)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let idC = sqlite3_column_text(stmt, 0),
                      let id = UUID(uuidString: String(cString: idC)) else { continue }
                let stateStr: String = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "pending"
                let state = AnalysisState(rawValue: stateStr) ?? .pending
                out.append((id, state))
            }
            return out
        }
    }

    // MARK: - Meta

    public func setMeta(_ key: String, json: Data) throws {
        try withWriter { conn in
            try setMetaLocked(key: key, blob: json, on: conn)
        }
    }

    public func meta(_ key: String) throws -> Data? {
        try withReader { conn in
            let stmt = try conn.prepared(Self.getMetaSQL)
            defer { sqlite3_reset(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return nil }
            guard rc == SQLITE_ROW else { throw DBError.step("meta -> \(rc)") }
            guard let blob = sqlite3_column_blob(stmt, 0) else { return nil }
            let len = Int(sqlite3_column_bytes(stmt, 0))
            return Data(bytes: blob, count: len)
        }
    }

    public func setMeta<T: Encodable>(_ key: String, value: T) throws {
        try withWriter { conn in
            // Encode under the write lock so we never touch the writer's
            // JSONEncoder concurrently with another mutation's payload encode.
            let json = try conn.encoder.encode(value)
            try setMetaLocked(key: key, blob: json, on: conn)
        }
    }

    public func meta<T: Decodable>(_ key: String, as: T.Type) throws -> T? {
        try withReader { conn in
            let stmt = try conn.prepared(Self.getMetaSQL)
            defer { sqlite3_reset(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return nil }
            guard rc == SQLITE_ROW else { throw DBError.step("meta -> \(rc)") }
            guard let blob = sqlite3_column_blob(stmt, 0) else { return nil }
            let len = Int(sqlite3_column_bytes(stmt, 0))
            let data = Data(bytes: blob, count: len)
            return try conn.decoder.decode(T.self, from: data)
        }
    }

    public func checkpoint() throws {
        try withWriter { conn in
            let rc = sqlite3_wal_checkpoint_v2(conn.handle, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
            // SQLITE_BUSY just means a reader currently pins the WAL; the
            // checkpoint still flushed what it could, so it's not a save error.
            guard rc == SQLITE_OK || rc == SQLITE_BUSY else {
                throw DBError.step("wal_checkpoint -> \(rc): \(conn.lastErrorMessage)")
            }
        }
    }

    // MARK: - Locked write helpers (caller holds the writer)

    /// Run a no-result statement: prepare (cached), bind, step to completion,
    /// reset. Throws on any step error.
    private func write(_ conn: SQLiteConnection, _ sql: String, _ label: String, bind: (OpaquePointer) -> Void) throws {
        let stmt = try conn.prepared(sql)
        bind(stmt)
        let rc = sqlite3_step(stmt)
        defer { sqlite3_reset(stmt) }
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError.step("\(label) -> \(rc): \(conn.lastErrorMessage)")
        }
    }

    private func upsertItemLocked(_ item: ScanItem, on conn: SQLiteConnection) throws {
        let idKey = item.id.uuidString.lowercased()
        let payload = try conn.encoder.encode(item)

        try write(conn, Self.upsertItemSQL, "upsertItem") { stmt in
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
            sqlite3_bind_text(stmt, 29, item.analysisState.rawValue, -1, SQLITE_TRANSIENT)
            if let a = item.analyzedAt {
                sqlite3_bind_double(stmt, 30, a.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 30)
            }
            bindOptText(stmt, 31, item.analyzerVersion)
            _ = payload.withUnsafeBytes { raw -> Int32 in
                if let base = raw.baseAddress {
                    return sqlite3_bind_blob(stmt, 32, base, Int32(payload.count), SQLITE_TRANSIENT)
                } else {
                    return sqlite3_bind_zeroblob(stmt, 32, 0)
                }
            }
        }

        // Per-item child rows: rebuild rather than diff.
        try write(conn, Self.deleteTagsSQL, "delTags") { sqlite3_bind_text($0, 1, idKey, -1, SQLITE_TRANSIENT) }
        for tag in item.tags {
            try write(conn, Self.insertTagSQL, "insertTag") { stmt in
                sqlite3_bind_text(stmt, 1, idKey, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, tag, -1, SQLITE_TRANSIENT)
            }
        }
        try write(conn, Self.deleteArchsSQL, "delArchs") { sqlite3_bind_text($0, 1, idKey, -1, SQLITE_TRANSIENT) }
        for arch in item.executable?.architectures ?? [] {
            try write(conn, Self.insertArchSQL, "insertArch") { stmt in
                sqlite3_bind_text(stmt, 1, idKey, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, arch, -1, SQLITE_TRANSIENT)
            }
        }
        try write(conn, Self.deleteRelsSQL, "delRels") { sqlite3_bind_text($0, 1, idKey, -1, SQLITE_TRANSIENT) }
        for rel in item.relationships {
            try write(conn, Self.insertRelSQL, "insertRel") { stmt in
                sqlite3_bind_text(stmt, 1, idKey, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, rel.kind.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, rel.targetPath, -1, SQLITE_TRANSIENT)
                sqlite3_bind_null(stmt, 4)
                if let note = rel.note {
                    sqlite3_bind_text(stmt, 5, note, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
            }
        }
    }

    private func stampAnalysisLocked(
        itemID: UUID,
        state: AnalysisState,
        analyzedAt: Date?,
        analyzerVersion: String?,
        on conn: SQLiteConnection
    ) throws {
        try write(conn, Self.updateItemAnalysisSQL, "updateItemAnalysis") { stmt in
            sqlite3_bind_text(stmt, 1, state.rawValue, -1, SQLITE_TRANSIENT)
            if let analyzedAt {
                sqlite3_bind_double(stmt, 2, analyzedAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            if let analyzerVersion {
                sqlite3_bind_text(stmt, 3, analyzerVersion, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_text(stmt, 4, itemID.uuidString.lowercased(), -1, SQLITE_TRANSIENT)
        }
    }

    private func clearAnalysisOutputLocked(key: String, on conn: SQLiteConnection) throws {
        try write(conn, Self.deleteTagsSQL, "delTags") { sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT) }
        try write(conn, Self.deleteArchsSQL, "delArchs") { sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT) }
        try write(conn, Self.deleteRelsSQL, "delRels") { sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT) }
        try write(conn, Self.deleteSymbolsSQL, "delSymbols") { sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT) }
        try write(conn, Self.deleteStringsFTSSQL, "delStrFTS") { sqlite3_bind_text($0, 1, key, -1, SQLITE_TRANSIENT) }
    }

    private func setMetaLocked(key: String, blob: Data, on conn: SQLiteConnection) throws {
        try write(conn, Self.setMetaSQL, "setMeta") { stmt in
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

    private func decodePayload(_ conn: SQLiteConnection, stmt: OpaquePointer, column: Int32) throws -> ScanItem? {
        guard let blob = sqlite3_column_blob(stmt, column) else { return nil }
        let len = Int(sqlite3_column_bytes(stmt, column))
        let data = Data(bytes: blob, count: len)
        return try conn.decoder.decode(ScanItem.self, from: data)
    }

    // MARK: - Setup

    private func writeOrCheckSchemaVersion() throws {
        if let raw = try? meta("schema_version"),
           let str = String(data: raw, encoding: .utf8),
           let v = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if v < Self.currentSchemaVersion { throw DBError.schemaTooOld(v) }
            if v > Self.currentSchemaVersion { throw DBError.schemaTooNew(v) }
        } else {
            try setMeta("schema_version", json: Data("\(Self.currentSchemaVersion)".utf8))
        }
    }

    private static func configureWriter(_ conn: SQLiteConnection) throws {
        try conn.exec("PRAGMA journal_mode=WAL;")
        try conn.exec("PRAGMA synchronous=NORMAL;")
        try conn.exec("PRAGMA foreign_keys=OFF;")
        try conn.exec("PRAGMA temp_store=MEMORY;")
        try conn.exec("PRAGMA cache_size=-32000;")
        try conn.exec("PRAGMA mmap_size=268435456;")
        try conn.exec("PRAGMA busy_timeout=5000;")
    }

    private static func configureReader(_ conn: SQLiteConnection) throws {
        // journal_mode is a per-database property already set to WAL by the
        // writer; readers only need their own per-connection knobs. Smaller
        // page cache than the writer keeps total memory bounded across the
        // pool; mmap still serves hot pages without a read() per page.
        try conn.exec("PRAGMA temp_store=MEMORY;")
        try conn.exec("PRAGMA cache_size=-16000;")
        try conn.exec("PRAGMA mmap_size=268435456;")
        try conn.exec("PRAGMA busy_timeout=5000;")
    }

    // MARK: - Cached SQL (compiled per connection on first use)

    private static let upsertItemSQL = """
        INSERT INTO items (
            id, path, name, category, size, modified_at, sha256,
            inside_bundle, owning_bundle_path, context,
            macho_kind, macho_platform, macho_min_os, macho_sdk,
            macho_is_fat, macho_is_apple, macho_is_xplat, macho_usage,
            bundle_identifier, bundle_short_version, bundle_version,
            bundle_display_name, bundle_exec_name, is_private_bundle,
            language, icon_blob_ref, strings_blob_ref, file_blob_ref,
            analysis_state, analyzed_at, analyzer_version, payload
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            analysis_state=excluded.analysis_state,
            analyzed_at=excluded.analyzed_at,
            analyzer_version=excluded.analyzer_version,
            payload=excluded.payload
        """
    private static let updateItemAnalysisSQL = "UPDATE items SET analysis_state = ?, analyzed_at = ?, analyzer_version = ? WHERE id = ?;"
    private static let deleteItemSQL = "DELETE FROM items WHERE id = ?"
    private static let itemByIDSQL = "SELECT payload FROM items WHERE id = ?"
    private static let deleteTagsSQL = "DELETE FROM tags WHERE item_id = ?"
    private static let insertTagSQL = "INSERT OR IGNORE INTO tags (item_id, tag) VALUES (?, ?)"
    private static let deleteArchsSQL = "DELETE FROM architectures WHERE item_id = ?"
    private static let insertArchSQL = "INSERT OR IGNORE INTO architectures (item_id, arch) VALUES (?, ?)"
    private static let deleteRelsSQL = "DELETE FROM relationships WHERE source_id = ?"
    private static let insertRelSQL = "INSERT OR REPLACE INTO relationships (source_id, kind, target_path, target_id, note) VALUES (?, ?, ?, ?, ?)"
    private static let outgoingTargetsSQL = "SELECT target_path FROM relationships WHERE source_id = ?"
    private static let insertSymbolSQL = "INSERT INTO symbols (item_id, name, demangled, kind, library_ordinal) VALUES (?, ?, ?, ?, ?)"
    private static let deleteSymbolsSQL = "DELETE FROM symbols WHERE item_id = ?"
    private static let insertBlobSQL = "INSERT OR REPLACE INTO blobs (ref, sha256, size, kind) VALUES (?, ?, ?, ?)"
    private static let insertSnapshotSQL = """
        INSERT INTO snapshots (
            parent_id, label, source_kind, source_ref, started_at,
            import_completed_at, import_state, analysis_state,
            analyzed_at, analyzer_version, system_info, options
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
    private static let insertSnapshotItemSQL = "INSERT OR IGNORE INTO snapshot_items (snapshot_id, item_id) VALUES (?, ?)"
    private static let insertStringsFTSSQL = "INSERT INTO strings_fts(item_id, item_path, content) VALUES (?, ?, ?)"
    private static let deleteStringsFTSSQL = "DELETE FROM strings_fts WHERE item_id = ?"
    private static let setMetaSQL = "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value"
    private static let getMetaSQL = "SELECT value FROM meta WHERE key = ?"

    private static let ddlCore = """
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value BLOB NOT NULL
        );

        CREATE TABLE IF NOT EXISTS snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            parent_id INTEGER,
            label TEXT,
            source_kind TEXT NOT NULL DEFAULT 'currentSystem',
            source_ref TEXT,
            started_at REAL NOT NULL,
            import_completed_at REAL,
            import_state TEXT NOT NULL DEFAULT 'running',
            analysis_state TEXT NOT NULL DEFAULT 'none',
            analyzed_at REAL,
            analyzer_version TEXT,
            system_info BLOB,
            options BLOB,
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
            analysis_state TEXT NOT NULL DEFAULT 'pending',
            analyzed_at REAL,
            analyzer_version TEXT,
            payload BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS items_path_idx           ON items(path);
        CREATE INDEX IF NOT EXISTS items_category_idx       ON items(category);
        CREATE INDEX IF NOT EXISTS items_owning_bundle_idx  ON items(owning_bundle_path);
        CREATE INDEX IF NOT EXISTS items_sha256_idx         ON items(sha256);
        CREATE INDEX IF NOT EXISTS items_bundle_id_idx      ON items(bundle_identifier);
        CREATE INDEX IF NOT EXISTS items_language_idx       ON items(language);
        CREATE INDEX IF NOT EXISTS items_analysis_idx       ON items(analysis_state);
        CREATE INDEX IF NOT EXISTS items_name_nocase_idx     ON items(name COLLATE NOCASE);

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
        """

    private static let ddlFTS = """
        CREATE VIRTUAL TABLE IF NOT EXISTS symbols_fts USING fts5(
            name, demangled, content='symbols', content_rowid='id', tokenize='unicode61'
        );
        CREATE TRIGGER IF NOT EXISTS symbols_ai AFTER INSERT ON symbols BEGIN
            INSERT INTO symbols_fts(rowid, name, demangled) VALUES (new.id, new.name, new.demangled);
        END;
        CREATE TRIGGER IF NOT EXISTS symbols_ad AFTER DELETE ON symbols BEGIN
            INSERT INTO symbols_fts(symbols_fts, rowid, name, demangled) VALUES ('delete', old.id, old.name, old.demangled);
        END;
        CREATE VIRTUAL TABLE IF NOT EXISTS strings_fts USING fts5(
            item_id UNINDEXED, item_path UNINDEXED, content, tokenize='unicode61'
        );
        """
}

// MARK: - Helper bindings

nonisolated private func bindOptText(_ stmt: OpaquePointer, _ idx: Int32, _ s: String?) {
    if let s {
        sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
    } else {
        sqlite3_bind_null(stmt, idx)
    }
}

nonisolated private func bindOptBlob(_ stmt: OpaquePointer, _ idx: Int32, _ b: Data?) {
    guard let b else { sqlite3_bind_null(stmt, idx); return }
    _ = b.withUnsafeBytes { raw -> Int32 in
        if let base = raw.baseAddress {
            return sqlite3_bind_blob(stmt, idx, base, Int32(b.count), SQLITE_TRANSIENT)
        }
        return sqlite3_bind_zeroblob(stmt, idx, 0)
    }
}

// MARK: - Public row types

public nonisolated struct SymbolRow: Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case function
        case data
        case objcClass
        case objcMetaClass
        case objcProtocol
        case swiftClass
        case swiftStruct
        case undefined
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

public nonisolated struct SymbolHit: Sendable, Hashable {
    public var itemID: UUID
    public var name: String
    public var demangled: String?
    public var kind: SymbolRow.Kind
}

public nonisolated struct StringsHit: Sendable, Hashable {
    public var itemID: UUID
    public var itemPath: String
    public var snippet: String
}

/// Where a snapshot's content came from. Stored on the `snapshots` row so the
/// UI can show "macOS 26.5.1 (this Mac)" vs "iPhone15,2_26.5.1_…ipsw".
public nonisolated enum SnapshotSourceKind: String, Codable, Sendable, Hashable, CaseIterable {
    case currentSystem
    case ipsw

    public var displayName: String {
        switch self {
        case .currentSystem: return "Current System"
        case .ipsw:          return "IPSW"
        }
    }

    public var systemImageName: String {
        switch self {
        case .currentSystem: return "desktopcomputer"
        case .ipsw:          return "shippingbox"
        }
    }
}

/// State of the import phase for a snapshot.
public nonisolated enum ImportState: String, Codable, Sendable, Hashable, CaseIterable {
    case running
    case done
    case failed
}

/// Per-item and per-snapshot analysis bookkeeping.
public nonisolated enum AnalysisState: String, Codable, Sendable, Hashable, CaseIterable {
    case none      // snapshot only: analysis never started
    case pending   // item only: import done, analysis not yet run
    case partial   // snapshot only: some items analyzed, others pending/failed
    case running   // snapshot only: analyzer currently working through this snapshot
    case done      // all members analyzed at current analyzer version
    case failed    // analysis attempted but errored
}

public nonisolated struct SnapshotRecord: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var parentID: Int64?
    public var label: String?
    public var sourceKind: SnapshotSourceKind
    public var sourceRef: String?
    public var startedAt: Date
    public var importCompletedAt: Date?
    public var importState: ImportState
    public var analysisState: AnalysisState
    public var analyzedAt: Date?
    public var analyzerVersion: String?
    public var systemInfo: SystemInfo?

    public init(
        id: Int64,
        parentID: Int64?,
        label: String?,
        sourceKind: SnapshotSourceKind,
        sourceRef: String?,
        startedAt: Date,
        importCompletedAt: Date?,
        importState: ImportState,
        analysisState: AnalysisState,
        analyzedAt: Date?,
        analyzerVersion: String?,
        systemInfo: SystemInfo?
    ) {
        self.id = id
        self.parentID = parentID
        self.label = label
        self.sourceKind = sourceKind
        self.sourceRef = sourceRef
        self.startedAt = startedAt
        self.importCompletedAt = importCompletedAt
        self.importState = importState
        self.analysisState = analysisState
        self.analyzedAt = analyzedAt
        self.analyzerVersion = analyzerVersion
        self.systemInfo = systemInfo
    }
}

nonisolated let SQLITE_TRANSIENT = unsafeBitCast(
    OpaquePointer(bitPattern: -1),
    to: sqlite3_destructor_type.self
)
