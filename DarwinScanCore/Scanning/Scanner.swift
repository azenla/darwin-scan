import Foundation
import Observation

/// Two-phase scan orchestrator.
///
/// - **Import**: walks a `SourceProvider`, hashes files, captures bytes into
///   the blob store, and writes minimal `ScanItem` rows. Items land with
///   `category = .unanalyzed` and `analysisState = .pending`. Fast — there
///   are no inspector calls in this phase. Bound to the in-flight snapshot
///   so cancelling discards just that snapshot.
///
/// - **Analyze**: re-runs the inspectors against captured blob bytes (or
///   live file paths for current-system imports where capture is off).
///   Refines category, populates per-category payloads, extracts symbols
///   and strings into FTS. Re-runnable on a finished snapshot or on a
///   single item.
///
/// `ScanController` is the SwiftUI-facing surface. It owns the worker actor
/// and emits `ScanProgress` snapshots for the UI to bind to.
@Observable
@MainActor
public final class ScanController {
    public var progress: ScanProgress = ScanProgress()
    public var isRunning: Bool = false
    public var phase: Phase = .idle

    public enum Phase: Equatable {
        case idle
        case importing
        case analyzing
        case done
        case failed(String)
    }

    private var workerTask: Task<Void, Never>?
    /// Throttle for the periodic in-analysis store refresh (sidebar counts +
    /// live search). Reset at the start of each analysis run.
    private var lastAnalysisRefresh = Date()
    /// Provider currently driving the active import. Held so we can tear
    /// down (unmount IPSW, remove extraction dir) when the import finishes
    /// or is cancelled.
    private var activeSource: (any SourceProvider)?

    public init() {}

    public func cancel() { workerTask?.cancel() }

    // MARK: - Import

    /// Start an import using the given source. Creates a new snapshot row in
    /// the bundle, walks the source, writes minimal items + captures bytes.
    /// Does NOT run analysis — call `startAnalysis(...)` afterwards.
    public func startImport(
        source: any SourceProvider,
        options: ScanOptions,
        into store: ScanStore
    ) {
        guard !isRunning else { return }
        isRunning = true
        phase = .importing
        progress = ScanProgress(phase: .importing, startedAt: Date())
        store.options = options
        let started = Date()
        store.lastScanStarted = started
        store.systemInfo = source.systemInfo

        let snapshotID = store.beginImport(
            source: source.sourceKind,
            sourceRef: source.sourceRef,
            startedAt: started,
            label: source.snapshotLabel,
            systemInfo: source.systemInfo,
            options: options
        )
        guard snapshotID != nil else {
            phase = .failed("Failed to open snapshot row")
            isRunning = false
            return
        }

        activeSource = source
        let writer = store.blobStore.makeWriter()
        let blobStore = store.blobStore
        let pipeline = ImportPipeline(options: options, blobWriter: writer, source: source)
        let walker = FileWalker(options: options, rootURLs: source.roots)

        workerTask = Task(priority: .utility) { @MainActor [weak self] in
            await ImportWorker.run(
                pipeline: pipeline,
                walker: walker,
                progressSink: { [weak self] snapshot in
                    self?.progress = snapshot
                },
                batchSink: { results in
                    var refs: [String] = []
                    refs.reserveCapacity(results.count)
                    var newItems: [ScanItem] = []
                    newItems.reserveCapacity(results.count)
                    for r in results {
                        newItems.append(r.item)
                        for ref in r.blobRefs { refs.append(ref) }
                    }
                    blobStore.registerMany(refs)
                    store.ingest(newItems)
                }
            )
            self?.progress.phase = .done
            self?.progress.inFlightPaths.removeAll()
            self?.isRunning = false
            let completed = Date()
            if Task.isCancelled {
                store.discardCurrentImport()
                self?.phase = .failed("cancelled")
            } else {
                store.completeImport(at: completed)
                self?.phase = .done
            }
            self?.activeSource?.cleanup()
            self?.activeSource = nil
            try? store.database?.checkpoint()
        }
    }

    // MARK: - Analyze

