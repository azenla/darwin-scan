import Foundation
import Observation

/// Single-shot scan controller. Holds an `actor`-isolated worker that does the
/// heavy lifting and a `@Observable` MainActor-side surface (`progress`,
/// `isRunning`) that SwiftUI can bind to.
@Observable
@MainActor
final class ScanController {
    var progress: ScanProgress = ScanProgress()
    var isRunning: Bool = false
    /// Set after a successful run — the items the scanner produced, ready to
    /// be ingested into a document's store.
    var lastResult: ScanResult?

    private var workerTask: Task<Void, Never>?

    func cancel() {
        workerTask?.cancel()
    }

    /// Kick off a scan. Items are ingested into the provided store as they
    /// finish — that way you can see live counts updating in the sidebar
    /// while a long /System walk is still running.
    func startScan(options: ScanOptions, ingestInto store: ScanStore) {
        guard !isRunning else { return }
        isRunning = true
        progress = ScanProgress(phase: .enumerating, startedAt: Date())
        store.reset()
        store.options = options
        store.lastScanStarted = Date()

        let worker = ScanWorker()
        workerTask = Task { @MainActor [weak self] in
            await worker.run(
                options: options,
                progressSink: { [weak self] snapshot in
                    self?.progress = snapshot
                },
                itemSink: { [weak self] item, blobs in
                    guard let self else { return }
                    for (ref, data) in blobs {
                        store.setBlob(data, forRef: ref)
                    }
                    store.upsert(item)
                    self.progress.itemsFound = store.items.count
                    self.progress.perCategoryCounts[item.category, default: 0] += 1
                },
                systemInfoSink: { info in
                    store.systemInfo = info
                }
            )
            self?.progress.phase = .done
            self?.isRunning = false
            store.lastScanCompleted = Date()
        }
    }
}

/// Result envelope — currently just a count. Kept so we can grow features
/// (timing breakdowns, error log) without changing the controller surface.
struct ScanResult: Sendable {
    var itemCount: Int
}

