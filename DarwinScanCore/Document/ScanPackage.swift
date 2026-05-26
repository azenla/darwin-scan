import Foundation

/// On-disk layout for a `.darwinscan` directory bundle.
///
/// ```
/// MyScan.darwinscan/
///   data.db              — SQLite database, schema v3 (see Database.swift)
///   format.txt           — single-line version stamp: "darwinscan v5"
///   blobs/
///     <2-char-prefix>/
///       <ref>.bin        — content-addressed payload
/// ```
///
/// The store now writes directly into the open bundle's directory — no
/// session cache dir copy on save. `createEmpty(at:)` initialises a fresh
/// bundle; `openInPlace(at:into:)` attaches an existing one.
///
/// **Format compatibility.** v2 (JSON manifest), v3 (SQLite schema v1), and
/// v4 (SQLite schema v2) are no longer recognised — opening one fails with
/// a clear error rather than attempting a silent migration. This was a
/// deliberate break: the schema promotes a couple dozen fields to dedicated
/// columns and introduces symbol / FTS / blob / snapshot tables, none of
/// which can be retrofitted onto an old bundle without re-scanning anyway.
public enum ScanPackage {
    public nonisolated static let databaseFilename = "data.db"
    public nonisolated static let blobsDirectory   = "blobs"
    public nonisolated static let formatStampFilename = "format.txt"
    public nonisolated static let packageVersion   = 5
    public nonisolated static let formatStampLine  = "darwinscan v5"

    public enum LoadError: Error, CustomStringConvertible {
        case notADirectory
        case unsupportedFormat(detected: String)
        case missingDatabase

        public var description: String {
            switch self {
            case .notADirectory:                return "ScanPackage.load: file is not a .darwinscan directory bundle"
            case .unsupportedFormat(let s):     return "ScanPackage.load: bundle is in an unsupported format (\(s)). DarwinScan now requires bundles in format v5; re-scan to produce a new bundle."
            case .missingDatabase:              return "ScanPackage.load: bundle has no data.db"
            }
        }
    }

    // MARK: - Bundle URLs

    /// Sub-paths within a `.darwinscan` directory bundle.
    public nonisolated static func databaseURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(databaseFilename, isDirectory: false)
    }

    public nonisolated static func blobsURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(blobsDirectory, isDirectory: true)
    }

    public nonisolated static func formatStampURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(formatStampFilename, isDirectory: false)
    }

    // MARK: - Create

    /// Initialise a brand-new `.darwinscan` bundle at the given URL. Writes
    /// the format stamp, the empty `blobs/` directory, and an empty
    /// (schema-current) `data.db`. Throws if the destination already exists
    /// or can't be created.
    ///
    /// Returns a populated `ScanStore` ready for ingest, with `database`
    /// already attached and `blobStore` rooted at the new bundle's `blobs/`.
    @discardableResult
    public static func createEmpty(at bundleURL: URL) throws -> ScanStore {
        let fm = FileManager.default
        if fm.fileExists(atPath: bundleURL.path) {
            throw NSError(
                domain: "ScanPackage",
                code: 1,
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

    // MARK: - Open

    /// Attach an existing `.darwinscan` bundle to `store` in place — opens
    /// `data.db` directly from `bundleURL/data.db` and registers all
    /// existing blob refs from `bundleURL/blobs/<prefix>/`. No bytes are
    /// copied.
    ///
    /// Throws `LoadError.notADirectory` / `missingDatabase` /
    /// `unsupportedFormat` for malformed bundles.
    public static func openInPlace(at bundleURL: URL, into store: ScanStore) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: bundleURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw LoadError.notADirectory
        }

        // Reject legacy layouts. A v2 bundle would have items.json /
        // metadata.json at the top level; v3/v4 are SQLite schema-version
        // gated and surface via `Database` errors below.
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
            case .schemaTooOld(let v):
                throw LoadError.unsupportedFormat(detected: "older (sqlite schema v\(v))")
            case .schemaTooNew(let v):
                throw LoadError.unsupportedFormat(detected: "newer (sqlite schema v\(v))")
            default:
                throw err
            }
        }
        store.databaseURL = dbURL
        // Ensure the blobs/ dir exists even on an old bundle that may have
        // shipped without any blobs (no shards yet).
        try? fm.createDirectory(at: blobsURL(in: bundleURL), withIntermediateDirectories: true)
        store.attachBundle(blobsDirectory: blobsURL(in: bundleURL))
        store.blobStore.scanForExistingBlobs()
        store.attachDatabase(db)
        try populateInMemoryView(store: store)

        // Refresh the format stamp on open — harmless if it's already correct,
        // and useful for bundles that lost the stamp through `cp -r` or a
        // partial restore.
        try? Data((formatStampLine + "\n").utf8).write(to: formatStampURL(in: bundleURL), options: .atomic)
    }

    // MARK: - Helpers

    /// Populate the store's in-memory `ItemHeader` map and derived indexes
    /// from the latest snapshot in the attached database. Called by
    /// `openInPlace` after the database is hooked up.
    private static func populateInMemoryView(store: ScanStore) throws {
        guard let db = store.database else { return }
        // Show the latest snapshot only. Earlier snapshots stay in the
        // database for diff / history but aren't surfaced in the default
        // in-memory view. A future snapshot-switcher UI will be able to
        // call `Database.itemsForSnapshot(id)` for any historical id.
        let items: [ScanItem]
        let latestSnapshot: SnapshotRecord?
        if let latestID = try db.latestSnapshotID() {
            items = try db.itemsForSnapshot(latestID)
            latestSnapshot = (try db.allSnapshots()).first(where: { $0.id == latestID })
        } else {
            items = []
            latestSnapshot = nil
        }
        let options: ScanOptions? = (try? db.meta("options", as: ScanOptions.self)) ?? nil

        store.load(
            items: items,
            systemInfo: latestSnapshot?.systemInfo,
            options: options,
            lastScanStarted: latestSnapshot?.startedAt,
            lastScanCompleted: latestSnapshot?.completedAt,
            mirrorToDatabase: false
        )
    }
}
