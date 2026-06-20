import Foundation

/// Per-item analysis output.
public nonisolated struct AnalysisOutput: Sendable {
    public let item: ScanItem
    public let symbols: [SymbolRow]
    public let additionalItems: [ScanItem]
    /// Symbols for any synthesized children (dyld_shared_cache virtuals).
    public let additionalSymbols: [SymbolRow]

    public init(
        item: ScanItem,
        symbols: [SymbolRow] = [],
        additionalItems: [ScanItem] = [],
        additionalSymbols: [SymbolRow] = []
    ) {
        self.item = item
        self.symbols = symbols
        self.additionalItems = additionalItems
        self.additionalSymbols = additionalSymbols
    }
}

/// Thread-safe accumulator for parallel dyld-cache image extraction. Each
/// image is independent, so workers append their results under a lock rather
/// than threading per-index buffers through the `concurrentPerform` closure.
nonisolated final class DyldImageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var items: [ScanItem] = []
    private(set) var symbols: [SymbolRow] = []
    func reserve(_ n: Int) { items.reserveCapacity(n) }
    func add(item: ScanItem, symbols syms: [SymbolRow]) {
        lock.lock(); defer { lock.unlock() }
        items.append(item)
        if !syms.isEmpty { symbols.append(contentsOf: syms) }
    }
}

