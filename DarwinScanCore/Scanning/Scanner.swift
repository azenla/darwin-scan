import Foundation
import Observation

/// Single-shot scan controller. Holds an `actor`-isolated worker that does the
/// heavy lifting and a `@Observable` MainActor-side surface (`progress`,
/// `isRunning`) that SwiftUI can bind to.
///
/// IMPORTANT: `progress` has a single writer — the worker, via `progressSink`.
/// `batchSink` ingests items but does NOT touch `progress`. This is what keeps
/// the on-screen counters from flapping: every snapshot is internally
/// consistent because no other callback can clobber individual fields between
/// snapshots.
@Observable
@MainActor
public final class ScanController {
    public var progress: ScanProgress = ScanProgress()
    public var isRunning: Bool = false
    public var lastResult: ScanResult?

    private var workerTask: Task<Void, Never>?

    public init() {}

    public func cancel() {
        workerTask?.cancel()
    }

    public func startScan(options: ScanOptions, ingestInto store: ScanStore) {
        guard !isRunning else { return }
        isRunning = true
        progress = ScanProgress(phase: .enumerating, startedAt: Date())
        store.reset()
        store.options = options
        let started = Date()
        store.lastScanStarted = started
        // Capture sw_vers / uname / SIP state at scan start so the snapshot
        // row records OS-level metadata for later diff. Also seed
        // `store.systemInfo` so the toolbar reflects the host immediately
        // (worker would otherwise set it again ~150ms in).
        let capturedInfo = SystemInfoCollector.capture()
        store.systemInfo = capturedInfo
        // Open a snapshot row for this scan. `ingest` will record per-item
        // membership; `finalizeScan` below either keeps it or discards it
        // depending on whether anything changed.
        store.beginSnapshot(at: started, systemInfo: capturedInfo)

        let writer = store.blobStore.makeWriter()
        let blobStore = store.blobStore

        let worker = ScanWorker()
        // Pin the scan at `.utility` so the TaskGroup children running on the
        // worker actor's executor inherit it. Without this, the task adopts
        // the SwiftUI gesture's `.userInitiated` QoS, and ImageIO's internal
        // dispatches (`CGImageSourceCreateThumbnailAtIndex` in IconInspector)
        // run at `.default` — a higher-QoS thread waiting on lower-QoS work
        // is the textbook priority inversion the runtime warns about.
        workerTask = Task(priority: .utility) { @MainActor [weak self] in
            await worker.run(
                options: options,
                blobWriter: writer,
                database: store.database,
                progressSink: { [weak self] snapshot in
                    self?.progress = snapshot
                },
                batchSink: { results in
                    // Ingest only — never write to `progress` from here.
                    // The worker owns all progress counters.
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
                    // Path-collision rescans reuse a previous UUID; their
                    // old symbol rows would otherwise stick around. We
                    // clear before inserting so the new symbol set wins.
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
            self?.progress.phase = .done
            self?.progress.inFlightPaths.removeAll()
            self?.isRunning = false
            let completed = Date()
            // Finalize the snapshot. If nothing changed since the parent
            // snapshot, the new row is discarded (and the in-memory view
            // is reloaded from the parent so the user sees the prior
            // state). Otherwise the row is kept with completed_at set.
            let result = store.finalizeScan(at: completed)
            switch result.kind {
            case .discarded:
                store.reloadFromLatestSnapshot()
                print("[ScanController] snapshot discarded — no changes since previous scan")
            case .kept:
                print("[ScanController] snapshot kept: +\(result.added) -\(result.removed) ~\(result.changed)")
            case .noSnapshot:
                break
            }
        }
    }
}

public nonisolated struct ScanResult: Sendable {
    public var itemCount: Int

    public init(itemCount: Int) { self.itemCount = itemCount }
}

/// Output of one inspector run, with any blob bytes already persisted to disk
/// by the worker before this struct crosses an actor boundary.
public nonisolated struct InspectResult: Sendable {
    public let item: ScanItem
    public let blobRefs: [String]
    /// Symbols extracted from a Mach-O binary, stamped with this item's UUID
    /// so the main-actor sink can hand them straight to the database without
    /// re-parsing. Empty for non-Mach-O items and when `extractSymbols` is off.
    public let symbols: [SymbolRow]

    public init(item: ScanItem, blobRefs: [String], symbols: [SymbolRow] = []) {
        self.item = item
        self.blobRefs = blobRefs
        self.symbols = symbols
    }
}

// MARK: - Worker

public actor ScanWorker {
    public init() {}

    /// Run a scan. Architecture: a sliding-window `TaskGroup` keeps N
    /// inspector tasks in flight at any time, where N = (activeCPUs - 1).
    /// The walker is a single producer; its iterator is pumped from this
    /// actor's body (never from child tasks, which keeps it Sendable-clean).
    /// Throttled flushes batch ingested items so SwiftUI sees ~4 updates per
    /// second instead of one per file.
    ///
    /// The TaskGroup payload is `(URL, InspectResult?)` rather than just
    /// `InspectResult?` so we can identify which URL just completed and
    /// remove it from the in-flight set — that's what powers the live queue
    /// view in the UI.
    public func run(
        options: ScanOptions,
        blobWriter: BlobWriter,
        database: Database? = nil,
        progressSink: @escaping @Sendable @MainActor (ScanProgress) -> Void,
        batchSink: @escaping @Sendable @MainActor ([InspectResult]) -> Void,
        systemInfoSink: @escaping @Sendable @MainActor (SystemInfo) -> Void
    ) async {
        let info = SystemInfoCollector.capture()
        await systemInfoSink(info)

        let pipeline = ScanPipeline(options: options, blobWriter: blobWriter, database: database)
        let walker = FileWalker(options: options)

        let maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        var progress = ScanProgress(
            phase: .enumerating,
            startedAt: Date(),
            workerCount: maxConcurrent
        )
        await progressSink(progress)

        var batch: [InspectResult] = []
        batch.reserveCapacity(256)
        var lastFlush = Date()
        var lastProgressEmit = Date()
        let flushInterval: TimeInterval = 0.25
        let progressInterval: TimeInterval = 0.15
        let batchSize = 256

        // Ordered list of paths currently being inspected. Order = enqueue
        // order, so the UI shows a stable list. We use an array rather than
        // a Set because rendering wants determinism.
        var inFlight: [String] = []
        inFlight.reserveCapacity(maxConcurrent)

        await withTaskGroup(of: (URL, InspectResult?).self) { group in
            var iterator = walker.makeStream().makeAsyncIterator()

            // Prime the window with `maxConcurrent` initial tasks. After this,
            // every completed task triggers one new task — keeping the window
            // saturated until the walker is exhausted.
            for _ in 0..<maxConcurrent {
                guard let url = await iterator.next() else { break }
                progress.filesVisited += 1
                inFlight.append(url.path)
                group.addTask {
                    if Task.isCancelled { return (url, nil) }
                    return (url, pipeline.inspect(url: url))
                }
            }
            progress.phase = .inspecting
            progress.inFlightPaths = inFlight
            await progressSink(progress)

            while let (completedURL, result) = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }

                // Remove the completed URL from the in-flight list. There's
                // exactly one matching entry — we never enqueue the same URL
                // twice. firstIndex(of:) is O(n) but n ≤ activeCPUs.
                if let idx = inFlight.firstIndex(of: completedURL.path) {
                    inFlight.remove(at: idx)
                }

                if let result = result {
                    batch.append(result)
                    progress.filesInspected += 1
                    progress.itemsFound += 1
                    progress.perCategoryCounts[result.item.category, default: 0] += 1
                }

                // Top up the window with the next URL, if any.
                if let url = await iterator.next() {
                    progress.filesVisited += 1
                    inFlight.append(url.path)
                    group.addTask {
                        if Task.isCancelled { return (url, nil) }
                        return (url, pipeline.inspect(url: url))
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
                    progress.inFlightPaths = inFlight
                    await progressSink(progress)
                }
            }
        }

        if !batch.isEmpty {
            await batchSink(batch)
        }

        progress.phase = .done
        progress.inFlightPaths = []
        await progressSink(progress)
    }
}

// MARK: - Pipeline

/// Stateless inspector dispatcher. `Sendable` so it can be captured by the
/// concurrent child tasks. The `BlobWriter` it carries writes to disk without
/// any actor hops — bytes never cross thread boundaries.
///
/// `database` is an optional handle the pipeline uses to push large per-item
/// data straight into SQLite from the worker thread, bypassing the main-
/// actor batchSink for payloads that would dominate UI thread time. Today
/// that's used for `strings_fts` ingestion: a 10 MB strings dump tokenises
/// in ~200 ms, and doing that on MainActor would stall every frame during
/// the scan. The `Database` class is itself thread-safe (internal lock).
public nonisolated struct ScanPipeline: Sendable {
    public let options: ScanOptions
    public let blobWriter: BlobWriter
    public let database: Database?
    public let machO = MachOInspector()

    public init(options: ScanOptions, blobWriter: BlobWriter, database: Database? = nil) {
        self.options = options
        self.blobWriter = blobWriter
        self.database = database
    }

    /// Routes a URL to the appropriate inspector and returns the resulting
    /// item plus the set of blob refs we wrote to disk for it.
    public func inspect(url: URL) -> InspectResult? {
        guard let (item, blobs) = classify(url: url) else { return nil }
        // Write the in-memory blobs to disk on this worker thread before
        // crossing back to MainActor — keeps peak memory low and keeps the
        // main thread out of the byte-pushing path entirely.
        for (ref, data) in blobs {
            blobWriter.write(data, ref: ref)
        }
        var enriched = item
        populateContextAndRelationships(item: &enriched, originalURL: url)

        // File capture: copy the file bytes verbatim into the blob store so
        // a future `darwin-scan extract` can rebuild the original tree. Only
        // for regular files (no bundles) under the size cap. We need a
        // SHA-256 — reuse the item's if hashing is on, compute one if not.
        if options.captureFiles, enriched.size > 0, enriched.size <= options.maxCaptureFileSize {
            let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isRegularFile {
                let sha: String?
                if let existing = enriched.sha256 {
                    sha = existing
                } else {
                    sha = Hash.sha256(of: url)
                    enriched.sha256 = sha
                }
                if let sha {
                    let ref = "file-\(sha)"
                    blobWriter.copy(from: url, ref: ref)
                    enriched.fileBlobRef = ref
                }
            }
        }

        // Collect every ref this item references, whether it came in via
        // the in-memory `blobs` dict (icons, app icons) OR was streamed
        // directly to disk by an inspector (strings). The BlobStore needs
        // to know about all of them so saved bundles include the files.
        var refs = Array(blobs.keys)
        if let r = enriched.executable?.stringsBlobRef { refs.append(r) }
        if let r = enriched.application?.iconRef { refs.append(r) }
        if let r = enriched.icon?.previewBlobRef { refs.append(r) }
        if let r = enriched.fileBlobRef { refs.append(r) }

        // Symbol extraction: only for Mach-O items whose category indicates
        // a binary we'd actually want symbols for. Skip dyldCache (multi-GB
        // and not a single binary), kext (would need symbols but they're
        // typically stripped), and obviously non-binary categories.
        let symbols: [SymbolRow]
        if options.extractSymbols
            && (enriched.category == .executable || enriched.category == .framework)
            && enriched.executable != nil {
            symbols = SymbolInspector.extract(url: url, itemID: enriched.id)
        } else {
            symbols = []
        }
        return InspectResult(item: enriched, blobRefs: refs, symbols: symbols)
    }

    // MARK: Classification

    private func classify(url: URL) -> (ScanItem, [String: Data])? {
        let path = url.path
        let filename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let isDir = values.isDirectory ?? false
        let isFile = values.isRegularFile ?? false
        let size = Int64((values.fileSize ?? 0))
        let mtime = values.contentModificationDate

        if isDir {
            switch ext {
            case "app":         return makeAppBundleItem(at: url, size: size, mtime: mtime)
            case "framework":   return makeFrameworkItem(at: url, size: size, mtime: mtime)
            case "kext":        return makeKextItem(at: url, size: size, mtime: mtime)
            case "mlpackage", "mlmodelc":
                                return makeMLModelItem(at: url, size: size, mtime: mtime)
            case "lproj":
                if options.inspectLocalizations,
                   let info = LocalizationInspector.inspectLprojDirectory(url) {
                    return (ScanItem(
                        id: ItemIdentity.uuid(path: path, sha256: nil, bundlePathOnly: true),
                        path: path, name: filename, category: .localization,
                        size: size, modifiedAt: mtime, sha256: nil,
                        insideBundle: isInsideBundle(path), owningBundlePath: owningBundle(path),
                        localization: info,
                        tags: ["lproj", info.language ?? "?"]
                    ), [:])
                }
                return nil
            case "bundle":      return makeFrameworkItem(at: url, size: size, mtime: mtime)
            default:            return nil
            }
        }

        guard isFile else { return nil }

        if options.inspectDyldCache, DyldCacheInspector.looksLikeDyldCache(filename: filename),
           let info = DyldCacheInspector.inspect(url: url) {
            var tags: [String] = ["dyld-cache"]
            if let arch = info.architecture { tags.append(arch) }
            let sha = options.hashFiles ? Hash.sha256(of: url) : nil
            return (ScanItem(
                id: ItemIdentity.uuid(path: path, sha256: sha),
                path: path, name: filename, category: .dyldCache,
                size: size, modifiedAt: mtime, sha256: sha,
                insideBundle: false, owningBundlePath: nil,
                dyldCache: info,
                tags: tags
            ), [:])
        }

        if (path.hasPrefix("/System/Library/LaunchDaemons/") || path.hasPrefix("/System/Library/LaunchAgents/"))
            && ext == "plist",
           let info = PlistInspector.decodeLaunchService(at: url) {
            var tags = [info.kind == .daemon ? "daemon" : "agent"]
            if info.runAtLoad { tags.append("RunAtLoad") }
            if info.keepAlive { tags.append("KeepAlive") }
            let sha = options.hashFiles ? Hash.sha256(of: url) : nil
            return (ScanItem(
                id: ItemIdentity.uuid(path: path, sha256: sha),
                path: path, name: info.label ?? filename, category: .launchService,
                size: size, modifiedAt: mtime, sha256: sha,
                insideBundle: isInsideBundle(path), owningBundlePath: owningBundle(path),
                launchService: info,
                tags: tags
            ), [:])
        }

        // Plists that aren't launch services. We catch these BEFORE the
        // Mach-O fallback because plists never have Mach-O magic, but the
        // explicit detection lets us extract structure (format, top-level
        // shape, key count) for the detail view.
        if ext == "plist", let (info, _) = PlistInspector.decodePlistInfo(at: url) {
            var tags: [String] = ["plist", info.format.rawValue]
            if info.kind != .other { tags.append(info.kind.rawValue) }
            if info.looksLikeInfoPlist { tags.append("Info.plist") }
            let sha = options.hashFiles ? Hash.sha256(of: url) : nil
            return (ScanItem(
                id: ItemIdentity.uuid(path: path, sha256: sha),
                path: path, name: filename, category: .plist,
                size: size, modifiedAt: mtime, sha256: sha,
                insideBundle: isInsideBundle(path), owningBundlePath: owningBundle(path),
                plist: info,
                tags: tags
            ), [:])
        }

        if options.inspectLocalizations,
           (ext == "strings" || ext == "stringsdict"),
           let info = LocalizationInspector.inspect(url: url) {
            var tags: [String] = [ext]
            if let lang = info.language { tags.append(lang) }
            let sha = options.hashFiles ? Hash.sha256(of: url) : nil
            return (ScanItem(
                id: ItemIdentity.uuid(path: path, sha256: sha),
                path: path, name: filename, category: .localization,
                size: size, modifiedAt: mtime, sha256: sha,
                insideBundle: isInsideBundle(path), owningBundlePath: owningBundle(path),
                localization: info,
                tags: tags
            ), [:])
        }

        if options.indexManPages && isManPagePath(path) {
            if let (info, _) = ManPageInspector.inspect(url: url) {
                var tags: [String] = ["man"]
                if let section = info.section { tags.append("\(section)") }
                let sha = options.hashFiles ? Hash.sha256(of: url) : nil
                return (ScanItem(
                    id: ItemIdentity.uuid(path: path, sha256: sha),
                    path: path, name: info.title ?? filename, category: .manPage,
                    size: size, modifiedAt: mtime, sha256: sha,
                    insideBundle: false, owningBundlePath: nil,
                    manPage: info,
                    tags: tags
                ), [:])
            }
        }

        if options.inspectMLModels, isMLModelExtension(ext),
           let info = MLModelInspector.inspect(url: url) {
            let sha = options.hashFiles ? Hash.sha256(of: url) : nil
            return (ScanItem(
                id: ItemIdentity.uuid(path: path, sha256: sha),
                path: path, name: filename, category: .mlModel,
                size: size, modifiedAt: mtime, sha256: sha,
                insideBundle: isInsideBundle(path), owningBundlePath: owningBundle(path),
                mlModel: info,
                tags: ["ml", info.container.rawValue]
            ), [:])
        }

        if isIconExtension(ext), let (info, preview) = IconInspector.inspect(url: url) {
            var blobs: [String: Data] = [:]
            var infoCopy = info
            if let preview {
                let ref = "icon-" + Hash.sha256Hex(preview)
                blobs[ref] = preview
                infoCopy.previewBlobRef = ref
            }
            let sha = options.hashFiles ? Hash.sha256(of: url) : nil
            return (ScanItem(
                id: ItemIdentity.uuid(path: path, sha256: sha),
                path: path, name: filename, category: .icon,
                size: size, modifiedAt: mtime, sha256: sha,
                insideBundle: isInsideBundle(path), owningBundlePath: owningBundle(path),
                icon: infoCopy,
                tags: [info.kind.rawValue]
            ), blobs)
        }

        if let scriptInfo = readShebang(url) {
            let sha = options.hashFiles ? Hash.sha256(of: url) : nil
            return (ScanItem(
                id: ItemIdentity.uuid(path: path, sha256: sha),
                path: path, name: filename, category: .script,
                size: size, modifiedAt: mtime, sha256: sha,
                insideBundle: isInsideBundle(path), owningBundlePath: owningBundle(path),
                script: scriptInfo,
                tags: [scriptInfo.language ?? "script"]
            ), [:])
        }

        if let machoInfo = machO.inspect(url: url) {
            return makeMachOItem(at: url, size: size, mtime: mtime, info: machoInfo)
        }

        return nil
    }

    // MARK: Item builders

    private func makeAppBundleItem(at url: URL, size: Int64, mtime: Date?) -> (ScanItem, [String: Data])? {
        guard let info = PlistInspector.decodeAppBundle(at: url) else { return nil }
        var infoCopy = info
        var blobs: [String: Data] = [:]
        if let png = AppBundleInspector.renderIconPNG(forBundle: url) {
            let ref = "appicon-" + Hash.sha256Hex(png)
            blobs[ref] = png
            infoCopy.iconRef = ref
        }
        var tags: [String] = ["app"]
        if info.isHidden    { tags.append("hidden") }
        if info.isAgentApp  { tags.append("background-only") }
        if let category = info.category { tags.append(category) }
        return (ScanItem(
            id: ItemIdentity.uuid(path: url.path, sha256: nil, bundlePathOnly: true),
            path: url.path,
            name: info.displayName ?? url.deletingPathExtension().lastPathComponent,
            category: .application,
            size: size, modifiedAt: mtime, sha256: nil,
            insideBundle: false, owningBundlePath: nil,
            application: infoCopy,
            tags: tags
        ), blobs)
    }

    private func makeFrameworkItem(at url: URL, size: Int64, mtime: Date?) -> (ScanItem, [String: Data])? {
        guard let info = PlistInspector.decodeFrameworkBundle(at: url) else {
            let bare = FrameworkInfo(
                bundleIdentifier: nil, shortVersionString: nil, currentVersion: nil,
                executableName: nil, headerCount: 0,
                isPrivate: url.path.contains("/PrivateFrameworks/")
            )
            return (ScanItem(
                id: ItemIdentity.uuid(path: url.path, sha256: nil, bundlePathOnly: true),
                path: url.path, name: url.deletingPathExtension().lastPathComponent,
                category: .framework, size: size, modifiedAt: mtime, sha256: nil,
                insideBundle: false, owningBundlePath: nil,
                framework: bare,
                tags: bare.isPrivate ? ["private-framework"] : ["framework"]
            ), [:])
        }
        var tags: [String] = ["framework"]
        if info.isPrivate { tags.append("private") }
        return (ScanItem(
            id: ItemIdentity.uuid(path: url.path, sha256: nil, bundlePathOnly: true),
            path: url.path, name: url.deletingPathExtension().lastPathComponent,
            category: .framework, size: size, modifiedAt: mtime, sha256: nil,
            insideBundle: false, owningBundlePath: nil,
            framework: info,
            tags: tags
        ), [:])
    }

    private func makeKextItem(at url: URL, size: Int64, mtime: Date?) -> (ScanItem, [String: Data])? {
        let info = PlistInspector.decodeFrameworkBundle(at: url)
            ?? FrameworkInfo(
                bundleIdentifier: nil, shortVersionString: nil, currentVersion: nil,
                executableName: nil, headerCount: 0, isPrivate: false
            )
        return (ScanItem(
            id: ItemIdentity.uuid(path: url.path, sha256: nil, bundlePathOnly: true),
            path: url.path, name: url.deletingPathExtension().lastPathComponent,
            category: .kext, size: size, modifiedAt: mtime, sha256: nil,
            insideBundle: false, owningBundlePath: nil,
            framework: info,
            tags: ["kext"]
        ), [:])
    }

    private func makeMLModelItem(at url: URL, size: Int64, mtime: Date?) -> (ScanItem, [String: Data])? {
        guard let info = MLModelInspector.inspect(url: url) else { return nil }
        return (ScanItem(
            id: ItemIdentity.uuid(path: url.path, sha256: nil, bundlePathOnly: true),
            path: url.path, name: url.deletingPathExtension().lastPathComponent,
            category: .mlModel, size: size, modifiedAt: mtime, sha256: nil,
            insideBundle: false, owningBundlePath: nil,
            mlModel: info,
            tags: ["ml", info.container.rawValue]
        ), [:])
    }

    private func makeMachOItem(at url: URL, size: Int64, mtime: Date?, info: ExecutableInfo) -> (ScanItem, [String: Data])? {
        var enriched = info
        // The strings dump is streamed directly to disk inside the BlobStore
        // cache dir via `StringsExtractor.streamStrings`, so we have no other
        // in-memory blobs to register from this Mach-O path.
        let blobs: [String: Data] = [:]
        let path = url.path
        let filename = url.lastPathComponent
        let inside = isInsideBundle(path)
        let owning = owningBundle(path)
        // Compute sha256 once up-front so the deterministic item ID can be
        // derived from (path, sha256) and strings_fts can be indexed under
        // the same id before the ScanItem is constructed. When hashing is
        // off the id falls back to a random UUID — re-scans of unhashed
        // binaries won't dedup, which is the documented tradeoff.
        let sha = options.hashFiles ? Hash.sha256(of: url) : nil
        let itemID = ItemIdentity.uuid(path: path, sha256: sha)

        enriched.isApple = isApplePath(path)
        enriched.isCrossPlatformTool = WellKnownCrossPlatformTools.contains(filename.lowercased())

        if info.kind == .executable, let usage = StringsExtractor.grepInBinary(url: url, needle: "usage:") {
            enriched.usageLine = usage
        } else if info.kind == .executable, let usage = StringsExtractor.grepInBinary(url: url, needle: "Usage:") {
            enriched.usageLine = usage
        }

        let category: ItemCategory
        switch info.kind {
        case .dylib, .bundle: category = .framework
        case .kext:           category = .kext
        case .executable:     category = .executable
        default:              category = .other
        }

        var roles: [ExecutableInfo.Role] = []
        if info.kind == .executable {
            if enriched.usageLine != nil { roles.append(.cli) }
            if path.contains("/libexec/") || path.contains("/PrivateFrameworks/") { roles.append(.helper) }
            if enriched.isCrossPlatformTool { roles.append(.interpreter) }
        } else if info.kind == .dylib {
            roles.append(.library)
        }
        enriched.roles = roles

        if options.extractStrings && info.kind == .executable && size <= options.maxInspectFileSize {
            // Streams /usr/bin/strings output directly to disk; no blob bytes
            // are ever held in worker memory. The function hashes the file
            // after writing and returns the content-addressed ref — caller
            // doesn't add anything to `blobs`, which is reserved for the
            // in-memory writer path.
            if let ref = StringsExtractor.streamStrings(
                from: url,
                minLength: options.stringsMinLength,
                into: blobWriter.directory
            ) {
                enriched.stringsBlobRef = ref
                // Tokenize the blob into FTS5 on this worker thread. Loading
                // a multi-MB strings dump as String + calling MainActor
                // tokenization would stall the UI; doing it inline here
                // keeps everything off-main. The Database lock serializes
                // FTS inserts across worker tasks.
                if let database {
                    indexStringsBlob(database: database, itemID: itemID, itemPath: path, ref: ref)
                }
            }
        }

        var tags: [String] = []
        switch info.kind {
        case .executable: tags.append("executable")
        case .dylib:      tags.append("dylib")
        case .bundle:     tags.append("bundle")
        case .dylinker:   tags.append("dylinker")
        case .kext:       tags.append("kext")
        case .object:     tags.append("object")
        case .dsym:       tags.append("dsym")
        case .core:       tags.append("core")
        case .unknown:    tags.append("macho")
        }
        for arch in info.architectures { tags.append(arch) }
        if info.isFatBinary { tags.append("fat") }
        if enriched.isCrossPlatformTool { tags.append("cross-platform") }
        if enriched.isApple == false { tags.append("third-party") }
        if let platform = info.platform { tags.append(platform) }
        if enriched.usageLine != nil { tags.append("cli") }

        return (ScanItem(
            id: itemID, path: path, name: filename, category: category,
            size: size, modifiedAt: mtime,
            sha256: sha,
            insideBundle: inside, owningBundlePath: owning,
            executable: enriched,
            tags: tags
        ), blobs)
    }

    // MARK: Context + relationships

    /// Compute `context` (the disambiguating label shown next to the name in
    /// lists) and `relationships` (outgoing graph edges). Pure derivation from
    /// the item's own fields plus the original URL — no cross-item lookups, so
    /// it's safe to run in the inspector pipeline before items are reconciled.
    private func populateContextAndRelationships(item: inout ScanItem, originalURL: URL) {
        // --- context ---
        if let bundlePath = item.owningBundlePath {
            let basename = (bundlePath as NSString).lastPathComponent
            let displayName = (basename as NSString).deletingPathExtension
            switch item.category {
            case .localization:
                if let lang = item.localization?.language {
                    item.context = "\(displayName) · \(lang)"
                } else {
                    item.context = displayName
                }
            case .manPage:
                if let section = item.manPage?.section {
                    item.context = "\(displayName) · section \(section)"
                } else {
                    item.context = displayName
                }
            default:
                item.context = displayName
            }
        } else {
            // Top-level item — show parent directory for disambiguation.
            let parent = originalURL.deletingLastPathComponent().path
            let parentName = (parent as NSString).lastPathComponent
            switch item.category {
            case .manPage:
                if let section = item.manPage?.section {
                    item.context = "section \(section)"
                }
            case .application:
                // Top-level apps: parent path like /System/Applications or /System/Library/CoreServices
                if !parent.isEmpty, parent != "/" { item.context = parent }
            default:
                if !parentName.isEmpty { item.context = parentName }
            }
        }

        // --- relationships ---
        var rels: [Relationship] = []
        if let owning = item.owningBundlePath {
            rels.append(Relationship(kind: .ownedByBundle, targetPath: owning, note: nil))
        }
        if let exec = item.executable {
            for lib in exec.linkedLibraries {
                rels.append(Relationship(kind: .linksDylib, targetPath: lib, note: nil))
            }
        }
        if let ls = item.launchService, let program = ls.program {
            rels.append(Relationship(kind: .launchesProgram, targetPath: program, note: "Program"))
        }
        item.relationships = rels
    }

    // MARK: Strings FTS

    /// Load a strings-dump blob from disk and ingest it into the database's
    /// `strings_fts` virtual table. Called from the worker pipeline so the
    /// tokenisation doesn't run on the main actor. The string content can
    /// be tens of MB for a large dylib; we load it as Data and convert to
    /// String once. Failures are silent — we shouldn't abort a scan for a
    /// missing FTS row.
    private func indexStringsBlob(database: Database, itemID: UUID, itemPath: String, ref: String) {
        let blobURL = blobWriter.directory.appendingPathComponent("\(ref).bin")
        guard let data = try? Data(contentsOf: blobURL, options: [.mappedIfSafe]),
              !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return }
        try? database.indexStrings(itemID: itemID, itemPath: itemPath, content: text)
    }

