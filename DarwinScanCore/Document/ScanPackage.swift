import Foundation

/// On-disk layout for a `.darwinscan` directory bundle. **Format v6.**
///
/// ```
/// MyScan.darwinscan/
///   data.db              — SQLite database, schema v6
///   format.txt           — version stamp: "darwinscan v6"
///   blobs/
///     <2-char-prefix>/
///       <ref>.bin        — content-addressed payload
/// ```
///
/// v6 introduced the two-phase model (import + analysis) — older bundles are
/// no longer recognised; opening one returns `LoadError.unsupportedFormat`.
public enum ScanPackage {
    public nonisolated static let databaseFilename = "data.db"
    public nonisolated static let blobsDirectory   = "blobs"
    public nonisolated static let formatStampFilename = "format.txt"
    public nonisolated static let packageVersion   = 6
    public nonisolated static let formatStampLine  = "darwinscan v6"

    public enum LoadError: Error, CustomStringConvertible {
        case notADirectory
        case unsupportedFormat(detected: String)
        case missingDatabase

        public var description: String {
            switch self {
            case .notADirectory:                return "ScanPackage.load: file is not a .darwinscan directory bundle"
            case .unsupportedFormat(let s):     return "ScanPackage.load: bundle is in an unsupported format (\(s)). DarwinScan now requires bundles in format v6; re-import to produce a new bundle."
            case .missingDatabase:              return "ScanPackage.load: bundle has no data.db"
            }
        }
    }

    public nonisolated static func databaseURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(databaseFilename, isDirectory: false)
    }
    public nonisolated static func blobsURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(blobsDirectory, isDirectory: true)
    }
    public nonisolated static func formatStampURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(formatStampFilename, isDirectory: false)
    }

    /// Initialise a brand-new `.darwinscan` bundle at the given URL.
    @discardableResult
    public static func createEmpty(at bundleURL: URL) throws -> ScanStore {
        let fm = FileManager.default
        if fm.fileExists(atPath: bundleURL.path) {
            throw NSError(
                domain: "ScanPackage", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot create bundle: a file already exists at \(bundleURL.path)"]
            )
        }
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: blobsURL(in: bundleURL), withIntermediateDirectories: true)
        try Data((formatStampLine + "\n").utf8).write(to: formatStampURL(in: bundleURL), options: .atomic)
        let store = ScanStore()
        let dbURL = databaseURL(in: bundleURL)
        let db = try Database(at: dbURL)
        store.databaseURL = dbURL
        store.attachBundle(blobsDirectory: blobsURL(in: bundleURL))
        store.attachDatabase(db)
        return store
    }

    /// Attach an existing `.darwinscan` bundle to `store` in place. Cheap —
    /// opens the SQLite handle and seeds the blob store, but does NOT load
    /// items. Call `populateActiveSnapshot(store:)` (typically off-main) to
    /// populate the working set.
    public static func openInPlace(at bundleURL: URL, into store: ScanStore) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: bundleURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw LoadError.notADirectory
        }
        if fm.fileExists(atPath: bundleURL.appendingPathComponent("items.json").path) ||
           fm.fileExists(atPath: bundleURL.appendingPathComponent("metadata.json").path) {
            throw LoadError.unsupportedFormat(detected: "v2 (legacy JSON)")
        }
        let dbURL = databaseURL(in: bundleURL)
        guard fm.fileExists(atPath: dbURL.path) else {
            throw LoadError.missingDatabase
        }
        let db: Database
        do {
            db = try Database(at: dbURL)
        } catch let err as Database.DBError {
            switch err {
            case .schemaTooOld(let v): throw LoadError.unsupportedFormat(detected: "older (sqlite schema v\(v))")
            case .schemaTooNew(let v): throw LoadError.unsupportedFormat(detected: "newer (sqlite schema v\(v))")
            default: throw err
            }
        }
        store.databaseURL = dbURL
        try? fm.createDirectory(at: blobsURL(in: bundleURL), withIntermediateDirectories: true)
        store.attachBundle(blobsDirectory: blobsURL(in: bundleURL))
        // `scanForExistingBlobs` walks every file under blobs/ to populate
        // the in-memory `refs` set — for a /System-scale bundle that's 470k
        // stat() calls. We only need the set when registering new blobs;
        // reads use `blobURL(forRef:)` directly. Skip on open for speed.
        store.attachDatabase(db)
        try? Data((formatStampLine + "\n").utf8).write(to: formatStampURL(in: bundleURL), options: .atomic)
    }

    /// Populate the in-memory view from the latest snapshot. Heavy for big
    /// bundles (~ms per thousand headers) — `nonisolated` because callers
    /// (`ScanSession.populateInitialView`) drive it through `Task.detached`
    /// to keep MainActor responsive. Safe to call multiple times; idempotent.
    public nonisolated static func populateActiveSnapshot(store: ScanStore) throws {
        try populateInMemoryView(store: store)
    }

    private nonisolated static func populateInMemoryView(store: ScanStore) throws {
        guard let db = store.database else { return }
        // SQL-first: we don't load any item headers up front. Only the
        // active snapshot id, system info, options, and per-category
        // counts come into memory here — item rows are streamed from
        // SQLite on demand (list views) or fetched per-id (detail views).
        let latestID = try db.latestSnapshotID()
        let options: ScanOptions? = (try? db.meta("options", as: ScanOptions.self)) ?? nil
        if let options { store.options = options }
        store.setActiveSnapshot(latestID)
    }
}