/// Stateless inspector dispatcher run during the **analysis** phase. Reads
/// bytes from the blob store (preferred — the bundle is the source of truth)
/// and falls back to the live filesystem only when an item has no
/// `fileBlobRef`. The latter is rare in practice: current-system scans
/// default to capture.
public nonisolated struct AnalysisPipeline: Sendable {
    public let options: ScanOptions
    public let blobStore: BlobStore
    public let database: Database?
    public let machO = MachOInspector()

    public init(options: ScanOptions, blobStore: BlobStore, database: Database? = nil) {
        self.options = options
        self.blobStore = blobStore
        self.database = database
    }

    /// Convenience for tests and tools that have a live URL but no
    /// existing item row: builds a minimal `ScanItem` for `url` (canonical
    /// path defaults to `url.path`) and runs the inspector pass against it.
    /// This is the closest analogue to the legacy `ScanPipeline.inspect(url:)`.
    public func analyze(url: URL, canonicalPath: String? = nil) -> AnalysisOutput {
        let path = canonicalPath ?? url.path
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let values = try? url.resourceValues(forKeys: keys)
        let size = Int64(values?.fileSize ?? 0)
        let item = ScanItem(
            id: UUID(),
            path: path, name: url.lastPathComponent, category: .unanalyzed,
            size: size, modifiedAt: values?.contentModificationDate,
            sha256: nil, insideBundle: false, owningBundlePath: nil
        )
        return analyze(item: item)
    }

    /// Refine one item. Returns a new `ScanItem` with category set, payload
    /// fields populated, tags/relationships rebuilt, plus any extracted
    /// symbols. The original `item.id` / `item.path` / `item.sha256` /
    /// `item.fileBlobRef` are preserved.
    public func analyze(item: ScanItem) -> AnalysisOutput {
        var item = item
        // Re-derive bundle membership from the canonical path on every
        // analysis run — these aren't stable across imports if the same
        // file moves between bundles, and the importer can't easily
        // compute them without per-item context.
        item.insideBundle = isInsideBundle(item.path)
        item.owningBundlePath = owningBundle(item.path)
        let filename = item.name
        let ext = (filename as NSString).pathExtension.lowercased()
        // Materialise a URL the legacy inspectors can read. Prefer the
        // captured blob — that's how IPSW analysis ever works. Live fall-
        // back lets the user analyze a current-system snapshot whose import
        // intentionally skipped capture.
        let inspectURL = resolveInspectURL(for: item)

        // Bundle wrappers (.app/.framework/.kext/etc.) — these arrived as
        // directory placeholders during import. The legacy inspectors need
        // a live directory tree; today we only handle them when the import
        // ran against a directory that still exists on disk (current-system
        // case). Blob-store-only bundles synthesise as a tag-only item.
        let isKnownBundleExt: Set<String> = ["app", "framework", "bundle", "kext", "mlpackage", "mlmodelc", "lproj"]
        if isKnownBundleExt.contains(ext), let url = inspectURL,
           (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return analyzeBundle(item: item, url: url, ext: ext)
        }

        // File items.
        guard let url = inspectURL else {
            // No bytes — best-effort heuristic from filename/extension only.
            return AnalysisOutput(item: stamp(item: item, category: .other, tags: ["analysis-unavailable"]))
        }
        return analyzeFile(item: item, url: url, ext: ext)
    }

    // MARK: - Bundles

    private func analyzeBundle(item: ScanItem, url: URL, ext: String) -> AnalysisOutput {
        switch ext {
        case "app":
            if let info = PlistInspector.decodeAppBundle(at: url) {
                var infoCopy = info
                if let png = AppBundleInspector.renderIconPNG(forBundle: url) {
                    let ref = "appicon-" + Hash.sha256Hex(png)
                    blobStore.makeWriter().write(png, ref: ref)
                    blobStore.register(ref: ref)
                    infoCopy.iconRef = ref
                }
                var tags: [String] = ["app"]
                if info.isHidden { tags.append("hidden") }
                if info.isAgentApp { tags.append("background-only") }
                if let category = info.category { tags.append(category) }
                var refined = item
                refined.category = .application
                refined.name = info.displayName ?? (url.deletingPathExtension().lastPathComponent)
                refined.application = infoCopy
                refined.tags = tags
                return AnalysisOutput(item: stampDone(refined))
            }
            return AnalysisOutput(item: stamp(item: item, category: .application, tags: ["app"]))
        case "framework", "bundle":
            let info = PlistInspector.decodeFrameworkBundle(at: url) ?? FrameworkInfo(
                bundleIdentifier: nil, shortVersionString: nil, currentVersion: nil,
                executableName: nil, headerCount: 0,
                isPrivate: url.path.contains("/PrivateFrameworks/")
            )
            var tags: [String] = ["framework"]
            if info.isPrivate { tags.append("private") }
            var refined = item
            refined.category = .framework
            refined.framework = info
            refined.tags = tags
            return AnalysisOutput(item: stampDone(refined))
        case "kext":
            let info = PlistInspector.decodeFrameworkBundle(at: url) ?? FrameworkInfo(
                bundleIdentifier: nil, shortVersionString: nil, currentVersion: nil,
                executableName: nil, headerCount: 0, isPrivate: false
            )
            var refined = item
            refined.category = .kext
            refined.framework = info
            refined.tags = ["kext"]
            return AnalysisOutput(item: stampDone(refined))
        case "mlpackage", "mlmodelc":
            if let info = MLModelInspector.inspect(url: url) {
                var refined = item
                refined.category = .mlModel
                refined.mlModel = info
                refined.tags = ["ml", info.container.rawValue]
                return AnalysisOutput(item: stampDone(refined))
            }
            return AnalysisOutput(item: stamp(item: item, category: .mlModel, tags: ["ml"]))
        case "lproj":
            if options.inspectLocalizations, let info = LocalizationInspector.inspectLprojDirectory(url) {
                var refined = item
                refined.category = .localization
                refined.localization = info
                refined.tags = ["lproj", info.language ?? "?"]
                return AnalysisOutput(item: stampDone(refined))
            }
            return AnalysisOutput(item: stamp(item: item, category: .localization, tags: ["lproj"]))
        default:
            return AnalysisOutput(item: stamp(item: item, category: .other, tags: []))
        }
    }

    // MARK: - Files

    private func analyzeFile(item: ScanItem, url: URL, ext: String) -> AnalysisOutput {
        let path = item.path
        let filename = item.name

        if options.inspectDyldCache, DyldCacheInspector.looksLikeDyldCache(filename: filename),
           let info = DyldCacheInspector.inspect(url: url) {
            var tags: [String] = ["dyld-cache"]
            if let arch = info.architecture { tags.append(arch) }
            var refined = item
            refined.category = .dyldCache
            refined.dyldCache = info
            refined.tags = tags
            // Synthesize per-image virtual framework items + cached symbols.
            var additionalItems: [ScanItem] = []
            var additionalSymbols: [SymbolRow] = []
            if !DyldCacheInspector.isSubcache(filename: filename),
               let images = DyldCacheInspector.enumerateImages(url: url),
               !images.isEmpty {
                let cacheArch = info.architecture ?? "?"
                let layout = options.extractSymbols ? DyldCacheLayout.load(mainCacheURL: url) : nil
                let strtab = layout.map { DyldCachedImageInspector.SharedStringTable(layout: $0) }

                // Extract every image in parallel — this is the single most
                // expensive analysis step (a /System cache has ~3000 images).
                // Each image is independent; SharedStringTable is thread-safe
                // (its mmap dict is locked and resolved once per image), and
                // `database.indexStrings` serializes on the writer. Results
                // merge into the collector under its lock.
                let collector = DyldImageCollector()
                collector.reserve(images.count)
                let imageArr = images
                let pipeline = self
                let db = database
                let extractStrings = options.extractStrings
                let minLen = options.stringsMinLength
                DispatchQueue.concurrentPerform(iterations: imageArr.count) { i in
                    let image = imageArr[i]
                    let virtual = pipeline.buildVirtualImageItem(image: image, cachePath: path, cacheName: filename, cacheArch: cacheArch)
                    var syms: [SymbolRow] = []
                    if let layout, let strtab,
                       let result = DyldCachedImageInspector.extract(
                           layout: layout, sharedStrtab: strtab,
                           imageAddress: image.address, itemID: virtual.id
                       ) {
                        syms = result.symbols
                        if extractStrings, let cstr = result.cstringBytes, let db {
                            let text = DyldCachedImageInspector.cstringTokensText(cstr, minLength: minLen)
                            if !text.isEmpty {
                                try? db.indexStrings(itemID: virtual.id, itemPath: virtual.path, content: text)
                            }
                        }
                    }
                    collector.add(item: virtual, symbols: syms)
                }
                additionalItems = collector.items
                additionalSymbols = collector.symbols
            }
            return AnalysisOutput(item: stampDone(refined), additionalItems: additionalItems, additionalSymbols: additionalSymbols)
        }

        if (path.hasPrefix("/System/Library/LaunchDaemons/") || path.hasPrefix("/System/Library/LaunchAgents/"))
            && ext == "plist", let info = PlistInspector.decodeLaunchService(at: url) {
            var tags = [info.kind == .daemon ? "daemon" : "agent"]
            if info.runAtLoad { tags.append("RunAtLoad") }
            if info.keepAlive { tags.append("KeepAlive") }
            var refined = item
            refined.category = .launchService
            refined.name = info.label ?? filename
            refined.launchService = info
            refined.tags = tags
            populateContextAndRelationships(item: &refined)
            return AnalysisOutput(item: stampDone(refined))
        }

        if ext == "plist", let (info, _) = PlistInspector.decodePlistInfo(at: url) {
            var tags: [String] = ["plist", info.format.rawValue]
            if info.kind != .other { tags.append(info.kind.rawValue) }
            if info.looksLikeInfoPlist { tags.append("Info.plist") }
            var refined = item
            refined.category = .plist
            refined.plist = info
            refined.tags = tags
            populateContextAndRelationships(item: &refined)
            return AnalysisOutput(item: stampDone(refined))
        }

        if options.inspectLocalizations, (ext == "strings" || ext == "stringsdict"),
           let info = LocalizationInspector.inspect(url: url) {
            var tags: [String] = [ext]
            if let lang = info.language { tags.append(lang) }
            var refined = item
            refined.category = .localization
            refined.localization = info
            refined.tags = tags
            populateContextAndRelationships(item: &refined)
            return AnalysisOutput(item: stampDone(refined))
        }

        if options.indexManPages, isManPagePath(path),
           let (info, _) = ManPageInspector.inspect(url: url) {
            var tags: [String] = ["man"]
            if let s = info.section { tags.append("\(s)") }
            var refined = item
            refined.category = .manPage
            refined.name = info.title ?? filename
            refined.manPage = info
            refined.tags = tags
            return AnalysisOutput(item: stampDone(refined))
        }

        if options.inspectMLModels, isMLModelExtension(ext), let info = MLModelInspector.inspect(url: url) {
            var refined = item
            refined.category = .mlModel
            refined.mlModel = info
            refined.tags = ["ml", info.container.rawValue]
            return AnalysisOutput(item: stampDone(refined))
        }

        if isIconExtension(ext), let (info, preview) = IconInspector.inspect(url: url) {
            var refs: [String] = []
            var copy = info
            if let preview {
                let ref = "icon-" + Hash.sha256Hex(preview)
                blobStore.makeWriter().write(preview, ref: ref)
                blobStore.register(ref: ref)
                copy.previewBlobRef = ref
                refs.append(ref)
            }
            var refined = item
            refined.category = .icon
            refined.icon = copy
            refined.tags = [info.kind.rawValue]
            return AnalysisOutput(item: stampDone(refined))
        }

        if let scriptInfo = readShebang(url) {
            var refined = item
            refined.category = .script
            refined.script = scriptInfo
            refined.tags = [scriptInfo.language ?? "script"]
            return AnalysisOutput(item: stampDone(refined))
        }

        if let machoInfo = machO.inspect(url: url) {
            return analyzeMachO(item: item, url: url, info: machoInfo)
        }

        return AnalysisOutput(item: stamp(item: item, category: .other, tags: []))
    }

    private func analyzeMachO(item: ScanItem, url: URL, info: ExecutableInfo) -> AnalysisOutput {
        var enriched = info
        let path = item.path
        let filename = item.name

        enriched.isApple = isApplePath(path)
        enriched.isCrossPlatformTool = WellKnownCrossPlatformTools.contains(filename.lowercased())

        if let csSliceOff = info.codeSignatureSliceOffset, let csSize = info.codeSignatureSize {
            let sliceFile = machO.sliceFileOffset(for: url)
            let absolute = sliceFile + csSliceOff
            if let csInfo = CodeSignatureInspector.parse(url: url, fileOffset: absolute, size: csSize) {
                enriched.signingIdentifier = csInfo.signingIdentifier
                enriched.teamIdentifier = csInfo.teamIdentifier
                enriched.isHardenedRuntime = csInfo.isHardenedRuntime
            }
        }
        if info.kind == .executable,
           let usage = StringsExtractor.grepInBinary(url: url, needle: "usage:") ??
                       StringsExtractor.grepInBinary(url: url, needle: "Usage:") {
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

        if options.extractStrings, info.kind == .executable, item.size <= options.maxInspectFileSize {
            if let ref = StringsExtractor.streamStrings(from: url, minLength: options.stringsMinLength, using: blobStore.makeWriter()) {
                enriched.stringsBlobRef = ref
                blobStore.register(ref: ref)
                if let database {
                    indexStringsBlob(database: database, itemID: item.id, itemPath: path, ref: ref)
                }
            }
        }

        let symbols: [SymbolRow]
        if options.extractSymbols, category == .executable || category == .framework {
            symbols = SymbolInspector.extract(url: url, itemID: item.id)
        } else {
            symbols = []
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

        var refined = item
        refined.category = category
        refined.executable = enriched
        refined.tags = tags
        refined.insideBundle = isInsideBundle(path)
        refined.owningBundlePath = owningBundle(path)
        populateContextAndRelationships(item: &refined)
        return AnalysisOutput(item: stampDone(refined), symbols: symbols)
    }

    // MARK: - Resolution

    private func resolveInspectURL(for item: ScanItem) -> URL? {
        if let ref = item.fileBlobRef {
            let url = blobStore.blobURL(forRef: ref)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // Fallback: live filesystem at the recorded path. Useful only when
        // the snapshot's source is the running OS and the file still exists.
        if FileManager.default.fileExists(atPath: item.path) {
            return URL(fileURLWithPath: item.path)
        }
        return nil
    }

    private func stamp(item: ScanItem, category: ItemCategory, tags: [String]) -> ScanItem {
        var copy = item
        copy.category = category
        if !tags.isEmpty { copy.tags = tags }
        copy.analysisState = .done
        copy.analyzedAt = Date()
        copy.analyzerVersion = Database.currentAnalyzerVersion
        return copy
    }

    private func stampDone(_ item: ScanItem) -> ScanItem {
        var copy = item
        copy.analysisState = .done
        copy.analyzedAt = Date()
        copy.analyzerVersion = Database.currentAnalyzerVersion
        return copy
    }

    // MARK: - Context + relationships (ported from old Scanner)

    private func populateContextAndRelationships(item: inout ScanItem) {
        if let bundlePath = item.owningBundlePath {
            let basename = (bundlePath as NSString).lastPathComponent
            let displayName = (basename as NSString).deletingPathExtension
            switch item.category {
            case .localization:
                if let lang = item.localization?.language {
                    item.context = "\(displayName) · \(lang)"
                } else { item.context = displayName }
            case .manPage:
                if let section = item.manPage?.section {
                    item.context = "\(displayName) · section \(section)"
                } else { item.context = displayName }
            default:
                item.context = displayName
            }
        } else {
            let parent = (item.path as NSString).deletingLastPathComponent
            let parentName = (parent as NSString).lastPathComponent
            switch item.category {
            case .manPage:
                if let section = item.manPage?.section { item.context = "section \(section)" }
            case .application:
                if !parent.isEmpty, parent != "/" { item.context = parent }
            default:
                if !parentName.isEmpty { item.context = parentName }
            }
        }

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
        if let app = item.application, let execPath = app.executablePath {
            rels.append(Relationship(kind: .containsExecutable, targetPath: execPath, note: app.executableName))
        }
        if let fw = item.framework, let execName = fw.executableName {
            switch item.category {
            case .kext:
                rels.append(Relationship(kind: .containsExecutable, targetPath: "\(item.path)/Contents/MacOS/\(execName)", note: execName))
            default:
                rels.append(Relationship(kind: .containsExecutable, targetPath: "\(item.path)/Versions/A/\(execName)", note: execName))
                rels.append(Relationship(kind: .containsExecutable, targetPath: "\(item.path)/\(execName)", note: execName))
            }
        }
        item.relationships = rels
    }

    private func buildVirtualImageItem(image: DyldCacheImage, cachePath: String, cacheName: String, cacheArch: String) -> ScanItem {
        let virtualPath = "\(cachePath)#\(image.path)"
        let imageName = (image.path as NSString).lastPathComponent
        let framework = FrameworkInfo(
            bundleIdentifier: nil, shortVersionString: nil, currentVersion: nil,
            executableName: imageName, headerCount: 0,
            isPrivate: image.path.contains("/PrivateFrameworks/")
        )
        var tags: [String] = ["dyld-cache-image", "framework"]
        if !cacheArch.isEmpty, cacheArch != "?" { tags.append(cacheArch) }
        if framework.isPrivate { tags.append("private") }
        return ScanItem(
            id: ItemIdentity.uuid(path: virtualPath, sha256: nil, bundlePathOnly: true),
            path: virtualPath, name: imageName, category: .framework,
            size: 0,
            modifiedAt: image.modTime > 0 ? Date(timeIntervalSince1970: TimeInterval(image.modTime)) : nil,
            sha256: nil, insideBundle: true, owningBundlePath: cachePath,
            framework: framework,
            tags: tags, context: "in \(cacheName)",
            relationships: [Relationship(kind: .inDyldCache, targetPath: cachePath, note: cacheArch)],
            analysisState: .done,
            analyzedAt: Date(),
            analyzerVersion: Database.currentAnalyzerVersion
        )
    }

    private func indexStringsBlob(database: Database, itemID: UUID, itemPath: String, ref: String) {
        let url = blobStore.blobURL(forRef: ref)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              !data.isEmpty else { return }
        // Decode lossily: a strings dump routinely contains bytes that aren't
        // valid UTF-8 (Latin-1 fragments, embedded binary). `String(data:
        // encoding: .utf8)` returns nil on the *first* bad byte, which
        // silently dropped the entire strings index for an item. Replacing
        // invalid sequences with U+FFFD keeps every searchable run.
        let text = String(decoding: data, as: UTF8.self)
        try? database.indexStrings(itemID: itemID, itemPath: itemPath, content: text)
    }

    // MARK: - Heuristics (ported)

    private func isMLModelExtension(_ ext: String) -> Bool {
        ["mlmodel", "mlpackage", "mlmodelc", "onnx", "tflite", "pt", "pth"].contains(ext)
    }
    private func isIconExtension(_ ext: String) -> Bool {
        ["icns", "png", "jpg", "jpeg", "tiff", "heic", "car"].contains(ext)
    }
    private func isManPagePath(_ path: String) -> Bool { path.contains("/share/man/man") }
    private func isInsideBundle(_ path: String) -> Bool {
        path.contains(".app/") || path.contains(".framework/") || path.contains(".bundle/")
            || path.contains(".kext/") || path.contains(".mlpackage/") || path.contains(".mlmodelc/")
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
        path.hasPrefix("/System/") || path.hasPrefix("/usr/lib") || path.hasPrefix("/usr/libexec")
            || path.hasPrefix("/usr/sbin")
            || (path.hasPrefix("/usr/bin/") && WellKnownAppleBinaries.contains((path as NSString).lastPathComponent))
    }
    private func readShebang(_ url: URL) -> ScriptInfo? {
        // Bind the handle so `defer` can close it — the previous one-liner
        // (`FileHandle(...).read(...)`) leaked a descriptor for every file
        // that wasn't a richer type, exhausting RLIMIT_NOFILE partway through
        // a /System analysis pass (after which every open silently fails).
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256), head.count >= 2 else { return nil }
        guard head[0] == 0x23, head[1] == 0x21 else { return nil }
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

// MARK: - Analysis worker (snapshot-wide)

/// Walks a snapshot's items via a SQLite cursor, runs the analyzer on each,
/// and writes the refined row back. Runs entirely on the actor's executor —
/// `run(...)` is an instance method (NOT a static func) so the body's
/// synchronous SQL+JSON work doesn't block the caller's actor (MainActor in
/// the GUI case). The single-cursor stream keeps memory bounded regardless
/// of snapshot size — there is never more than one `ScanItem` in flight.
public actor AnalysisWorker {
    public init() {}

    public func run(
        snapshotID: Int64,
        options: ScanOptions,
        store: ScanStore,
        progressSink: @escaping @Sendable @MainActor (ScanProgress) -> Void
    ) async {
        guard let database = store.database else { return }
        let pipeline = AnalysisPipeline(options: options, blobStore: store.blobStore, database: database)
        let maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        let total = (try? database.itemCountInSnapshot(snapshotID)) ?? 0
        var progress = ScanProgress(phase: .analyzing, startedAt: Date(), workerCount: maxConcurrent)
        progress.itemsFound = total
        await progressSink(progress)

        // Bounded query pulls just the IDs (16 B/item).
        let ids = (try? database.orderedItemIDs(inSnapshot: snapshotID)) ?? []

        var processed = 0
        var lastEmit = Date()
        let emitInterval: TimeInterval = 0.15

        // Producer/consumer. `maxConcurrent` tasks read + inspect items in
        // parallel (the slow part — Mach-O parse, symbol/string extraction —
        // on pooled reader connections). The consumer here on the actor
        // accumulates finished outputs and commits them in batches: the single
        // writer is serial, so committing N at a time keeps it from becoming
        // the bottleneck when per-item inspection is cheap (the bulk case).
        let writeBatchSize = 64
        var pending: [AnalysisWrite] = []
        pending.reserveCapacity(writeBatchSize)
        var recentPaths: [String] = []   // rolling window for the queue UI
        var active = 0                    // outstanding analyze tasks

        func flush() {
            guard !pending.isEmpty else { return }
            try? database.applyAnalysisBatch(
                pending, snapshotID: snapshotID,
                analyzedAt: Date(), analyzerVersion: Database.currentAnalyzerVersion
            )
            pending.removeAll(keepingCapacity: true)
        }

        await withTaskGroup(of: AnalysisOutput?.self) { group in
            var iterator = ids.makeIterator()
            while active < maxConcurrent, let id = iterator.next() {
                let itemID = id
                group.addTask { Self.readAndAnalyze(itemID, pipeline: pipeline, database: database) }
                active += 1
            }

            while let output = await group.next() {
                active -= 1
                if let output {
                    pending.append(AnalysisWrite(
                        item: output.item, symbols: output.symbols,
                        additionalItems: output.additionalItems, additionalSymbols: output.additionalSymbols
                    ))
                    processed += 1
                    progress.filesInspected = processed
                    progress.perCategoryCounts[output.item.category, default: 0] += 1
                    recentPaths.insert(output.item.path, at: 0)
                    if recentPaths.count > maxConcurrent { recentPaths.removeLast() }
                    if pending.count >= writeBatchSize { flush() }
                }
                // Keep the window full until the input is drained or cancelled.
                if !Task.isCancelled, let id = iterator.next() {
                    let itemID = id
                    group.addTask { Self.readAndAnalyze(itemID, pipeline: pipeline, database: database) }
                    active += 1
                }
                let n = Date()
                if n.timeIntervalSince(lastEmit) >= emitInterval {
                    lastEmit = n
                    progress.activeWorkers = active
                    progress.inFlightPaths = recentPaths
                    await progressSink(progress)
                }
            }
            flush()
        }

        progress.phase = .done
        progress.inFlightPaths = []
        progress.activeWorkers = 0
        await progressSink(progress)
    }

    /// Read + inspect one item (no write). Pure and `nonisolated`, so it runs
    /// off the actor across many tasks at once; reads use the reader pool and
    /// the inspectors hold no shared mutable state. The actor batches the
    /// returned outputs into the single writer.
    private nonisolated static func readAndAnalyze(
        _ id: UUID,
        pipeline: AnalysisPipeline,
        database: Database
    ) -> AnalysisOutput? {
        if Task.isCancelled { return nil }
        guard let item = try? database.item(id: id) else { return nil }
        return pipeline.analyze(item: item)
    }
}

// MARK: - Reference data

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