    // MARK: Heuristics

    private func isMLModelExtension(_ ext: String) -> Bool {
        ["mlmodel", "mlpackage", "mlmodelc", "onnx", "tflite", "pt", "pth"].contains(ext)
    }

    private func isIconExtension(_ ext: String) -> Bool {
        ["icns", "png", "jpg", "jpeg", "tiff", "heic", "car"].contains(ext)
    }

    private func isManPagePath(_ path: String) -> Bool {
        path.contains("/share/man/man")
    }

    private func isInsideBundle(_ path: String) -> Bool {
        path.contains(".app/") ||
            path.contains(".framework/") ||
            path.contains(".bundle/") ||
            path.contains(".kext/") ||
            path.contains(".mlpackage/") ||
            path.contains(".mlmodelc/")
    }

    private func owningBundle(_ path: String) -> String? {
        for suffix in [".app", ".framework", ".bundle", ".kext", ".mlpackage", ".mlmodelc"] {
            if let range = path.range(of: "\(suffix)/") {
                let endIndex = range.upperBound
                let bundleEnd = path.index(before: endIndex)
                return String(path[path.startIndex..<bundleEnd])
            }
        }
        return nil
    }

    private func isApplePath(_ path: String) -> Bool {
        path.hasPrefix("/System/") ||
            path.hasPrefix("/usr/lib") ||
            path.hasPrefix("/usr/libexec") ||
            path.hasPrefix("/usr/sbin") ||
            (path.hasPrefix("/usr/bin/") && WellKnownAppleBinaries.contains((path as NSString).lastPathComponent))
    }

