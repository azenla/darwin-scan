import Foundation

/// "Where do files come from for an import?" Abstraction over a live macOS
/// root (`/System`, `/bin`, …) versus a mounted IPSW image.
public nonisolated protocol SourceProvider: Sendable {
    var sourceKind: SnapshotSourceKind { get }
    var sourceRef: String { get }
    var snapshotLabel: String? { get }
    var systemInfo: SystemInfo? { get }
    var roots: [URL] { get }
    var excludedPrefixes: [String] { get }
    func canonicalPath(for url: URL) -> String
    /// Human-facing path for progress UI. Defaults to `canonicalPath`; the
    /// IPSW source prefixes the mounted volume name so the user can tell
    /// which disk image a file came from ("Macintosh HD 1 → /System/…").
    func displayPath(for url: URL) -> String
    func cleanup()
}

public extension SourceProvider {
    nonisolated func displayPath(for url: URL) -> String { canonicalPath(for: url) }
}

// MARK: - Current system

public nonisolated struct CurrentSystemSource: SourceProvider {
    public let sourceKind: SnapshotSourceKind = .currentSystem
    public let sourceRef: String
    public let snapshotLabel: String?
    public let systemInfo: SystemInfo?
    public let roots: [URL]
    public let excludedPrefixes: [String]

    public init(options: ScanOptions, captureInfo: SystemInfo? = nil) {
        let info = captureInfo ?? SystemInfoCollector.capture()
        self.systemInfo = info
        let host = ProcessInfo.processInfo.hostName
        let version = info.productVersion ?? "macOS"
        let build = info.productBuildVersion.map { " (\($0))" } ?? ""
        self.sourceRef = "\(host) — \(version)\(build)"
        let dateLabel = darwinscanSnapshotLabelFormatter.string(from: Date())
        self.snapshotLabel = "Current System · \(dateLabel)"
        self.roots = options.roots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.excludedPrefixes = options.excludedPrefixes
    }

    public func canonicalPath(for url: URL) -> String { url.path }
    public func cleanup() {}
}

// MARK: - IPSW

