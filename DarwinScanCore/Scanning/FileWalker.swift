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
    public nonisolated func isExcluded(_ path: String) -> Bool {
        for prefix in options.excludedPrefixes {
            if path == prefix || path.hasPrefix(prefix + "/") {
                return true
            }
        }
        return false
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
            if isSymlink && !options.followSymlinks {
                // Still report the symlink itself — useful as evidence that, say,
                // `/etc -> /private/etc` exists — but don't descend.
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
