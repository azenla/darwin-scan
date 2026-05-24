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
public enum ScanPackage {
    // v3 names. `nonisolated` so the off-main save path
    // (`makeFileWrapper(snapshot:)`) can reference them — the project's
    // default actor isolation is MainActor, which would otherwise capture
    // these constants.
    public nonisolated static let databaseFilename = "data.db"
    public nonisolated static let blobsDirectory   = "blobs"
    public nonisolated static let packageVersion   = 3

    // v2 legacy names — read only.
    public nonisolated static let legacyMetadataFilename = "metadata.json"
    public nonisolated static let legacyItemsFilename    = "items.json"

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

    // MARK: - Snapshot

    /// Sendable, MainActor-free representation of the document state that the
    /// SwiftUI save path needs. `ScanDocument.snapshot(contentType:)` populates
    /// one of these on the background thread SwiftUI calls it on, and the
    /// equally-background `fileWrapper(snapshot:configuration:)` consumes it.
    public nonisolated struct Snapshot: Sendable {
        /// Captured `data.db` bytes (post-checkpoint). Nil when the document
        /// hasn't been backed by a database (shouldn't happen in practice).
        public let databaseBytes: Data?
        /// Directory holding `<ref>.bin` blob files. Blobs are content-
        /// addressed so referencing them by URL is race-free even if writes
        /// resume during serialization.
        public let blobCacheDirectory: URL

        public init(databaseBytes: Data?, blobCacheDirectory: URL) {
            self.databaseBytes = databaseBytes
            self.blobCacheDirectory = blobCacheDirectory
        }
    }

    // MARK: - Save

    /// Off-MainActor save path used by `ScanDocument.fileWrapper(snapshot:configuration:)`.
    /// Wraps the captured database bytes plus the on-disk blob files into a
    /// directory `FileWrapper` that SwiftUI streams out to the destination.
    public nonisolated static func makeFileWrapper(snapshot: Snapshot) throws -> FileWrapper {
        var contents: [String: FileWrapper] = [:]

        if let dbBytes = snapshot.databaseBytes {
            let dbWrapper = FileWrapper(regularFileWithContents: dbBytes)
            dbWrapper.preferredFilename = databaseFilename
            contents[databaseFilename] = dbWrapper
        }

        // Enumerate blob files in the session cache directory. Blobs are
        // content-addressed (`<hint>-<sha256>.bin`) so existing files are
        // immutable — pointing FileWrapper at the URL with `[.immediate]`
        // captures bytes now without holding a Data buffer per blob.
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

    /// Builds a `FileWrapper` directory representation of the current store.
    /// Caller is responsible for calling `database.checkpoint()` first so the
    /// WAL is folded into the main DB file before we read it back through
    /// `FileWrapper`. Used by the CLI and tests; the SwiftUI document save
    /// path uses `makeFileWrapper(snapshot:)` instead.
    public static func makeFileWrapper(from store: ScanStore) throws -> FileWrapper {
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

        // Don't set `preferredFilename` on the root — modern AppKit raises
        // an Objective-C exception when assigning nil here, and the caller
        // (DocumentGroup, write(to:), etc.) supplies the destination path
        // anyway.
        return FileWrapper(directoryWithFileWrappers: contents)
    }

    // MARK: - Load

    /// Reads a directory FileWrapper back into the supplied store. Opens (or
    /// creates from legacy JSON) the persistent `data.db`, then attaches it to
    /// the store so subsequent scans write through. Nonisolated because
    /// `ScanDocument.init(configuration:)` runs off MainActor under recent
    /// SwiftUI SDKs.
    public static func load(into store: ScanStore, from wrapper: FileWrapper) throws {
        guard wrapper.isDirectory, let children = wrapper.fileWrappers else {
            throw NSError(domain: "ScanPackage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not a package"])
        }

        let cacheDir = store.blobStore.cacheDirectory
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let dbURL = cacheDir.appendingPathComponent(databaseFilename)
        // Always start from a clean slate — the cache dir is fresh per
        // session, but if a stale file is somehow there, remove it.
        try? FileManager.default.removeItem(at: dbURL)

        if let dbWrapper = children[databaseFilename] {
            // Use `FileWrapper.write(to:options:)` rather than reading
            // `regularFileContents` first — for a /System scan with strings
            // extraction `data.db` can be hundreds of MB, and materialising
            // it as a `Data` buffer just to write it out doubles peak memory
            // on open. `write(to:)` streams when the source is file-backed.
            try dbWrapper.write(to: dbURL, options: [], originalContentsURL: nil)
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
                    // Stream the wrapper bytes into the session cache dir so
                    // the off-main save path can locate blobs by URL without
                    // hopping back through the (MainActor) BlobStore — and so
                    // `loadedWrappers` doesn't have to pin every blob in RAM.
                    let dstURL = cacheDir.appendingPathComponent(filename)
                    try? file.write(to: dstURL, options: [], originalContentsURL: nil)
                    store.blobStore.register(ref: ref)
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

    /// Strip an optional `hint-` prefix to expose the raw hash for sharding.
    /// Mirrors `BlobStore.blobHashPart` so the off-main save path can compute
    /// the same 2-character bucket without touching the MainActor store.
    private nonisolated static func blobHashPart(_ ref: String) -> String {
        if let dash = ref.firstIndex(of: "-") {
            return String(ref[ref.index(after: dash)...])
        }
        return ref
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