/// Imports from an Apple `.ipsw`. Modern macOS IPSWs ship cryptex DMGs as
/// AEA-encrypted blobs whose keys live on Apple's Pallas signing service.
///
/// We use a two-step lifecycle so the heavy work (unzip + Pallas key fetch +
/// AEA decrypt + hdiutil attach) doesn't block the UI:
///
/// 1. `IPSWSource.prepare(ipswURL:...)` — async; returns a fully prepared
///    source after extraction + decryption + mounting. Surfaces progress
///    via a callback.
/// 2. Use the returned source like any other `SourceProvider`.
///
/// `cleanup()` detaches every mountpoint and removes the extraction dir.
/// Called by the importer when the import finishes or fails.
///
/// ## Key fetch
///
/// `aea` (the system tool) cannot fetch keys from Apple's servers on its
/// own. We delegate to `/opt/homebrew/bin/ipsw` (or `/usr/local/bin/ipsw`)
/// via `ipsw fw aea -k <file>` when available — that command implements
/// the Pallas protocol Apple uses for AEA FCS keys. Without the helper, the
/// import still proceeds for plain (non-AEA) DMGs and the user can supply
/// keys manually via the `aeaKeys` override.
public nonisolated final class IPSWSource: SourceProvider, @unchecked Sendable {
    public let sourceKind: SnapshotSourceKind = .ipsw
    public private(set) var sourceRef: String
    public private(set) var snapshotLabel: String?
    public private(set) var systemInfo: SystemInfo?
    public private(set) var roots: [URL] = []
    public let excludedPrefixes: [String]

    private let extractionRoot: URL
    private var mountedVolumes: [String] = []   // /Volumes/<name> paths
    /// AEA files we decrypted into `.dmg` — kept here so we can delete them
    /// on cleanup (they're materialised into the extraction dir).
    private var decryptedDMGs: [URL] = []
    /// Warnings collected during prepare so the CLI/UI can surface them.
    public private(set) var diagnostics: [String] = []

    public enum IPSWError: Error, CustomStringConvertible {
        case extractFailed(String)
        case noMountableImage(String)
        case mountFailed(URL, String)
        case missingHelper

        public var description: String {
            switch self {
            case .extractFailed(let m):    return "IPSW: extract failed — \(m)"
            case .noMountableImage(let m): return "IPSW: no mountable image — \(m)"
            case .mountFailed(let u, let m): return "IPSW: failed to mount \(u.lastPathComponent) — \(m)"
            case .missingHelper:           return "IPSW: AEA-encrypted DMGs need the `ipsw` helper. Install via `brew install blacktop/tap/ipsw`, or pre-supply decryption keys."
            }
        }
    }

    // MARK: - Async prepare

    /// Async constructor. Performs every long-running step on a background
    /// task so the caller's actor (typically MainActor) stays responsive.
    /// `progress` is invoked with one human-readable line per major step.
    /// `aeaKeys` is an optional map `archive-filename → base64-key` for
    /// callers that already have keys; missing entries fall back to the
    /// `ipsw fw aea -k` helper.
    public static func prepare(
        ipswURL: URL,
        options: ScanOptions,
        aeaKeys: [String: String] = [:],
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> IPSWSource {
        // Heavy work is plain sync (Process / hdiutil), so a Task.detached
        // is enough to keep MainActor free.
        return try await Task.detached(priority: .userInitiated) {
            try IPSWSource(syncPreparing: ipswURL, options: options, aeaKeys: aeaKeys, progress: progress)
        }.value
    }

    /// Synchronous initializer for non-UI consumers (CLI) where we already
    /// run on a background task.
    public convenience init(
        ipswURL: URL,
        options: ScanOptions,
        aeaKeys: [String: String] = [:],
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        try self.init(syncPreparing: ipswURL, options: options, aeaKeys: aeaKeys, progress: progress)
    }

    private init(
        syncPreparing ipswURL: URL,
        options: ScanOptions,
        aeaKeys: [String: String],
        progress: @escaping @Sendable (String) -> Void
    ) throws {
        self.excludedPrefixes = options.excludedPrefixes
        self.sourceRef = ipswURL.lastPathComponent
        self.snapshotLabel = "IPSW · \(ipswURL.deletingPathExtension().lastPathComponent)"
        self.extractionRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("darwinscan-ipsw-\(UUID().uuidString)", isDirectory: true)

        progress("Extracting IPSW…")
        try Self.extract(ipswURL: ipswURL, into: extractionRoot)
        progress("Reading BuildManifest…")
        readBuildManifest()

        progress("Locating disk images…")
        let dmgs = (try? Self.enumerateFiles(under: extractionRoot, withExtension: "dmg")) ?? []
        let aeas = (try? Self.enumerateFiles(under: extractionRoot, withExtension: "aea")) ?? []
        if dmgs.isEmpty && aeas.isEmpty {
            throw IPSWError.noMountableImage("no .dmg or .aea inside IPSW")
        }

        let helper = Self.locateIPSWHelper()

        // Step 1: decrypt every AEA to a sibling .dmg.
        for aea in aeas {
            progress("Decrypting \(aea.lastPathComponent)…")
            let dmg = aea.deletingPathExtension() // strips ".aea" -> "<name>.dmg"
            do {
                if let explicit = aeaKeys[aea.lastPathComponent] {
                    try Self.aeaDecrypt(input: aea, output: dmg, keyValue: explicit)
                } else if let helper {
                    progress("  → fetching FCS key from Apple…")
                    let key = try Self.fetchAEAKey(using: helper, archive: aea)
                    try Self.aeaDecrypt(input: aea, output: dmg, keyValue: key)
                } else {
                    diagnostics.append("Skipping \(aea.lastPathComponent): no AEA key (install blacktop/tap/ipsw or supply --aea-key).")
                    continue
                }
                decryptedDMGs.append(dmg)
            } catch {
                diagnostics.append("Skipping \(aea.lastPathComponent): \(error)")
            }
        }

        // Step 2: mount everything that looks like a DMG.
        let allDMGs = dmgs + decryptedDMGs
        for dmg in allDMGs {
            progress("Mounting \(dmg.lastPathComponent)…")
            do {
                let mounts = try Self.mountDMG(dmg)
                mountedVolumes.append(contentsOf: mounts.map(\.path))
            } catch {
                diagnostics.append("Skipping \(dmg.lastPathComponent): \(error)")
            }
        }
        if mountedVolumes.isEmpty {
            throw IPSWError.noMountableImage("nothing in the IPSW could be mounted (see diagnostics)")
        }

        progress("Picking scan roots…")
        populateScanRoots(options: options)
    }

    deinit { cleanupInternal() }
    public func cleanup() { cleanupInternal() }

    private func cleanupInternal() {
        let mounts = mountedVolumes
        mountedVolumes.removeAll()
        for path in mounts { Self.detach(mountPath: path) }
        // Decrypted DMGs are inside extractionRoot; the rmdir below covers them.
        try? FileManager.default.removeItem(at: extractionRoot)
    }

    public func canonicalPath(for url: URL) -> String {
        let urlPath = url.path
        // Each scan root is `<mountpoint>/<subroot>` (e.g.
        // `/Volumes/AppCryptex/System`). The mountpoint is the parent of
        // the root; we strip that prefix so the recorded path looks
        // canonical (`/System/Applications/...`).
        for root in roots {
            let rootPath = root.path
            let mountpoint = (rootPath as NSString).deletingLastPathComponent
            if urlPath == rootPath {
                return "/" + root.lastPathComponent
            }
            if !mountpoint.isEmpty, urlPath.hasPrefix(mountpoint + "/") {
                return String(urlPath.dropFirst(mountpoint.count))
            }
        }
        return urlPath
    }

    /// "<mounted volume> → <canonical path>", e.g.
    /// "Macintosh HD 1 → /System/Library/…". The raw mounted path
    /// (`/Volumes/Macintosh HD 1/System/…`) hides which image a file is from
    /// and buries the meaningful suffix; this surfaces both.
    public func displayPath(for url: URL) -> String {
        let urlPath = url.path
        for root in roots {
            let mountpoint = (root.path as NSString).deletingLastPathComponent
            guard !mountpoint.isEmpty,
                  urlPath == root.path || urlPath.hasPrefix(mountpoint + "/") else { continue }
            let volume = (mountpoint as NSString).lastPathComponent
            let canonical = canonicalPath(for: url)
            return volume.isEmpty ? canonical : "\(volume) → \(canonical)"
        }
        return canonicalPath(for: url)
    }

    // MARK: - Scan-root discovery

    private func populateScanRoots(options: ScanOptions) {
        let fm = FileManager.default
        var found: [URL] = []
        // For each requested option root (e.g. `/System`), look for it
        // inside every mounted volume and emit the matching subtree.
        for volume in mountedVolumes {
            let volumeURL = URL(fileURLWithPath: volume, isDirectory: true)
            for relative in options.roots {
                let trimmed = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
                let candidate = volumeURL.appendingPathComponent(trimmed, isDirectory: true)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                    found.append(candidate)
                }
            }
        }
        // If none of the requested roots exist on any mountpoint, fall back
        // to the mountpoints themselves so the cryptex images that don't
        // start with `/System` still get walked.
        if found.isEmpty {
            found = mountedVolumes.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        roots = found
    }

    // MARK: - BuildManifest

    private func readBuildManifest() {
        let fm = FileManager.default
        let manifest = extractionRoot.appendingPathComponent("BuildManifest.plist")
        guard fm.fileExists(atPath: manifest.path),
              let data = try? Data(contentsOf: manifest),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return
        }
        var info = SystemInfo(productName: "macOS")
        if let product = plist["ProductVersion"] as? String { info.productVersion = product }
        if let build = plist["ProductBuildVersion"] as? String { info.productBuildVersion = build }
        if let train = plist["Train"] as? String { info.buildTrain = train }
        // SupportedProductTypes is a list of Mac model identifiers
        // (`Mac15,11`, …). Earlier versions of this code mistakenly stored
        // it into `architectures`, which led to the System Info pane
        // listing 50+ "architectures." Architectures are now derived from
        // the BuildIdentity chip IDs (Apple Silicon → arm64); the model
        // list rides in its own field.
        if let supported = plist["SupportedProductTypes"] as? [String], !supported.isEmpty {
            info.supportedProductTypes = supported
        }
        info.architectures = Self.architectures(fromBuildManifest: plist)
        if let v = info.productVersion, let b = info.productBuildVersion {
            sourceRef = "macOS \(v) (\(b))"
        } else if let v = info.productVersion {
            sourceRef = "macOS \(v) IPSW"
        }
        systemInfo = info
    }

    /// Pull CPU architectures from BuildIdentities. Apple Silicon Mac chips
    /// (`ApChipID` ≥ 0x8000) imply arm64; legacy Intel manifests would
    /// imply x86_64. Today's Universal Mac IPSWs are arm64-only, but the
    /// per-identity walk keeps us honest for future formats.
    private static func architectures(fromBuildManifest plist: [String: Any]) -> [String] {
        guard let identities = plist["BuildIdentities"] as? [[String: Any]] else {
            return ["arm64"]
        }
        var archs: Set<String> = []
        for identity in identities {
            if let chipIDStr = identity["ApChipID"] as? String {
                let stripped = chipIDStr.hasPrefix("0x") ? String(chipIDStr.dropFirst(2)) : chipIDStr
                if let chipID = Int(stripped, radix: 16) {
                    archs.insert(chipID >= 0x8000 ? "arm64" : "x86_64")
                }
            } else if let chipIDInt = identity["ApChipID"] as? Int {
                archs.insert(chipIDInt >= 0x8000 ? "arm64" : "x86_64")
            }
        }
        return archs.isEmpty ? ["arm64"] : Array(archs).sorted()
    }

    // MARK: - Process helpers

    private static func extract(ipswURL: URL, into destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", ipswURL.path, destination.path]
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let data = (try? err.fileHandleForReading.readToEnd()) ?? Data()
            let msg = String(data: data, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
            throw IPSWError.extractFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func enumerateFiles(under root: URL, withExtension ext: String) throws -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == ext.lowercased() {
                results.append(url)
            }
        }
        return results
    }

    /// Mount a DMG using hdiutil. We deliberately don't pass `-mountpoint`
    /// because multi-volume images (every macOS cryptex DMG) fail with
    /// "Mountpoint cannot be specified for multi-fs images". Instead we
    /// parse the `-plist` output and collect every `mount-point` returned.
    private static func mountDMG(_ dmgURL: URL) throws -> [URL] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["attach", dmgURL.path, "-nobrowse", "-readonly", "-noverify", "-noautoopen", "-plist"]
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        let outData = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        if proc.terminationStatus != 0 {
            let errData = (try? err.fileHandleForReading.readToEnd()) ?? Data()
            let msg = String(data: errData, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
            throw IPSWError.mountFailed(dmgURL, msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: outData, options: [], format: nil) as? [String: Any],
              let systemEntities = plist["system-entities"] as? [[String: Any]] else {
            throw IPSWError.mountFailed(dmgURL, "couldn't parse hdiutil plist output")
        }
        var mounts: [URL] = []
        for entity in systemEntities {
            if let mp = entity["mount-point"] as? String, !mp.isEmpty {
                mounts.append(URL(fileURLWithPath: mp, isDirectory: true))
            }
        }
        if mounts.isEmpty {
            throw IPSWError.mountFailed(dmgURL, "no mountable partitions")
        }
        return mounts
    }

    private static func detach(mountPath: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["detach", mountPath, "-force"]
        proc.standardError = Pipe()
        proc.standardOutput = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }

    /// AEA decrypt with an explicit base64 key (or `base64:<...>` payload
    /// produced by `ipsw fw aea -k`).
    private static func aeaDecrypt(input: URL, output: URL, keyValue rawKey: String) throws {
        let key = rawKey.hasPrefix("base64:") ? rawKey : "base64:" + rawKey.replacingOccurrences(of: "base64:", with: "")
        try? FileManager.default.removeItem(at: output)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/aea")
        proc.arguments = ["decrypt", "-i", input.path, "-o", output.path, "-key-value", key]
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let data = (try? err.fileHandleForReading.readToEnd()) ?? Data()
            let msg = String(data: data, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
            throw IPSWError.extractFailed("aea decrypt: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Find the `ipsw` helper (blacktop/ipsw) on PATH. Used for AEA FCS
    /// key fetching since the system `aea` tool can't talk to Pallas.
    private static func locateIPSWHelper() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/ipsw",
            "/usr/local/bin/ipsw",
            "/opt/local/bin/ipsw"
        ]
        let fm = FileManager.default
        for c in candidates where fm.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        // Try $PATH search as a fallback.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let p = String(dir) + "/ipsw"
                if fm.isExecutableFile(atPath: p) {
                    return URL(fileURLWithPath: p)
                }
            }
        }
        return nil
    }

    /// `ipsw fw aea -k <file>` prints `base64:<...>` on stdout. We capture
    /// that and pass it to `aea decrypt -key-value`.
    private static func fetchAEAKey(using helper: URL, archive: URL) throws -> String {
        let proc = Process()
        proc.executableURL = helper
        proc.arguments = ["fw", "aea", "-k", archive.path]
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        let outData = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        let text = String(data: outData, encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            let errData = (try? err.fileHandleForReading.readToEnd()) ?? Data()
            let msg = String(data: errData, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
            throw IPSWError.extractFailed("ipsw fw aea -k: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        // Output is sometimes multi-line; pluck the first base64:* token.
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("base64:") {
                return trimmed
            }
        }
        throw IPSWError.extractFailed("ipsw fw aea -k didn't print a base64 key (got: \(text.prefix(120)))")
    }
}

nonisolated let darwinscanSnapshotLabelFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
}()