    /// Run analysis over every item in `snapshotID` (defaults to the
    /// active snapshot). Idempotent — items are reset and re-analyzed.
    public func startAnalysis(
        snapshotID: Int64? = nil,
        options: ScanOptions,
        in store: ScanStore
    ) {
        guard !isRunning else { return }
        guard let database = store.database else { return }
        let targetSnapshot = snapshotID ?? store.activeSnapshotID
        guard let targetSnapshot else { return }
        isRunning = true
        phase = .analyzing
        progress = ScanProgress(phase: .analyzing, startedAt: Date())
        lastAnalysisRefresh = Date()
        try? database.markSnapshotAnalysis(
            snapshotID: targetSnapshot,
            state: .running,
            analyzedAt: nil,
            analyzerVersion: nil
        )
        store.invalidateSnapshotHistory()

        let worker = AnalysisWorker()
        workerTask = Task(priority: .utility) { @MainActor [weak self] in
            // AnalysisWorker.run is an instance method on the actor, so the
            // body runs on the worker's executor — MainActor stays free
            // during the per-item SQL + inspector loop.
            await worker.run(
                snapshotID: targetSnapshot,
                options: options,
                store: store,
                progressSink: { [weak self] snapshot in
                    guard let self else { return }
                    self.progress = snapshot
                    // Periodically refresh the in-memory snapshot view so the
                    // sidebar category counts climb and field searches
                    // (arch:, symbol:, …) populate live during analysis —
                    // throttled so the full-snapshot re-filter it triggers
                    // isn't paid on every progress tick.
                    let now = Date()
                    if now.timeIntervalSince(self.lastAnalysisRefresh) > 2.5 {
                        self.lastAnalysisRefresh = now
                        store.noteAnalysisProgress()
                    }
                }
            )
            let completed = Date()
            self?.progress.phase = .done
            self?.progress.inFlightPaths.removeAll()
            self?.isRunning = false
            if Task.isCancelled {
                try? database.markSnapshotAnalysis(
                    snapshotID: targetSnapshot,
                    state: .partial,
                    analyzedAt: nil,
                    analyzerVersion: Database.currentAnalyzerVersion
                )
                self?.phase = .failed("cancelled")
            } else {
                try? database.markSnapshotAnalysis(
                    snapshotID: targetSnapshot,
                    state: .done,
                    analyzedAt: completed,
                    analyzerVersion: Database.currentAnalyzerVersion
                )
                self?.phase = .done
            }
            store.invalidateSnapshotHistory()
            // Refresh the active-snapshot in-memory view from disk so the
            // user sees the refined items. The refresh re-reads ~half a
            // million headers for a /System-scale bundle, so push it off
            // MainActor — the controller has already flipped `.isRunning`
            // back to false, so the toolbar is responsive while this runs.
            if let active = store.activeSnapshotID {
                let store = store
                let snapID = active
                Task.detached(priority: .userInitiated) {
                    store.setActiveSnapshot(snapID)
                }
            }
            try? database.checkpoint()
        }
    }

    /// Re-run analysis for a single item. Intended for the detail view's
    /// "Analyze this item" affordance.
    public func analyzeItem(_ itemID: UUID, options: ScanOptions, in store: ScanStore) {
        guard let database = store.database else { return }
        guard let item = try? database.item(id: itemID) else { return }
        let pipeline = AnalysisPipeline(options: options, blobStore: store.blobStore, database: database)
        let refined = pipeline.analyze(item: item)
        store.applyAnalysis(refined.item, symbols: refined.symbols)
        try? database.setItemAnalysisState(
            itemID: itemID,
            state: .done,
            analyzedAt: Date(),
            analyzerVersion: Database.currentAnalyzerVersion
        )
    }
}

// MARK: - Import result

public nonisolated struct ImportResult: Sendable {
    public let item: ScanItem
    public let blobRefs: [String]
    public init(item: ScanItem, blobRefs: [String]) {
        self.item = item
        self.blobRefs = blobRefs
    }
}

// MARK: - Import pipeline

