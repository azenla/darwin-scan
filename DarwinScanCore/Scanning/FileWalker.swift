import Foundation

/// Recursively yields `URL`s under each scan root, respecting excludes and
/// the symlink-follow option. Yields directories AND regular files — the
/// scanner decides which inspector applies.
///
/// The walker is `nonisolated` and safe to drive from a background actor.
/// We use `AsyncStream` so callers can iterate with `for await`.
public nonisolated struct FileWalker: Sendable {
    public let options: ScanOptions

    public init(options: ScanOptions) {
        self.options = options
    }

    /// True if `path` (or one of its prefix segments) is in the excludes list.
    ///
    /// The default excludes list contains `/System/Volumes` — that's where
    /// firmlinks point to user data — but the OS cryptex content lives at
    /// `/System/Volumes/Preboot/Cryptexes/`, exposed via firmlinks at
    /// `/System/Cryptexes/{OS,App,ExclaveOS}`. We carve out the cryptex
    /// preboot subtree unconditionally so the dyld_shared_cache et al. are
    /// scannable. Bug repro before this fix: `inspectDyldCache=true` but zero
    /// dyldCache items appeared in the manifest, because the walker yielded
    /// the symlink at `/System/Cryptexes/OS` without descending.
    public nonisolated func isExcluded(_ path: String) -> Bool {
        // `Incoming/` is a staging area for the next OS update — every file
        // under `Cryptexes/OS/` reappears at the same path under
        // `Cryptexes/Incoming/OS/` while an update is downloaded. The walker
        // would otherwise double-count every dyld_shared_cache image. We
        // carve it out *before* the broader cryptex carve-out below so the
        // permissive check can't override.
        if path == "/System/Volumes/Preboot/Cryptexes/Incoming"
            || path.hasPrefix("/System/Volumes/Preboot/Cryptexes/Incoming/") {
            return true
        }
        if path.hasPrefix("/System/Volumes/Preboot/Cryptexes/") || path == "/System/Volumes/Preboot/Cryptexes" {
            return false
        }
        for prefix in options.excludedPrefixes {
            if path == prefix || path.hasPrefix(prefix + "/") {
                return true
            }
        }
        if options.englishLocalizationsOnly && isNonEnglishLproj(path) {
            return true
        }
        return false
    }

    /// True when `path` is itself a non-English `.lproj` directory. We don't
    /// match `/path/foo.lproj/Strings/...` because we want the walker to
    /// prune the *subtree*, which happens naturally once we exclude the
    /// `.lproj` directory itself.
    private nonisolated func isNonEnglishLproj(_ path: String) -> Bool {
        let last = (path as NSString).lastPathComponent
        guard last.hasSuffix(".lproj") else { return false }
        let stem = String(last.dropLast(".lproj".count))
        return !Self.isEnglishLocale(stem)
    }

    /// Whether a locale code names English. Accepts the bare language code
    /// (`en`), region-tagged variants (`en_US`, `en-GB`), and the special
    /// `Base.lproj` directory Apple ships for nib/xib resources that aren't
    /// language-specific.
    public static func isEnglishLocale(_ code: String) -> Bool {
        if code == "Base" { return true }
        let lower = code.lowercased()
        if lower == "en" { return true }
        return lower.hasPrefix("en_") || lower.hasPrefix("en-")
    }

    /// Yields URLs. The returned stream completes when all roots have been
    /// fully walked or when the consumer cancels the task.
    public nonisolated func makeStream() -> AsyncStream<URL> {
        let walker = self
        return AsyncStream { continuation in
            Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                for root in walker.options.roots {
                    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDir) else { continue }
                    if !isDir.boolValue {
                        continuation.yield(rootURL)
                        continue
                    }
                    walker.walk(root: rootURL) { continuation.yield($0) }
                }
                continuation.finish()
            }
        }
    }

    /// Iterative pre-order traversal. We can't lean on
    /// `FileManager.enumerator` because we want to skip `/System/Volumes` *and*
    /// optionally skip symlinks, and pruning entire subtrees mid-enumeration
    /// is awkward with that API.
    private nonisolated func walk(root: URL, yield: @Sendable (URL) -> Void) {
        let fm = FileManager.default
        var stack: [URL] = [root]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isAliasFileKey]

        while let current = stack.popLast() {
            let path = current.path
            if isExcluded(path) { continue }

            guard let values = try? current.resourceValues(forKeys: keys) else { continue }
            let isSymlink = values.isSymbolicLink ?? false
            if isSymlink {
                // Cryptex firmlinks (`/System/Cryptexes/{OS,App,ExclaveOS}`)
                // are how the OS exposes the immutable cryptex partitions —
                // they look like symlinks but point at content that's part of
                // the system image. Always descend through them regardless of
                // `options.followSymlinks`, since they're the only way to
                // reach the dyld_shared_cache et al.
                let isCryptexLink = path == "/System/Cryptexes/OS"
                    || path == "/System/Cryptexes/App"
                    || path == "/System/Cryptexes/ExclaveOS"
                if isCryptexLink || options.followSymlinks {
                    let resolved = current.resolvingSymlinksInPath()
                    stack.append(resolved)
                    yield(current)
                    continue
                }
                // Plain old symlink — yield it as evidence but don't descend.
                yield(current)
                continue
            }

            let isDir = values.isDirectory ?? false
            yield(current)
            guard isDir else { continue }

            // We treat .app / .framework / .bundle / .kext / .mlpackage / .mlmodelc
            // as "first-class items" and *still* descend into them, because we
            // want to find the executable inside an .app or the metadata inside
            // an .mlmodelc. The inspectors mark items with `insideBundle = true`
            // so the UI can collapse them.
            let children: [URL]
            do {
                children = try fm.contentsOfDirectory(
                    at: current,
                    includingPropertiesForKeys: Array(keys),
                    options: []
                )
            } catch {
                continue
            }
            for child in children {
                stack.append(child)
            }
        }
    }
}