    private func readShebang(_ url: URL) -> ScriptInfo? {
        guard let head = try? FileHandle(forReadingFrom: url).read(upToCount: 256), head.count >= 2 else { return nil }
        guard head[0] == 0x23, head[1] == 0x21 else { return nil } // "#!"
        guard let nl = head.firstIndex(of: 0x0A) else { return nil }
        let interp = String(data: head[2..<nl], encoding: .utf8)?.trimmingCharacters(in: .whitespaces)
        let language = languageFromInterpreter(interp ?? "")
        return ScriptInfo(interpreter: interp, language: language, lineCount: nil)
    }

    private func languageFromInterpreter(_ line: String) -> String? {
        let firstToken = line.split(separator: " ").first.map(String.init) ?? line
        let last = (firstToken as NSString).lastPathComponent
        if last == "env" {
            let tokens = line.split(separator: " ").map(String.init)
            if tokens.count >= 2 {
                let cmd = (tokens[1] as NSString).lastPathComponent
                return normalizeLanguage(cmd)
            }
        }
        return normalizeLanguage(last)
    }

    private func normalizeLanguage(_ name: String) -> String? {
        let lower = name.lowercased()
        if lower.hasPrefix("python") { return "python" }
        if lower.hasPrefix("perl")   { return "perl" }
        if lower.hasPrefix("ruby")   { return "ruby" }
        if lower.hasPrefix("node")   { return "node" }
        if lower.hasPrefix("bash") || lower.hasPrefix("zsh") || lower.hasPrefix("sh") || lower == "dash" { return "shell" }
        if lower.hasPrefix("awk")    { return "awk" }
        if lower.hasPrefix("tcl")    { return "tcl" }
        if lower == "osascript"      { return "applescript" }
        return name.isEmpty ? nil : name
    }
}

