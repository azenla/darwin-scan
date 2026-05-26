import Foundation

/// One-shot scan driver suitable for a command-line invocation. The SwiftUI
/// `ScanController` is fire-and-forget (it returns immediately and writes
/// back via callbacks); this helper waits for the scan to finish.
///
/// Identical write model to the app: the destination `.darwinscan` bundle is
/// either created (`ScanPackage.createEmpty`) or opened in place
/// (`ScanPackage.openInPlace`), and the worker streams items straight into
/// `<bundle>/data.db` and `<bundle>/blobs/<prefix>/`. No FileWrapper-style
/// save copy at the end.
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

    /// Run a scan with `options` and write the resulting state into the
    /// `.darwinscan` bundle at `outputBundleURL`. Creates the bundle if it
    /// doesn't exist; opens it in place and appends a new snapshot if it
    /// does. Progress updates are delivered at the same cadence the GUI
    /// receives them (~150 ms throttle).
    public static func runScan(
        options: ScanOptions,
        outputBundleURL: URL,
        progressHandler: @escaping @MainActor (ProgressUpdate) -> Void = { _ in }
    ) async throws {
        let fm = FileManager.default
        let store: ScanStore
        if fm.fileExists(atPath: outputBundleURL.path) {
            store = ScanStore()
            try ScanPackage.openInPlace(at: outputBundleURL, into: store)
            FileHandle.standardError.write(Data("Re-scanning existing bundle (latest snapshot will become the parent of this one)\n".utf8))
        } else {
            store = try ScanPackage.createEmpty(at: outputBundleURL)
        }
        store.options = options
        let started = Date()
        store.lastScanStarted = started
        let info = SystemInfoCollector.capture()
        store.systemInfo = info
        store.beginSnapshot(at: started, systemInfo: info)

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
                for r in results {
                    newItems.append(r.item)
                    newItems.append(contentsOf: r.additionalItems)
                    for ref in r.blobRefs { refs.append(ref) }
                    if !r.symbols.isEmpty {
                        symbolRows.append(contentsOf: r.symbols)
                    }
                }
                blobStore.registerMany(refs)
                // Clear-on-rescan keyed by every itemID we're about to
                // re-insert symbols for — covers both first-class binaries
                // (whose item is `r.item`) and cached-image symbols
                // (whose item is one of `r.additionalItems`).
                var symbolItemIDs: Set<UUID> = []
                for row in symbolRows { symbolItemIDs.insert(row.itemID) }
                for id in symbolItemIDs where store.items[id] != nil {
                    store.clearSymbolsForReingest(id)
                }
                store.ingest(newItems)
                store.insertSymbols(symbolRows)
            },
            systemInfoSink: { info in
                store.systemInfo = info
            }
        )

        let completed = Date()
        let result = store.finalizeScan(at: completed)
        switch result.kind {
        case .discarded:
            store.reloadFromLatestSnapshot()
            FileHandle.standardError.write(Data("No changes detected — snapshot discarded; bundle on disk is unchanged.\n".utf8))
        case .kept:
            FileHandle.standardError.write(Data("Snapshot kept: +\(result.added) -\(result.removed) ~\(result.changed)\n".utf8))
        case .noSnapshot:
            break
        }

        // Checkpoint the WAL into the main DB file. The on-disk bundle is
        // already up-to-date from the per-batch transactions; this just
        // collapses the WAL so a copy of the bundle (or `darwin-scan
        // extract`) sees the final state without depending on the
        // companion `-wal` / `-shm` files.
        try? store.database?.checkpoint()
    }
}
