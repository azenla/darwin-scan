import Foundation

/// On-disk layout for a `.darwinscan` directory bundle (v3 — SQLite manifest):
///
/// ```
/// MyScan.darwinscan/
///   data.db              — SQLite database, schema v1 (items + meta + relationships)
///   blobs/
///     <2-char-prefix>/
///       <ref>.bin        — content-addressed payload
/// ```
///
/// The blob layout still mirrors git's loose-object scheme — keeps directory
/// sizes reasonable when there are tens of thousands of small icons / strings
/// dumps.
///
/// ### Legacy bundles
///
/// v2 bundles (the JSON `items.json` + `metadata.json` form) are read on open:
/// we parse the JSON, seed a fresh `data.db` inside the BlobStore cache, and
/// surface the store as if it had been opened from a v3 bundle. The next save
/// writes a v3 bundle — there's no roundtrip back to v2.
enum ScanPackage {
    // v3 names
    static let databaseFilename = "data.db"
    static let blobsDirectory   = "blobs"
    static let packageVersion   = 3

    // v2 legacy names — read only.
    static let legacyMetadataFilename = "metadata.json"
    static let legacyItemsFilename    = "items.json"

    struct LegacyMetadata: Codable {
        var version: Int
        var systemInfo: SystemInfo?
        var options: ScanOptions
        var lastScanStarted: Date?
        var lastScanCompleted: Date?
    }

    struct LegacyPayload: Codable {
        var items: [ScanItem]
    }

    // MARK: - Save

    /// Builds a `FileWrapper` directory representation of the current store.
    /// Caller is responsible for calling `database.checkpoint()` first so the
    /// WAL is folded into the main DB file before we read it back through
    /// `FileWrapper`.
    static func makeFileWrapper(from store: ScanStore) throws -> FileWrapper {
        var contents: [String: FileWrapper] = [:]

        if let db = store.database, let dbURL = store.databaseURL {
            // Make sure WAL contents are committed into the main file. We
            // checkpoint defensively even though `ScanDocument.snapshot`
            // already does this — keeps `makeFileWrapper` standalone.
            try db.checkpoint()
            let dbWrapper = try FileWrapper(url: dbURL, options: [.immediate])
            dbWrapper.preferredFilename = databaseFilename
            contents[databaseFilename] = dbWrapper
        }

        // Blobs come from the disk-backed store. `FileWrapper(url:)` streams
        // bytes when the parent wrapper is written out — we never hold all
        // blob bytes in memory at once.
        let bucketed = store.blobStore.makeFileWrappersForSave()
        if !bucketed.isEmpty {
            var subdirs: [String: FileWrapper] = [:]
            for (prefix, files) in bucketed {
                subdirs[prefix] = FileWrapper(directoryWithFileWrappers: files)
            }
            contents[blobsDirectory] = FileWrapper(directoryWithFileWrappers: subdirs)
        }

        let root = FileWrapper(directoryWithFileWrappers: contents)
        root.preferredFilename = nil
        return root
    }

    // MARK: - Load

    /// Reads a directory FileWrapper back into the supplied store. Opens (or
    /// creates from legacy JSON) the persistent `data.db`, then attaches it to
    /// the store so subsequent scans write through.
    static func load(into store: ScanStore, from wrapper: FileWrapper) throws {
        guard wrapper.isDirectory, let children = wrapper.fileWrappers else {
            throw NSError(domain: "ScanPackage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a package"])
        }

        let cacheDir = store.blobStore.cacheDirectory
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let dbURL = cacheDir.appendingPathComponent(databaseFilename)
        // Always start from a clean slate — the cache dir is fresh per
        // session, but if a stale file is somehow there, remove it.
        try? FileManager.default.removeItem(at: dbURL)

        if let dbWrapper = children[databaseFilename],
           let dbBytes = dbWrapper.regularFileContents {
            try dbBytes.write(to: dbURL, options: .atomic)
            try openAndAttachDatabase(at: dbURL, store: store)
            try loadFromAttachedDatabase(store: store)
        } else if let itemsWrapper = children[legacyItemsFilename],
                  let itemsData = itemsWrapper.regularFileContents {
            // Legacy v2 path: decode the JSON, seed a new SQLite at dbURL,
            // attach it to the store.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let items = try decoder.decode(LegacyPayload.self, from: itemsData).items
            var legacyMeta: LegacyMetadata?
            if let metaWrapper = children[legacyMetadataFilename],
               let metaData = metaWrapper.regularFileContents {
                legacyMeta = try? decoder.decode(LegacyMetadata.self, from: metaData)
            }
            try openAndAttachDatabase(at: dbURL, store: store)
            store.load(
                items: items,
                systemInfo: legacyMeta?.systemInfo,
                options: legacyMeta?.options,
                lastScanStarted: legacyMeta?.lastScanStarted,
                lastScanCompleted: legacyMeta?.lastScanCompleted,
                mirrorToDatabase: true
            )
            print("[ScanPackage] Migrated legacy v2 bundle to SQLite")
        } else {
            // Empty / unknown bundle — give the store an empty database so
            // ongoing writes still persist.
            try openAndAttachDatabase(at: dbURL, store: store)
        }

        if let blobsRoot = children[blobsDirectory], let prefixes = blobsRoot.fileWrappers {
            for (_, prefixWrapper) in prefixes {
                guard prefixWrapper.isDirectory, let files = prefixWrapper.fileWrappers else { continue }
                for (filename, file) in files {
                    guard filename.hasSuffix(".bin") else { continue }
                    let ref = String(filename.dropLast(4))
                    store.blobStore.registerLoaded(ref: ref, wrapper: file)
                }
            }
        }
    }

    // MARK: - Helpers

    private static func openAndAttachDatabase(at url: URL, store: ScanStore) throws {
        let db = try Database(at: url)
        store.databaseURL = url
        store.attachDatabase(db)
    }

    private static func loadFromAttachedDatabase(store: ScanStore) throws {
        guard let db = store.database else { return }
        let items = try db.allItems()
        let systemInfo: SystemInfo? = (try? db.meta("system_info", as: SystemInfo.self)) ?? nil
        let options:    ScanOptions? = (try? db.meta("options", as: ScanOptions.self)) ?? nil
        let started:    Date?        = (try? db.meta("last_scan_started", as: Date.self)) ?? nil
        let completed:  Date?        = (try? db.meta("last_scan_completed", as: Date.self)) ?? nil

        store.load(
            items: items,
            systemInfo: systemInfo,
            options: options,
            lastScanStarted: started,
            lastScanCompleted: completed,
            mirrorToDatabase: false
        )
    }
}
