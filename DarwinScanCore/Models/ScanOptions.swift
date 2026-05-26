import Foundation

/// User-configurable knobs for a scan. Defaults exclude user-state paths
/// (/Users, /Applications, /Library, /Volumes, /usr/local, /opt) so we only
/// touch material that would be present in an IPSW.
public nonisolated struct ScanOptions: Codable, Hashable, Sendable {
    /// Top-level roots to traverse.
    public var roots: [String] = [
        "/System",
        "/bin",
        "/sbin",
        "/usr"
    ]

    /// Path prefixes that are skipped during traversal.
    public var excludedPrefixes: [String] = [
        "/System/Volumes",
        "/usr/local",
        "/usr/spool",
        "/private/var/folders",
        "/private/tmp",
        "/private/var/tmp"
    ]

    public var followSymlinks: Bool = false
    public var hashFiles: Bool = true
    public var extractStrings: Bool = false
    public var stringsMinLength: Int = 6
    public var indexManPages: Bool = true
    public var inspectLocalizations: Bool = true
    /// When on, the walker skips non-English `.lproj` subtrees entirely and
    /// the classifier drops non-English `.strings` / `.stringsdict`. Treats
    /// `en`, `en_US`, `en_GB`, `en-US`, `en-GB`, and the cross-platform
    /// `Base.lproj` directory as English. Substantially shrinks scans of
    /// `/System/Library/CoreServices` and `/System/Applications` where
    /// hundreds of `.lproj` directories live.
    public var englishLocalizationsOnly: Bool = false
    public var inspectAppBundles: Bool = true
    public var inspectMLModels: Bool = true
    public var inspectDyldCache: Bool = true
    public var maxInspectFileSize: Int64 = 256 * 1024 * 1024

    /// When on, the raw bytes of every classified file are written into the
    /// content-addressed blob store and the resulting ref is recorded on the
    /// item (`ScanItem.fileBlobRef`). Lets `darwin-scan extract` rebuild a
    /// directory tree from a `.darwinscan` bundle.
    ///
    /// Defaults to **true** — the user-facing pitch of DarwinScan is "capture
    /// the system image", which is meaningless if the bytes aren't actually
    /// captured. Content-addressing deduplicates within the scan (and across
    /// snapshots in the same bundle), so the size cost is bounded by the
    /// distinct content visited.
    public var captureFiles: Bool = true

    /// Hard cap on the size of a file that `captureFiles` will pull into the
    /// blob store. Files above this are skipped (no ref is recorded).
    public var maxCaptureFileSize: Int64 = 256 * 1024 * 1024

    /// Extract symbols, Obj-C/Swift class names, and undefined imports from
    /// every Mach-O binary. Slows scans by ~30% on a /System but produces a
    /// fully searchable symbol index. On by default since the cost is small
    /// relative to the strings extractor.
    public var extractSymbols: Bool = true

    public init(
        roots: [String]? = nil,
        excludedPrefixes: [String]? = nil,
        followSymlinks: Bool = false,
        hashFiles: Bool = true,
        extractStrings: Bool = false,
        stringsMinLength: Int = 6,
        indexManPages: Bool = true,
        inspectLocalizations: Bool = true,
        englishLocalizationsOnly: Bool = false,
        inspectAppBundles: Bool = true,
        inspectMLModels: Bool = true,
        inspectDyldCache: Bool = true,
        maxInspectFileSize: Int64 = 256 * 1024 * 1024,
        captureFiles: Bool = true,
        maxCaptureFileSize: Int64 = 256 * 1024 * 1024,
        extractSymbols: Bool = true
    ) {
        if let roots { self.roots = roots }
        if let excludedPrefixes { self.excludedPrefixes = excludedPrefixes }
        self.followSymlinks = followSymlinks
        self.hashFiles = hashFiles
        self.extractStrings = extractStrings
        self.stringsMinLength = stringsMinLength
        self.indexManPages = indexManPages
        self.inspectLocalizations = inspectLocalizations
        self.englishLocalizationsOnly = englishLocalizationsOnly
        self.inspectAppBundles = inspectAppBundles
        self.inspectMLModels = inspectMLModels
        self.inspectDyldCache = inspectDyldCache
        self.maxInspectFileSize = maxInspectFileSize
        self.captureFiles = captureFiles
        self.maxCaptureFileSize = maxCaptureFileSize
        self.extractSymbols = extractSymbols
    }
}