/// Where `ScanStore` is `@MainActor`-by-default-isolation, this worker runs on
/// a background actor and never touches the store directly. Inspector outputs
/// are funnelled through closures (`itemSink`) so the MainActor side can
/// serialize all store mutations.
private actor ScanWorker {
    let machO = MachOInspector()

    func run(
        options: ScanOptions,
        progressSink: @escaping @Sendable @MainActor (ScanProgress) -> Void,
        itemSink: @escaping @Sendable @MainActor (ScanItem, [String: Data]) -> Void,
        systemInfoSink: @escaping @Sendable @MainActor (SystemInfo) -> Void
    ) async {
        // System info first — cheap, and the UI can show it immediately.
        let info = SystemInfoCollector.capture()
        await systemInfoSink(info)

        var progress = ScanProgress(phase: .enumerating, startedAt: Date())
        await progressSink(progress)

        let walker = FileWalker(options: options)

        // We pull URLs out of the walker stream and batch the per-item work
        // so we don't hop back to MainActor on every single file (would slow
        // a /System scan dramatically).
        var batch: [(ScanItem, [String: Data])] = []
        batch.reserveCapacity(64)

        for await url in walker.makeStream() {
            if Task.isCancelled { break }
            progress.filesVisited += 1
            progress.currentPath = url.path
            if progress.filesVisited % 64 == 0 {
                await progressSink(progress)
            }

            if let produced = inspect(url: url, options: options) {
                progress.filesInspected += 1
                batch.append(produced)
                if batch.count >= 32 {
                    let toFlush = batch
                    batch.removeAll(keepingCapacity: true)
                    for (item, blobs) in toFlush {
                        await itemSink(item, blobs)
                    }
                }
            }
        }
        if !batch.isEmpty {
            for (item, blobs) in batch {
                await itemSink(item, blobs)
            }
        }

        progress.phase = .done
        progress.currentPath = ""
        await progressSink(progress)
    }

    /// Routes a URL to the appropriate inspector. Returns nil for files we
    /// don't classify (e.g. plain text data files inside /usr/share).
    nonisolated func inspect(url: URL, options: ScanOptions) -> (ScanItem, [String: Data])? {
        let path = url.path
        let filename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let fm = FileManager.default

        // Resource values: cheaper than two stat calls for size + mtime + type.
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let isDir = values.isDirectory ?? false
        let isFile = values.isRegularFile ?? false
        let size = Int64((values.fileSize ?? 0))
        let mtime = values.contentModificationDate

        // Directories first — bundles are categorized by extension.
        if isDir {
            switch ext {
            case "app":
                return makeAppBundleItem(at: url, size: size, mtime: mtime)
            case "framework":
                return makeFrameworkItem(at: url, size: size, mtime: mtime, kind: .framework)
            case "kext":
                return makeKextItem(at: url, size: size, mtime: mtime)
            case "mlpackage", "mlmodelc":
                return makeMLModelItem(at: url, size: size, mtime: mtime)
            case "lproj":
                if options.inspectLocalizations,
                   let info = LocalizationInspector.inspectLprojDirectory(url) {
                    return (ScanItem(
                        id: UUID(), path: path, name: filename, category: .localization,
                        size: size, modifiedAt: mtime, sha256: nil,
                        insideBundle: isInsideBundle(path), owningBundlePath: owningBundle(path),
                        localization: info,
                        tags: ["lproj", info.language ?? "?"]
                    ), [:])
                }
                return nil
            case "bundle":
                // Generic resource bundle — record as framework for now since
                // they behave similarly (.framework is a kind of .bundle).
                return makeFrameworkItem(at: url, size: size, mtime: mtime, kind: .framework)
            default:
                // Plain directory — not interesting on its own.
                return nil
            }
        }

        guard isFile else { return nil }

        // File-based dispatch ---------------------------------------------------
        // Order matters: prefer "rich" inspectors before falling back to
        // generic Mach-O detection.

        // DYLD shared cache files (under /System/Library/dyld/ and inside cryptexes)
        if options.inspectDyldCache, DyldCacheInspector.looksLikeDyldCache(filename: filename),
           let info = DyldCacheInspector.inspect(url: url) {
            var tags: [String] = ["dyld-cache"]
            if let arch = info.architecture { tags.append(arch) }
            return (ScanItem(
                id: UUID(), path: path, name: filename, category: .dyldCache,
                size: size, modifiedAt: mtime,
                sha256: options.hashFiles ? Hash.sha256(of: url) : nil,
                insideBundle: false, owningBundlePath: nil,
                dyldCache: info,
                tags: tags
            ), [:])
        }

        // Launch plists.
        if (path.hasPrefix("/System/Library/LaunchDaemons/") || path.hasPrefix("/System/Library/LaunchAgents/"))
            && ext == "plist",
           let info = PlistInspector.decodeLaunchService(at: url) {
            var tags = [info.kind == .daemon ? "daemon" : "agent"]
            if info.runAtLoad { tags.append("RunAtLoad") }
            if info.keepAlive { tags.append("KeepAlive") }
            return (ScanItem(
                id: UUID(), path: path, name: info.label ?? filename, category: .launchService,
                size: size, modifiedAt: mtime,
                sha256: options.hashFiles ? Hash.sha256(of: url) : nil,
                insideBundle: isInsideBundle(path), owningBundlePath: owningBundle(path),
                launchService: info,
                tags: tags
            ), [:])
        }

        // Localizations.
        if options.inspectLocalizations,
           (ext == "strings" || ext == "stringsdict"),
           let info = LocalizationInspector.inspect(url: url) {
            var tags: [String] = [ext]
            if let lang = info.language { tags.append(lang) }
            return (ScanItem(
                id: UUID(), path: path, name: filename, category: .localization,
                size: size, modifiedAt: mtime,
                sha256: options.hashFiles ? Hash.sha256(of: url) : nil,
                insideBundle: isInsideBundle(path), owningBundlePath: owningBundle(path),
                localization: info,
                tags: tags
            ), [:])
        }

        // Man pages.
        if options.indexManPages && isManPagePath(path) {
            if let (info, _) = ManPageInspector.inspect(url: url) {
                var tags: [String] = ["man"]
                if let section = info.section { tags.append("\(section)") }
                return (ScanItem(
                    id: UUID(), path: path, name: info.title ?? filename, category: .manPage,
                    size: size, modifiedAt: mtime,
                    sha256: options.hashFiles ? Hash.sha256(of: url) : nil,
                    insideBundle: false, owningBundlePath: nil,
                    manPage: info,
                    tags: tags
                ), [:])
            }
        }

        // Standalone ML models.
        if options.inspectMLModels, isMLModelExtension(ext),
           let info = MLModelInspector.inspect(url: url) {
            return (ScanItem(
                id: UUID(), path: path, name: filename, category: .mlModel,
                size: size, modifiedAt: mtime,
                sha256: options.hashFiles ? Hash.sha256(of: url) : nil,
                insideBundle: isInsideBundle(path), owningBundlePath: owningBundle(path),
                mlModel: info,
                tags: ["ml", info.container.rawValue]
            ), [:])
        }

        // Icons and images that look like app/system icons.
        if isIconExtension(ext), let (info, preview) = IconInspector.inspect(url: url) {
            var blobs: [String: Data] = [:]
            var infoCopy = info
            if let preview {
                let ref = "icon-" + Hash.sha256Hex(preview)
                blobs[ref] = preview
                infoCopy.previewBlobRef = ref
            }
            return (ScanItem(
                id: UUID(), path: path, name: filename, category: .icon,
                size: size, modifiedAt: mtime,
                sha256: options.hashFiles ? Hash.sha256(of: url) : nil,
                insideBundle: isInsideBundle(path), owningBundlePath: owningBundle(path),
                icon: infoCopy,
                tags: [info.kind.rawValue]
            ), blobs)
        }

        // Scripts — detected by shebang.
        if isFile, let scriptInfo = readShebang(url) {
            return (ScanItem(
                id: UUID(), path: path, name: filename, category: .script,
                size: size, modifiedAt: mtime,
                sha256: options.hashFiles ? Hash.sha256(of: url) : nil,
                insideBundle: isInsideBundle(path), owningBundlePath: owningBundle(path),
                script: scriptInfo,
                tags: [scriptInfo.language ?? "script"]
            ), [:])
        }

        // Mach-O — last because magic-byte sniffing is the most expensive.
        if let machoInfo = machO.inspect(url: url) {
            return makeMachOItem(at: url, size: size, mtime: mtime, info: machoInfo, options: options, fm: fm)
        }

        return nil
    }

    // MARK: Item builders

    private nonisolated func makeAppBundleItem(at url: URL, size: Int64, mtime: Date?) -> (ScanItem, [String: Data])? {
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
            id: UUID(),
            path: url.path,
            name: info.displayName ?? url.deletingPathExtension().lastPathComponent,
            category: .application,
            size: size, modifiedAt: mtime, sha256: nil,
            insideBundle: false, owningBundlePath: nil,
            application: infoCopy,
            tags: tags
        ), blobs)
    }

    private nonisolated func makeFrameworkItem(at url: URL, size: Int64, mtime: Date?, kind: ItemCategory) -> (ScanItem, [String: Data])? {
        guard let info = PlistInspector.decodeFrameworkBundle(at: url) else {
            // Some bundles have no Info.plist but are still framework-shaped;
            // surface them with a minimal record so they're findable.
            let bare = FrameworkInfo(
                bundleIdentifier: nil, shortVersionString: nil, currentVersion: nil,
                executableName: nil, headerCount: 0,
                isPrivate: url.path.contains("/PrivateFrameworks/")
            )
            return (ScanItem(
                id: UUID(), path: url.path, name: url.deletingPathExtension().lastPathComponent,
                category: .framework, size: size, modifiedAt: mtime, sha256: nil,
                insideBundle: false, owningBundlePath: nil,
                framework: bare,
                tags: bare.isPrivate ? ["private-framework"] : ["framework"]
            ), [:])
        }
        var tags: [String] = ["framework"]
        if info.isPrivate { tags.append("private") }
        return (ScanItem(
            id: UUID(), path: url.path, name: url.deletingPathExtension().lastPathComponent,
            category: .framework, size: size, modifiedAt: mtime, sha256: nil,
            insideBundle: false, owningBundlePath: nil,
            framework: info,
            tags: tags
        ), [:])
    }

    private nonisolated func makeKextItem(at url: URL, size: Int64, mtime: Date?) -> (ScanItem, [String: Data])? {
        let info = PlistInspector.decodeFrameworkBundle(at: url)
            ?? FrameworkInfo(
                bundleIdentifier: nil, shortVersionString: nil, currentVersion: nil,
                executableName: nil, headerCount: 0, isPrivate: false
            )
        return (ScanItem(
            id: UUID(), path: url.path, name: url.deletingPathExtension().lastPathComponent,
            category: .kext, size: size, modifiedAt: mtime, sha256: nil,
            insideBundle: false, owningBundlePath: nil,
            framework: info,
            tags: ["kext"]
        ), [:])
    }

    private nonisolated func makeMLModelItem(at url: URL, size: Int64, mtime: Date?) -> (ScanItem, [String: Data])? {
        guard let info = MLModelInspector.inspect(url: url) else { return nil }
        return (ScanItem(
            id: UUID(), path: url.path, name: url.deletingPathExtension().lastPathComponent,
            category: .mlModel, size: size, modifiedAt: mtime, sha256: nil,
            insideBundle: false, owningBundlePath: nil,
            mlModel: info,
            tags: ["ml", info.container.rawValue]
        ), [:])
    }

    private nonisolated func makeMachOItem(at url: URL, size: Int64, mtime: Date?, info: ExecutableInfo, options: ScanOptions, fm: FileManager) -> (ScanItem, [String: Data])? {
        var enriched = info
        var blobs: [String: Data] = [:]
        let path = url.path
        let filename = url.lastPathComponent
        let inside = isInsideBundle(path)
        let owning = owningBundle(path)

        // Heuristic enrichment ------------------------------------------------
        enriched.isApple = isApplePath(path)
        enriched.isCrossPlatformTool = WellKnownCrossPlatformTools.contains(filename.lowercased())

        // Look for a "usage:" line by reading the file head — cheap CLI signal.
        if info.kind == .executable, let usage = StringsExtractor.grepInBinary(url: url, needle: "usage:") {
            enriched.usageLine = usage
        } else if info.kind == .executable, let usage = StringsExtractor.grepInBinary(url: url, needle: "Usage:") {
            enriched.usageLine = usage
        }

        // Decide category. dylibs and frameworks-as-files go to "framework"
        // because users think of them together; bare bundles too.
        let category: ItemCategory
        switch info.kind {
        case .dylib, .bundle:
            category = .framework
        case .kext:
            category = .kext
        case .executable:
            category = inside ? .executable : .executable
        default:
            category = .other
        }

        // Roles --------------------------------------------------------------
        var roles: [ExecutableInfo.Role] = []
        if info.kind == .executable {
            if enriched.usageLine != nil { roles.append(.cli) }
            if path.contains("/libexec/") || path.contains("/PrivateFrameworks/") { roles.append(.helper) }
            if enriched.isCrossPlatformTool { roles.append(.interpreter) }
        } else if info.kind == .dylib {
            roles.append(.library)
        }
        enriched.roles = roles

        // Optional strings cache.
        if options.extractStrings && info.kind == .executable && size <= options.maxInspectFileSize {
            if let dump = StringsExtractor.extract(from: url, minLength: options.stringsMinLength) {
                let ref = "strings-" + Hash.sha256Hex(dump)
                blobs[ref] = dump
                enriched.stringsBlobRef = ref
            }
        }

        var tags: [String] = []
        switch info.kind {
        case .executable:    tags.append("executable")
        case .dylib:         tags.append("dylib")
        case .bundle:        tags.append("bundle")
        case .dylinker:      tags.append("dylinker")
        case .kext:          tags.append("kext")
        case .object:        tags.append("object")
        case .dsym:          tags.append("dsym")
        case .core:          tags.append("core")
        case .unknown:       tags.append("macho")
        }
        for arch in info.architectures { tags.append(arch) }
        if info.isFatBinary { tags.append("fat") }
        if enriched.isCrossPlatformTool { tags.append("cross-platform") }
        if enriched.isApple == false { tags.append("third-party") }
        if let platform = info.platform { tags.append(platform) }
        if enriched.usageLine != nil { tags.append("cli") }

        return (ScanItem(
            id: UUID(), path: path, name: filename, category: category,
            size: size, modifiedAt: mtime,
            sha256: options.hashFiles ? Hash.sha256(of: url) : nil,
            insideBundle: inside, owningBundlePath: owning,
            executable: enriched,
            tags: tags
        ), blobs)
    }

    // MARK: Heuristics

    private nonisolated func isMLModelExtension(_ ext: String) -> Bool {
        ["mlmodel", "mlpackage", "mlmodelc", "onnx", "tflite", "pt", "pth"].contains(ext)
    }

    private nonisolated func isIconExtension(_ ext: String) -> Bool {
        ["icns", "png", "jpg", "jpeg", "tiff", "heic", "car"].contains(ext)
    }

    private nonisolated func isManPagePath(_ path: String) -> Bool {
        path.contains("/share/man/man")
    }

    private nonisolated func isInsideBundle(_ path: String) -> Bool {
        path.contains(".app/") ||
            path.contains(".framework/") ||
            path.contains(".bundle/") ||
            path.contains(".kext/") ||
            path.contains(".mlpackage/") ||
            path.contains(".mlmodelc/")
    }

    /// Returns the closest enclosing `.app`/`.framework`/`.bundle`/`.kext`
    /// path, if any.
    private nonisolated func owningBundle(_ path: String) -> String? {
        for suffix in [".app", ".framework", ".bundle", ".kext", ".mlpackage", ".mlmodelc"] {
            if let range = path.range(of: "\(suffix)/") {
                let endIndex = range.upperBound
                // Backtrack to include the suffix itself, exclude the trailing slash.
                let bundleEnd = path.index(before: endIndex)
                return String(path[path.startIndex..<bundleEnd])
            }
        }
        return nil
    }

    private nonisolated func isApplePath(_ path: String) -> Bool {
        path.hasPrefix("/System/") ||
            path.hasPrefix("/usr/lib") ||
            path.hasPrefix("/usr/libexec") ||
            path.hasPrefix("/usr/sbin") ||
            (path.hasPrefix("/usr/bin/") && WellKnownAppleBinaries.contains((path as NSString).lastPathComponent))
    }

    private nonisolated func readShebang(_ url: URL) -> ScriptInfo? {
        guard let head = try? FileHandle(forReadingFrom: url).read(upToCount: 256), head.count >= 2 else { return nil }
        guard head[0] == 0x23, head[1] == 0x21 else { return nil } // "#!"
        // Find newline.
        guard let nl = head.firstIndex(of: 0x0A) else { return nil }
        let interp = String(data: head[2..<nl], encoding: .utf8)?.trimmingCharacters(in: .whitespaces)
        let language = languageFromInterpreter(interp ?? "")
        return ScriptInfo(interpreter: interp, language: language, lineCount: nil)
    }

    private nonisolated func languageFromInterpreter(_ line: String) -> String? {
        // Common forms:
        //   /bin/bash
        //   /usr/bin/env perl
        //   /usr/bin/python3 -u
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

    private nonisolated func normalizeLanguage(_ name: String) -> String? {
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

/// Names that we treat as "Apple-shipped" even when they live in /usr/bin
/// (Apple-signed tools that aren't easy to spot otherwise). Conservative — the
/// real test is the code signature; this is the cheap fallback.
nonisolated private let WellKnownAppleBinaries: Set<String> = [
    "diskutil", "tmutil", "csrutil", "softwareupdate", "pmset",
    "launchctl", "systemsetup", "asr", "dscl", "scutil",
    "codesign", "spctl", "stapler", "xattr", "xcrun", "xcode-select",
    "say", "open", "pbcopy", "pbpaste", "defaults",
    "log", "system_profiler", "ioreg", "kextstat", "vm_stat"
]

/// Well-known scripting language interpreters / cross-platform tools shipped
/// with the OS. Marked so a user looking for "non-Apple things in /usr/bin"
/// can find them quickly. Not exhaustive — easy to extend.
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
