import Foundation
import Observation
import CryptoKit
import os.lock

/// Disk-backed content-addressed payload store. Three reasons this exists as
/// its own type (rather than a `[String: Data]` on `ScanStore`):
///
/// 1. **Memory** — a /System scan with `extractStrings = true` can produce
///    hundreds of MB of payload bytes. Keeping it all on the heap stalls the
///    UI and creates frequent GC-like pauses.
/// 2. **Parallelism** — the background scan workers write blobs concurrently.
///    Passing `Data` across actor boundaries copies bytes; passing a ref
///    string is free.
/// 3. **Save time** — historically `FileWrapper(url:)` streamed bytes from a
///    session cache directory into the bundle on save. The store now writes
///    directly into the open bundle's `blobs/<prefix>/<ref>.bin` sharded
///    layout, so there is no save-time copy: every byte lands in its final
///    home as the scanner produces it.
///
/// **Sharded on-disk layout.** Blobs live at
/// `<rootDirectory>/<2-char-prefix>/<ref>.bin`, matching the saved bundle
/// format described in `ScanPackage`. The prefix is the first two characters
/// of the hash part of the ref (after any `hint-` prefix, e.g. for
/// `icon-3a4f…` the prefix is `3a`).
///
/// **Isolation.** Because the open-bundle flow runs the scanner straight into
/// the bundle directory (no per-session cache copy), and SwiftUI's old
/// `ReferenceFileDocument` machinery already invoked save paths from
/// background threads, this type is explicitly `nonisolated`. Mutations to
/// `refs` are funnelled through the scanner's MainActor `batchSink` and
/// through `ScanPackage.openInPlace` at load time — there is no concurrent
/// writer to `refs` itself. Concurrent writes from inspector tasks land in
/// distinct content-addressed paths and are safe on APFS.
@Observable
public nonisolated final class BlobStore: @unchecked Sendable {
    /// Every ref we know about. The bytes live at `blobURL(forRef:)`.
    public private(set) var refs: Set<String> = []

    /// Guards mutations of `refs`. The analysis worker now registers blob refs
    /// (extracted icons/previews) from many concurrent tasks, so the `Set`
    /// insert must be serialized — a concurrently-mutated Swift Set is
    /// undefined behavior, not just a lost write.
    private var refsLock = os_unfair_lock_s()

    /// Root of the sharded blob layout — typically `<bundle>/blobs/` for an
    /// open document, or any temp directory in tests.
    public let rootDirectory: URL

    /// Back-compat alias. Older code (and CLAUDE.md) referred to this as
    /// `cacheDirectory`; the store now writes directly into the bundle's
    /// `blobs/` directory, but the symbol stayed identical so call sites
    /// continue to compile.
    public var cacheDirectory: URL { rootDirectory }

    /// Create a fresh BlobStore that owns the given directory. Pass the
    /// bundle's `blobs/` subdirectory for normal operation; tests can pass a
    /// per-test temp dir. The directory is created if it doesn't exist.
    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        try? FileManager.default.createDirectory(
            at: rootDirectory, withIntermediateDirectories: true
        )
    }

    /// Produce a `BlobWriter` that worker tasks can use to write blobs
    /// concurrently. Writes go to distinct content-addressed paths under
    /// the same sharded layout, so they don't collide on APFS.
    public func makeWriter() -> BlobWriter {
        BlobWriter(rootDirectory: rootDirectory)
    }

    /// Register a ref the worker just wrote to disk. Idempotent. Thread-safe.
    public func register(ref: String) {
        os_unfair_lock_lock(&refsLock); defer { os_unfair_lock_unlock(&refsLock) }
        refs.insert(ref)
    }

    public func registerMany(_ refs: [String]) {
        os_unfair_lock_lock(&refsLock); defer { os_unfair_lock_unlock(&refsLock) }
        for ref in refs { self.refs.insert(ref) }
    }

    /// Read the bytes for a blob ref. Returns nil if the ref isn't known or
    /// the file is missing.
    public func data(forRef ref: String) -> Data? {
        try? Data(contentsOf: blobURL(forRef: ref))
    }

    /// Path inside the sharded blob layout for a given ref.
    public func blobURL(forRef ref: String) -> URL {
        let prefix = Self.shardPrefix(forRef: ref)
        return rootDirectory
            .appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent("\(ref).bin")
    }

    /// Discover blob refs already on disk under `rootDirectory` and register
    /// them. Called by `ScanPackage.openInPlace` after attaching the existing
    /// bundle, so the in-memory `refs` set mirrors the bundle's contents
    /// without a copy step.
    public func scanForExistingBlobs() {
        let fm = FileManager.default
        guard let prefixes = try? fm.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        // Collect off-lock (directory I/O is slow), then insert in one locked
        // pass via registerMany.
        var found: [String] = []
        for prefixURL in prefixes {
            let isDir = (try? prefixURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            guard let files = try? fm.contentsOfDirectory(at: prefixURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for fileURL in files {
                let name = fileURL.lastPathComponent
                guard name.hasSuffix(".bin") else { continue }
                found.append(String(name.dropLast(4)))
            }
        }
        registerMany(found)
    }

    /// First two characters of the hash part of a ref. Refs are either
    /// `<ref>` (a plain sha256) or `<hint>-<sha256>` (e.g. `icon-3a4f…`).
    /// We shard on the hash side so a single hint doesn't make one bucket
    /// huge.
    public static func shardPrefix(forRef ref: String) -> String {
        if let dash = ref.firstIndex(of: "-") {
            let after = ref.index(after: dash)
            return String(ref[after...].prefix(2))
        }
        return String(ref.prefix(2))
    }
}

/// Worker-side writer. Sendable because it carries only a directory URL —
/// concurrent writes to distinct files in the same dir are safe on APFS.
public nonisolated struct BlobWriter: Sendable {
    public let rootDirectory: URL

    /// Back-compat alias; older code grabbed `writer.directory`.
    public var directory: URL { rootDirectory }

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// Write `data` under the given ref into the sharded layout. Idempotent:
    /// if the file already exists at the same size we skip the write to
    /// avoid touching atime / mtime.
    public func write(_ data: Data, ref: String) {
        let url = ensureShardURL(forRef: ref)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let attrs, (attrs[.size] as? Int) == data.count {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    /// Copy `source` into the blob layout as `<prefix>/<ref>.bin` using
    /// FileManager — the byte stream stays in the kernel rather than passing
    /// through Foundation Data, so capturing a 200 MB Mach-O is constant-
    /// memory for the scanner. Idempotent: if a file with the same ref and
    /// size already exists, the copy is skipped (typical for content-
    /// addressed dedup across identical binaries).
    public func copy(from source: URL, ref: String) {
        let dst = ensureShardURL(forRef: ref)
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: dst.path),
           let dstSize = attrs[.size] as? Int,
           let srcAttrs = try? fm.attributesOfItem(atPath: source.path),
           let srcSize = srcAttrs[.size] as? Int,
           srcSize == dstSize {
            return
        }
        if fm.fileExists(atPath: dst.path) {
            try? fm.removeItem(at: dst)
        }
        try? fm.copyItem(at: source, to: dst)
    }

    /// Read `source` exactly once, computing its SHA-256 while streaming the
    /// bytes into the content-addressed blob layout. Returns `(sha, ref)` on
    /// success — the blob is written as `\(refPrefix)\(sha)` — or nil if the
    /// source can't be read.
    ///
    /// This replaces the old two-pass import flow (`Hash.sha256(of:)` to get
    /// the digest, then `copy(from:ref:)` to capture the bytes), which read
    /// every imported file from disk *twice*. For a /System walk — hundreds of
    /// thousands of files including multi-hundred-MB Mach-Os — that halves the
    /// dominant import cost.
    ///
    /// Content-addressed dedup is preserved: once the digest (and thus the
    /// destination) is known, an already-present blob means identical bytes,
    /// so the temp is discarded rather than rewritten. Safe under the import
    /// worker's concurrent task group — the temp name is unique per call and a
    /// lost move race (two files, same content) is treated as a dedup hit.
    public func captureHashing(
        from source: URL,
        refPrefix: String = "file-",
        chunkSize: Int = 1 << 20
    ) -> (sha: String, ref: String)? {
        let fm = FileManager.default
        guard let inHandle = try? FileHandle(forReadingFrom: source) else { return nil }
        defer { try? inHandle.close() }

        let tempURL = rootDirectory.appendingPathComponent(".capture-\(UUID().uuidString).tmp")
        try? fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        fm.createFile(atPath: tempURL.path, contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: tempURL) else {
            try? fm.removeItem(at: tempURL)
            return nil
        }

        var hasher = SHA256()
        var ok = true
        while true {
            let chunk: Data
            do {
                guard let c = try inHandle.read(upToCount: chunkSize), !c.isEmpty else { break }
                chunk = c
            } catch { ok = false; break }
            hasher.update(data: chunk)
            do { try outHandle.write(contentsOf: chunk) } catch { ok = false; break }
        }
        try? outHandle.close()

        guard ok else {
            try? fm.removeItem(at: tempURL)
            return nil
        }

        let sha = hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
        let ref = "\(refPrefix)\(sha)"
        let dst = ensureShardURL(forRef: ref)

        if fm.fileExists(atPath: dst.path) {
            try? fm.removeItem(at: tempURL)
            return (sha, ref)
        }
        do {
            try fm.moveItem(at: tempURL, to: dst)
        } catch {
            // Most likely another worker just wrote the same content (the ref
            // is the hash, so the bytes are identical). Treat a present dst as
            // success; otherwise the capture genuinely failed.
            try? fm.removeItem(at: tempURL)
            guard fm.fileExists(atPath: dst.path) else { return nil }
        }
        return (sha, ref)
    }

    /// Sharded destination URL for a ref, with the prefix directory created
    /// on demand. Cheap to call repeatedly — `createDirectory(withIntermediate…)`
    /// is a no-op when the dir exists.
    private func ensureShardURL(forRef ref: String) -> URL {
        let prefix = BlobStore.shardPrefix(forRef: ref)
        let prefixURL = rootDirectory.appendingPathComponent(prefix, isDirectory: true)
        try? FileManager.default.createDirectory(at: prefixURL, withIntermediateDirectories: true)
        return prefixURL.appendingPathComponent("\(ref).bin")
    }
}
