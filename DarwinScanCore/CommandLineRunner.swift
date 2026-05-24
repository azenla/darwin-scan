import Foundation

/// One-shot scan driver suitable for a command-line invocation. The SwiftUI
/// `ScanController` is fire-and-forget (it returns immediately and writes
/// back via callbacks); this helper waits for the scan to finish and saves
/// the result to a `.darwinscan` bundle on disk.
///
/// Memory model is identical to the app's: a fresh `ScanStore` + `BlobStore`
/// + `Database` are created in a session cache dir, the worker streams
/// items through `ingest`, and `ScanPackage.makeFileWrapper` serializes the
/// finished store back into a directory bundle at `outputBundleURL`.
@MainActor
public enum CommandLineRunner {
    /// Progress snapshot delivered to the host CLI for display.
    public struct ProgressUpdate: Sendable {
        public let phase: ScanProgress.Phase
        public let filesVisited: Int
        public let filesInspected: Int
        public let itemsFound: Int
        public let inFlight: [String]
        public let workerCount: Int

        public init(from snapshot: ScanProgress) {
            self.phase = snapshot.phase
            self.filesVisited = snapshot.filesVisited
            self.filesInspected = snapshot.filesInspected
            self.itemsFound = snapshot.itemsFound
            self.inFlight = snapshot.inFlightPaths
            self.workerCount = snapshot.workerCount
        }
    }

    /// Run a scan with `options` and save the resulting `.darwinscan` bundle
    /// to `outputBundleURL`. The directory at `outputBundleURL` is replaced
    /// if it already exists. Progress updates are delivered to
    /// `progressHandler` on the main actor at the same cadence the GUI
    /// receives them (~150 ms throttle).
    public static func runScan(
        options: ScanOptions,
        outputBundleURL: URL,
        progressHandler: @escaping @MainActor (ProgressUpdate) -> Void = { _ in }
    ) async throws {
        let store = ScanStore()
        try attachFreshDatabase(to: store)
        store.options = options
        store.lastScanStarted = Date()

        let writer = store.blobStore.makeWriter()
        let blobStore = store.blobStore

        let worker = ScanWorker()
        await worker.run(
            options: options,
            blobWriter: writer,
            database: store.database,
            progressSink: { snapshot in
                progressHandler(ProgressUpdate(from: snapshot))
            },
            batchSink: { results in
                var refs: [String] = []
                refs.reserveCapacity(results.count)
                var newItems: [ScanItem] = []
                newItems.reserveCapacity(results.count)
                var symbolRows: [SymbolRow] = []
                var symbolIDs: [UUID] = []
                for r in results {
                    newItems.append(r.item)
                    for ref in r.blobRefs { refs.append(ref) }
                    if !r.symbols.isEmpty {
                        symbolRows.append(contentsOf: r.symbols)
                        symbolIDs.append(r.item.id)
                    }
                }
                blobStore.registerMany(refs)
                for id in symbolIDs {
                    if store.items[id] != nil {
                        store.clearSymbolsForReingest(id)
                    }
                }
                store.ingest(newItems)
                store.insertSymbols(symbolRows)
            },
            systemInfoSink: { info in
                store.systemInfo = info
            }
        )

        store.lastScanCompleted = Date()

        // Build the FileWrapper and write to disk. Replace any prior bundle
        // at the destination — generating into an existing bundle would
        // intermix old & new blobs without diffing.
        let wrapper = try ScanPackage.makeFileWrapper(from: store)
        let fm = FileManager.default
        if fm.fileExists(atPath: outputBundleURL.path) {
            try fm.removeItem(at: outputBundleURL)
        }
        try wrapper.write(to: outputBundleURL, options: [.atomic], originalContentsURL: nil)
    }

    /// Attach a fresh SQLite database inside the store's BlobStore cache
    /// directory. Mirrors what `ScanDocument` does when a new document is
    /// created in the app — the bundle save later pulls the file out of
    /// that directory.
    private static func attachFreshDatabase(to store: ScanStore) throws {
        let cacheDir = store.blobStore.cacheDirectory
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let url = cacheDir.appendingPathComponent(ScanPackage.databaseFilename)
        try? FileManager.default.removeItem(at: url)
        let db = try Database(at: url)
        store.databaseURL = url
        store.attachDatabase(db)
    }
}
