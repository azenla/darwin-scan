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
    public var inspectAppBundles: Bool = true
    public var inspectMLModels: Bool = true
    public var inspectDyldCache: Bool = true
    public var maxInspectFileSize: Int64 = 256 * 1024 * 1024

    public init(
        roots: [String]? = nil,
        excludedPrefixes: [String]? = nil,
        followSymlinks: Bool = false,
        hashFiles: Bool = true,
        extractStrings: Bool = false,
        stringsMinLength: Int = 6,
        indexManPages: Bool = true,
        inspectLocalizations: Bool = true,
        inspectAppBundles: Bool = true,
        inspectMLModels: Bool = true,
        inspectDyldCache: Bool = true,
        maxInspectFileSize: Int64 = 256 * 1024 * 1024
    ) {
        if let roots { self.roots = roots }
        if let excludedPrefixes { self.excludedPrefixes = excludedPrefixes }
        self.followSymlinks = followSymlinks
        self.hashFiles = hashFiles
        self.extractStrings = extractStrings
        self.stringsMinLength = stringsMinLength
        self.indexManPages = indexManPages
        self.inspectLocalizations = inspectLocalizations
        self.inspectAppBundles = inspectAppBundles
        self.inspectMLModels = inspectMLModels
        self.inspectDyldCache = inspectDyldCache
        self.maxInspectFileSize = maxInspectFileSize
    }
}