public nonisolated struct ImportPipeline: Sendable {
    public let options: ScanOptions
    public let blobWriter: BlobWriter
    public let source: any SourceProvider

    public init(options: ScanOptions, blobWriter: BlobWriter, source: any SourceProvider) {
        self.options = options
        self.blobWriter = blobWriter
        self.source = source
    }

    /// Capture one file into the bundle, returning a minimal ScanItem.
    /// Skips directories entirely (analysis recovers bundles from the
    /// per-file rows it imports inside them).
    public func importOne(url: URL) -> ImportResult? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let isFile = values.isRegularFile ?? false
        // Bundle wrappers come in as directories. Record them as bundle-
        // shaped items so the analyzer can classify them; their bytes don't
        // need capture (their constituent files do).
        let isDir = values.isDirectory ?? false
        let path = source.canonicalPath(for: url)
        let filename = url.lastPathComponent
        let size = Int64(values.fileSize ?? 0)
        let mtime = values.contentModificationDate

        if isDir {
            // Emit a placeholder row only for known bundle extensions so we
            // don't flood the manifest with every directory in the tree.
            let ext = url.pathExtension.lowercased()
            let knownBundleExt: Set<String> = ["app", "framework", "bundle", "kext", "mlpackage", "mlmodelc", "lproj"]
            guard knownBundleExt.contains(ext) else { return nil }
            let item = ScanItem(
                id: ItemIdentity.uuid(path: path, sha256: nil, bundlePathOnly: true),
                path: path,
                name: filename,
                category: .unanalyzed,
                size: size,
                modifiedAt: mtime,
                sha256: nil,
                insideBundle: false,
                owningBundlePath: nil,
                tags: ["unanalyzed"]
            )
            return ImportResult(item: item, blobRefs: [])
        }
        guard isFile else { return nil }

        // Hash + (optionally) capture the bytes. We always hash when
        // captureFiles is on because the deterministic id needs sha256.
        let sha: String?
        var refs: [String] = []
        var fileBlobRef: String? = nil
        let shouldCapture = options.captureFiles && size > 0 && size <= options.maxCaptureFileSize
        if shouldCapture {
            // Single pass: hash the bytes *while* writing them to the blob
            // store, instead of one full read to hash and a second full read
            // to copy.
            if let captured = blobWriter.captureHashing(from: url, refPrefix: "file-") {
                sha = captured.sha
                fileBlobRef = captured.ref
                refs.append(captured.ref)
            } else {
                // Capture failed (e.g. a transient write error). Fall back to
                // a hash-only pass so the item can still get deterministic
                // identity if the file is at least readable.
                sha = Hash.sha256(of: url)
            }
        } else if options.hashFiles || options.captureFiles {
            // Not capturing (disabled, empty file, or over the cap) but the
            // identity still needs a hash.
            sha = Hash.sha256(of: url)
        } else {
            sha = nil
        }

        let item = ScanItem(
            id: ItemIdentity.uuid(path: path, sha256: sha),
            path: path,
            name: filename,
            category: .unanalyzed,
            size: size,
            modifiedAt: mtime,
            sha256: sha,
            insideBundle: false, // analyzer fills this in
            owningBundlePath: nil,
            fileBlobRef: fileBlobRef,
            tags: ["unanalyzed"]
        )
        return ImportResult(item: item, blobRefs: refs)
    }
}

// MARK: - Import worker

public actor ImportWorker {
    public static func run(
        pipeline: ImportPipeline,
        walker: FileWalker,
        progressSink: @escaping @Sendable @MainActor (ScanProgress) -> Void,
        batchSink: @escaping @Sendable @MainActor ([ImportResult]) -> Void
    ) async {
        let maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        var progress = ScanProgress(phase: .importing, startedAt: Date(), workerCount: maxConcurrent)
        await progressSink(progress)

        var batch: [ImportResult] = []
        batch.reserveCapacity(256)
        var lastFlush = Date()
        var lastProgressEmit = Date()
        let flushInterval: TimeInterval = 0.25
        let progressInterval: TimeInterval = 0.15
        let batchSize = 256
        var inFlight: [URL] = []
        inFlight.reserveCapacity(maxConcurrent)

        await withTaskGroup(of: (URL, ImportResult?).self) { group in
            var iterator = walker.makeStream().makeAsyncIterator()
            for _ in 0..<maxConcurrent {
                guard let url = await iterator.next() else { break }
                progress.filesVisited += 1
                inFlight.append(url)
                group.addTask {
                    if Task.isCancelled { return (url, nil) }
                    return (url, pipeline.importOne(url: url))
                }
            }
            progress.inFlightPaths = inFlight.map { pipeline.source.displayPath(for: $0) }
                progress.activeWorkers = inFlight.count
            await progressSink(progress)

            while let (completedURL, result) = await group.next() {
                if Task.isCancelled { group.cancelAll(); continue }
                if let idx = inFlight.firstIndex(of: completedURL) {
                    inFlight.remove(at: idx)
                }
                if let result {
                    batch.append(result)
                    progress.filesInspected += 1
                    progress.itemsFound += 1
                    progress.perCategoryCounts[result.item.category, default: 0] += 1
                    progress.bytesHashed += result.item.size
                }
                if let url = await iterator.next() {
                    progress.filesVisited += 1
                    inFlight.append(url)
                    group.addTask {
                        if Task.isCancelled { return (url, nil) }
                        return (url, pipeline.importOne(url: url))
                    }
                }
                let now = Date()
                if batch.count >= batchSize || (now.timeIntervalSince(lastFlush) >= flushInterval && !batch.isEmpty) {
                    let toSend = batch
                    batch.removeAll(keepingCapacity: true)
                    lastFlush = now
                    await batchSink(toSend)
                }
                if now.timeIntervalSince(lastProgressEmit) >= progressInterval {
                    lastProgressEmit = now
                    progress.inFlightPaths = inFlight.map { pipeline.source.displayPath(for: $0) }
                progress.activeWorkers = inFlight.count
                    await progressSink(progress)
                }
            }
        }
        if !batch.isEmpty { await batchSink(batch) }
        progress.phase = .done
        progress.inFlightPaths = []
        await progressSink(progress)
    }
}
