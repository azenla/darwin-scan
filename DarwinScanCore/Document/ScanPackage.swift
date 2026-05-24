import Foundation

/// On-disk layout for a `.darwinscan` directory bundle (v4 — denormalized
/// SQLite manifest).
///
/// ```
/// MyScan.darwinscan/
///   data.db              — SQLite database, schema v2 (see Database.swift)
///   format.txt           — single-line version stamp: "darwinscan v4"
///   blobs/
///     <2-char-prefix>/
///       <ref>.bin        — content-addressed payload
/// ```
///
/// **Incompatible with prior bundles.** v2 (JSON manifest) and v3 (SQLite
/// schema v1) are no longer recognised — opening one fails with a clear error
/// rather than attempting a silent migration. This was a deliberate break:
/// the new schema promotes a couple dozen fields to dedicated columns and
/// introduces symbol / FTS / blob / snapshot tables, none of which can be
/// retrofitted onto an old bundle without re-scanning anyway.
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

    // MARK: - Snapshot

    /// Sendable, MainActor-free representation of the document state that the
    /// SwiftUI save path needs.
    public nonisolated struct Snapshot: Sendable {
        public let databaseBytes: Data?
        public let blobCacheDirectory: URL

        public init(databaseBytes: Data?, blobCacheDirectory: URL) {
            self.databaseBytes = databaseBytes
            self.blobCacheDirectory = blobCacheDirectory
        }
    }

    // MARK: - Save

    public nonisolated static func makeFileWrapper(snapshot: Snapshot) throws -> FileWrapper {
        var contents: [String: FileWrapper] = [:]

        if let dbBytes = snapshot.databaseBytes {
            let dbWrapper = FileWrapper(regularFileWithContents: dbBytes)
            dbWrapper.preferredFilename = databaseFilename
            contents[databaseFilename] = dbWrapper
        }

        let stampData = Data((formatStampLine + "\n").utf8)
        let stampWrapper = FileWrapper(regularFileWithContents: stampData)
        stampWrapper.preferredFilename = formatStampFilename
        contents[formatStampFilename] = stampWrapper

        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: snapshot.blobCacheDirectory, includingPropertiesForKeys: nil)) ?? []
        var bucketed: [String: [String: FileWrapper]] = [:]
        for url in entries {
            let filename = url.lastPathComponent
            guard filename.hasSuffix(".bin") else { continue }
            let ref = String(filename.dropLast(4))
            let prefix = String(blobHashPart(ref).prefix(2))
            guard let wrapper = try? FileWrapper(url: url, options: [.immediate]) else { continue }
            wrapper.preferredFilename = filename
            bucketed[prefix, default: [:]][filename] = wrapper
        }
        if !bucketed.isEmpty {
            var subdirs: [String: FileWrapper] = [:]
            for (prefix, files) in bucketed {
                subdirs[prefix] = FileWrapper(directoryWithFileWrappers: files)
            }
            contents[blobsDirectory] = FileWrapper(directoryWithFileWrappers: subdirs)
        }

        return FileWrapper(directoryWithFileWrappers: contents)
    }

    public static func makeFileWrapper(from store: ScanStore) throws -> FileWrapper {
        var contents: [String: FileWrapper] = [:]

        if let db = store.database, let dbURL = store.databaseURL {
            try db.checkpoint()
            let dbWrapper = try FileWrapper(url: dbURL, options: [.immediate])
            dbWrapper.preferredFilename = databaseFilename
            contents[databaseFilename] = dbWrapper
        }

        let stampData = Data((formatStampLine + "\n").utf8)
        let stampWrapper = FileWrapper(regularFileWithContents: stampData)
        stampWrapper.preferredFilename = formatStampFilename
        contents[formatStampFilename] = stampWrapper

        let bucketed = store.blobStore.makeFileWrappersForSave()
        if !bucketed.isEmpty {
            var subdirs: [String: FileWrapper] = [:]
            for (prefix, files) in bucketed {
                subdirs[prefix] = FileWrapper(directoryWithFileWrappers: files)
            }
            contents[blobsDirectory] = FileWrapper(directoryWithFileWrappers: subdirs)
        }

        return FileWrapper(directoryWithFileWrappers: contents)
    }

    // MARK: - Load

    public static func load(into store: ScanStore, from wrapper: FileWrapper) throws {
        guard wrapper.isDirectory, let children = wrapper.fileWrappers else {
            throw LoadError.notADirectory
        }

        // Reject anything that isn't v4. Legacy v2 (items.json + metadata.json)
        // and v3 (sqlite schema v1) both fail — re-scan is the documented path.
        if children["items.json"] != nil || children["metadata.json"] != nil {
            throw LoadError.unsupportedFormat(detected: "v2 (legacy JSON)")
        }

        let cacheDir = store.blobStore.cacheDirectory
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let dbURL = cacheDir.appendingPathComponent(databaseFilename)
        try? FileManager.default.removeItem(at: dbURL)

        guard let dbWrapper = children[databaseFilename] else {
            throw LoadError.missingDatabase
        }

        // Stream the DB file out of the wrapper rather than going through
        // `regularFileContents` — for /System scans `data.db` can be in the
        // hundreds of MB and materialising it as Data would double peak RAM
        // on open.
        try dbWrapper.write(to: dbURL, options: [], originalContentsURL: nil)

        // Opening will throw `DBError.schemaTooOld` / `schemaTooNew` if the
        // bundle's data.db isn't schema v2 — surface that as `unsupportedFormat`.
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
        store.attachDatabase(db)
        try loadFromAttachedDatabase(store: store)

        if let blobsRoot = children[blobsDirectory], let prefixes = blobsRoot.fileWrappers {
            for (_, prefixWrapper) in prefixes {
                guard prefixWrapper.isDirectory, let files = prefixWrapper.fileWrappers else { continue }
                for (filename, file) in files {
                    guard filename.hasSuffix(".bin") else { continue }
                    let ref = String(filename.dropLast(4))
                    let dstURL = cacheDir.appendingPathComponent(filename)
                    try? file.write(to: dstURL, options: [], originalContentsURL: nil)
                    store.blobStore.register(ref: ref)
                }
            }
        }
    }

    // MARK: - Helpers

    private nonisolated static func blobHashPart(_ ref: String) -> String {
        if let dash = ref.firstIndex(of: "-") {
            return String(ref[ref.index(after: dash)...])
        }
        return ref
    }

    private static func loadFromAttachedDatabase(store: ScanStore) throws {
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