// MARK: - Reference data (nonisolated so the pipeline can use them off-main)

nonisolated private let WellKnownAppleBinaries: Set<String> = [
    "diskutil", "tmutil", "csrutil", "softwareupdate", "pmset",
    "launchctl", "systemsetup", "asr", "dscl", "scutil",
    "codesign", "spctl", "stapler", "xattr", "xcrun", "xcode-select",
    "say", "open", "pbcopy", "pbpaste", "defaults",
    "log", "system_profiler", "ioreg", "kextstat", "vm_stat"
]

nonisolated private let WellKnownCrossPlatformTools: Set<String> = [
    "perl", "perl5.34", "perl5.28", "perl5.30", "perl5.32",
    "python", "python3", "python3.9", "python3.10", "python3.11", "python3.12",
    "ruby", "irb", "gem", "bundle",
    "tclsh", "wish",
    "awk", "gawk", "sed", "grep", "egrep", "fgrep",
    "bash", "zsh", "sh", "dash", "ksh", "tcsh", "csh",
    "vim", "vi", "ex", "view", "nano", "emacs", "ed",
    "less", "more", "head", "tail", "cat", "tac",
    "make", "gmake",
    "git", "svn", "cvs",
    "openssl", "curl", "wget",
    "ssh", "scp", "sftp", "rsync", "telnet",
    "tar", "gzip", "gunzip", "bzip2", "bunzip2", "xz", "unxz", "zstd",
    "patch", "diff", "diff3", "sdiff", "cmp",
    "expr", "bc", "dc", "factor",
    "find", "xargs", "locate", "which", "whereis",
    "uniq", "sort", "comm", "join", "paste",
    "tr", "cut", "wc", "split", "csplit", "od", "fold", "fmt",
    "ps", "top", "kill", "killall", "pkill", "pgrep", "renice", "nice",
    "ping", "traceroute", "netstat", "nc", "host", "dig", "nslookup",
    "ftp",
    "yacc", "bison", "flex",
    "lex", "m4", "as", "nm", "ar", "ranlib",
    "tmux", "screen"
]
