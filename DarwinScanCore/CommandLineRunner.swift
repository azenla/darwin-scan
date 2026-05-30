import Foundation

/// Synchronous-style drivers for the new two-phase CLI. The SwiftUI
/// `ScanController` is fire-and-forget; these helpers await completion so
/// `darwin-scan` exits with a sensible status code.
@MainActor
public enum CommandLineRunner {
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

    /// Phase 1: import only. Creates the bundle if it doesn't exist; chains
    /// a new snapshot onto the existing snapshot history otherwise.
    public static func runImport(
        source: any SourceProvider,
        options: ScanOptions,
        outputBundleURL: URL,
        progressHandler: @escaping @MainActor (ProgressUpdate) -> Void = { _ in }
    ) async throws {
        let fm = FileManager.default
        let store: ScanStore
        if fm.fileExists(atPath: outputBundleURL.path) {
            store = ScanStore()
            try ScanPackage.openInPlace(at: outputBundleURL, into: store)
        } else {
            store = try ScanPackage.createEmpty(at: outputBundleURL)
        }
        store.options = options

        let started = Date()
        store.lastScanStarted = started
        store.systemInfo = source.systemInfo
        store.beginImport(
            source: source.sourceKind,
            sourceRef: source.sourceRef,
            startedAt: started,
            label: source.snapshotLabel,
            systemInfo: source.systemInfo,
            options: options
        )

        let writer = store.blobStore.makeWriter()
        let blobStore = store.blobStore
        let pipeline = ImportPipeline(options: options, blobWriter: writer, source: source)
        let walker = FileWalker(options: options, rootURLs: source.roots)

        await ImportWorker.run(
            pipeline: pipeline,
            walker: walker,
            progressSink: { snapshot in progressHandler(ProgressUpdate(from: snapshot)) },
            batchSink: { results in
                var refs: [String] = []; refs.reserveCapacity(results.count)
                var items: [ScanItem] = []; items.reserveCapacity(results.count)
                for r in results {
                    items.append(r.item)
                    for ref in r.blobRefs { refs.append(ref) }
                }
                blobStore.registerMany(refs)
                store.ingest(items)
            }
        )

        let completed = Date()
        store.completeImport(at: completed)
        try? store.database?.checkpoint()
        FileHandle.standardError.write(Data("Imported \(store.itemCount) items.\n".utf8))
        source.cleanup()
    }

    /// Phase 2: re-runnable analysis. `snapshotID == nil` means "latest".
    public static func runAnalysis(
        bundleURL: URL,
        snapshotID: Int64? = nil,
        options: ScanOptions,
        progressHandler: @escaping @MainActor (ProgressUpdate) -> Void = { _ in }
    ) async throws {
        let store = ScanStore()
        try ScanPackage.openInPlace(at: bundleURL, into: store)
        guard let database = store.database else {
            throw NSError(domain: "darwin-scan", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bundle has no database."])
        }
        let target: Int64?
        if let snapshotID {
            target = snapshotID
        } else {
            target = try database.latestSnapshotID()
        }
        guard let target else {
            throw NSError(domain: "darwin-scan", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No snapshot to analyze."])
        }
        try? database.markSnapshotAnalysis(snapshotID: target, state: .running, analyzedAt: nil, analyzerVersion: nil)
        store.invalidateSnapshotHistory()

        let worker = AnalysisWorker()
        await worker.run(
            snapshotID: target,
            options: options,
            store: store,
            progressSink: { snapshot in progressHandler(ProgressUpdate(from: snapshot)) }
        )
        try? database.markSnapshotAnalysis(
            snapshotID: target,
            state: .done,
            analyzedAt: Date(),
            analyzerVersion: Database.currentAnalyzerVersion
        )
        try? database.checkpoint()
        FileHandle.standardError.write(Data("Analysis complete for snapshot \(target).\n".utf8))
    }

    public static func listSnapshots(bundleURL: URL) throws -> [SnapshotRecord] {
        let store = ScanStore()
        try ScanPackage.openInPlace(at: bundleURL, into: store)
        return store.snapshotHistory()
    }

    public static func deleteSnapshot(bundleURL: URL, snapshotID: Int64) throws {
        let store = ScanStore()
        try ScanPackage.openInPlace(at: bundleURL, into: store)
        store.deleteSnapshot(snapshotID)
        try? store.database?.checkpoint()
    }
}
