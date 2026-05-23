import Foundation

/// User-configurable knobs for a scan. Defaults exclude user-state paths
/// (/Users, /Applications, /Library, /Volumes, /usr/local, /opt) so we only
/// touch material that would be present in an IPSW.
nonisolated struct ScanOptions: Codable, Hashable, Sendable {
    /// Top-level roots to traverse.
    var roots: [String] = [
        "/System",
        "/bin",
        "/sbin",
        "/usr"
    ]

    /// Path prefixes that are skipped during traversal. Order doesn't matter;
    /// any prefix match excludes the subtree.
    var excludedPrefixes: [String] = [
        "/System/Volumes",     // user data, network mounts, recovery snapshots
        "/usr/local",          // Homebrew / user-installed (Intel default)
        "/usr/spool",
        "/private/var/folders",
        "/private/tmp",
        "/private/var/tmp"
    ]

    /// When true, follow symbolic links. Default off — most useful symlinks in
    /// the system image are intra-volume and either point to things we'd hit
    /// anyway or out to user paths we want to avoid.
    var followSymlinks: Bool = false

    /// Hash every file's contents (SHA-256). Required for diff-against-prior-
    /// scan; cheap on Apple Silicon thanks to CommonCrypto, but a full /System
    /// scan still adds tens of seconds. Toggle off for fast structural scans.
    var hashFiles: Bool = true

    /// When true, run `/usr/bin/strings` on every Mach-O executable and store
    /// the output as a blob inside the bundle. Massively increases scan time
    /// and bundle size; turn on only when you want to search across binary
    /// strings later.
    var extractStrings: Bool = false

    /// When extracting strings, ignore strings shorter than this. Matches the
    /// `strings -n N` flag.
    var stringsMinLength: Int = 6

    /// Render man pages to a stored HTML/plain form during scanning. Cheap.
    var indexManPages: Bool = true

    /// Parse plist localizations to count keys.
    var inspectLocalizations: Bool = true

    /// Inspect .app bundle Info.plists and try to extract their app icons.
    var inspectAppBundles: Bool = true

    /// Inspect ML models for metadata (descriptions, IO shapes, labels).
    var inspectMLModels: Bool = true

    /// Inspect dyld_shared_cache_* file headers (does not extract images).
    var inspectDyldCache: Bool = true

    /// Maximum file size to fully read for content-based inspections (Mach-O
    /// parsing reads ~2-32KB regardless; this guards strings extraction).
    var maxInspectFileSize: Int64 = 256 * 1024 * 1024
}
