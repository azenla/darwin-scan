import Foundation
import SQLite3

/// One SQLite connection plus a per-connection prepared-statement cache and
/// its own JSON coders.
///
/// **Threading.** A single `sqlite3*` — and especially a *reused* prepared
/// statement — must be driven by one thread at a time. This type is therefore
/// NOT internally synchronized; `Database` guarantees single-threaded use of
/// each connection (the writer is serialized by a lock, and each pooled reader
/// is leased to exactly one caller at a time). The per-connection JSON coders
/// are safe for the same reason — they're only ever touched by the one thread
/// currently holding the connection, so concurrent readers never share a coder.
final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer
    let readOnly: Bool
    private var cache: [String: OpaquePointer] = [:]

    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    enum ConnError: Error, CustomStringConvertible {
        case open(String)
        case prepare(String)
        var description: String {
            switch self {
            case .open(let m): return "SQLiteConnection.open: \(m)"
            case .prepare(let m): return "SQLiteConnection.prepare: \(m)"
            }
        }
    }

    init(path: String, readOnly: Bool) throws {
        self.readOnly = readOnly
        var h: OpaquePointer?
        let flags = (readOnly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let h { sqlite3_close_v2(h) }
            throw ConnError.open("sqlite3_open_v2(\(path), readOnly: \(readOnly)) -> \(rc): \(msg)")
        }
        self.handle = h
    }

    /// A prepared statement for `sql`, reset and with bindings cleared so it's
    /// ready to bind. Compiled once and cached on this connection — both the
    /// writer's hot inserts and the UI's hot reads avoid recompilation.
    func prepared(_ sql: String) throws -> OpaquePointer {
        if let stmt = cache[sql] {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            return stmt
        }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw ConnError.prepare("sqlite3_prepare_v2 -> \(rc): \(lastErrorMessage) [\(sql)]")
        }
        cache[sql] = stmt
        return stmt
    }

    /// Run a statement (or several `;`-separated statements) with no result
    /// rows — DDL, pragmas, transaction control.
    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        defer { if let err { sqlite3_free(err) } }
        guard rc == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            throw ConnError.prepare("sqlite3_exec -> \(rc): \(msg) [\(sql)]")
        }
    }

    var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    private var didClose = false

    /// Finalize every cached statement and close the handle. Idempotent, so
    /// an explicit `Database.close()` followed by `deinit` is safe.
    func close() {
        guard !didClose else { return }
        didClose = true
        for (_, stmt) in cache { sqlite3_finalize(stmt) }
        cache.removeAll()
        sqlite3_close_v2(handle)
    }

    deinit { close() }
}
