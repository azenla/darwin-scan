import Foundation
import Observation

/// Disk-backed content-addressed payload store. Three reasons this exists as
/// its own type (rather than a `[String: Data]` on `ScanStore`):
///
/// 1. **Memory** — a /System scan with `extractStrings = true` can produce
///    hundreds of MB of payload bytes. Keeping it all on the heap stalls the
///    UI and creates frequent GC-like pauses.
/// 2. **Parallelism** — the background scan workers write blobs concurrently.
///    Passing `Data` across actor boundaries copies bytes; passing a ref
///    string is free.
/// 3. **Save time** — when the document is saved, `FileWrapper(url:)` reads
///    bytes from disk lazily, so we don't materialize everything just to
///    serialize.
///
/// Blobs always live on disk at `~/Library/Caches/io.zenla.DarwinScan/
/// <session>/<ref>.bin`. Freshly-scanned blobs land there via `BlobWriter`;
/// blobs read out of a loaded `.darwinscan` bundle are streamed into the same
/// directory by `ScanPackage.load`. Because SwiftUI's `ReferenceFileDocument`
/// machinery now invokes `newDocument` / `init(configuration:)` / `snapshot`
/// from background threads, this type is explicitly `nonisolated` (overriding
/// the project default of MainActor). Mutations to `refs` are funnelled
/// through the scanner's MainActor `batchSink` and through `ScanPackage.load`
/// on the document-init thread — there is no concurrent writer.
@Observable
public nonisolated final class BlobStore {
    /// Every ref we know about. The bytes live at `blobURL(forRef:)`.
    public private(set) var refs: Set<String> = []

    /// Where blobs live on disk. Created on init; cleaned up on deinit.
    public let cacheDirectory: URL

    public init() {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let session = "session-\(UUID().uuidString)"
        cacheDirectory = base
            .appendingPathComponent("io.zenla.DarwinScan", isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true
        )
    }

    deinit {
        // Best-effort cleanup. If anything is still readable from us through
        // FileWrapper after a save, it's been copied into the package by then.
        let dir = cacheDirectory
        try? FileManager.default.removeItem(at: dir)
    }

    /// Produce a `BlobWriter` that worker tasks can use to write blobs
    /// concurrently. Writes go to distinct content-addressed paths so they
    /// don't collide on APFS.
    public func makeWriter() -> BlobWriter {
        BlobWriter(directory: cacheDirectory)
    }

    /// Register a ref the worker just wrote to disk. Idempotent.
    public func register(ref: String) {
        refs.insert(ref)
    }

    public func registerMany(_ refs: [String]) {
        for ref in refs { self.refs.insert(ref) }
    }

    /// Read the bytes for a blob ref. Returns nil if the ref isn't known.
    /// Called from the UI when rendering icons / strings dumps.
    public func data(forRef ref: String) -> Data? {
        try? Data(contentsOf: blobURL(forRef: ref))
    }

    /// Build the directory FileWrapper subtree for inclusion in the saved
    /// document. We use `FileWrapper(url:)` so Foundation can stream bytes
    /// from disk into the destination rather than materializing everything.
    public func makeFileWrappersForSave() -> [String: [String: FileWrapper]] {
        var bucketed: [String: [String: FileWrapper]] = [:]
        for ref in refs {
            let prefix = String(blobHashPart(ref).prefix(2))
            let filename = "\(ref).bin"
            let url = blobURL(forRef: ref)
            guard let wrapper = try? FileWrapper(url: url, options: [.immediate]) else { continue }
            wrapper.preferredFilename = filename
            bucketed[prefix, default: [:]][filename] = wrapper
        }
        return bucketed
    }

    /// Path inside the cache directory for a given ref. Public so the
    /// `BlobWriter` and tests can introspect.
    public func blobURL(forRef ref: String) -> URL {
        cacheDirectory.appendingPathComponent("\(ref).bin")
    }

    /// Strip optional "hint-" prefix to expose the raw hash for sharding.
    private func blobHashPart(_ ref: String) -> String {
        if let dash = ref.firstIndex(of: "-") {
            return String(ref[ref.index(after: dash)...])
        }
        return ref
    }
}

/// Worker-side writer. Sendable because it carries only a directory URL —
/// concurrent writes to distinct files in the same dir are safe on APFS.
public nonisolated struct BlobWriter: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Write `data` under the given ref. Idempotent: if the file exists with
    /// matching size we skip the write to avoid touching atime / mtime.
    public func write(_ data: Data, ref: String) {
        let url = directory.appendingPathComponent("\(ref).bin")
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let attrs, (attrs[.size] as? Int) == data.count {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    /// Copy `source` into the blob directory as `<ref>.bin` using
    /// FileManager — the byte stream stays in the kernel rather than passing
    /// through Foundation Data, so capturing a 200 MB Mach-O is constant-
    /// memory for the scanner. Idempotent: if a file with the same ref and
    /// size already exists, the copy is skipped (typical for content-
    /// addressed dedup across identical binaries).
    public func copy(from source: URL, ref: String) {
        let dst = directory.appendingPathComponent("\(ref).bin")
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: dst.path),
           let dstSize = attrs[.size] as? Int,
           let srcAttrs = try? fm.attributesOfItem(atPath: source.path),
           let srcSize = srcAttrs[.size] as? Int,
           srcSize == dstSize {
            return
        }
        // Use clonefile (APFS copy-on-write) under the hood via copyItem.
        // If the dst already exists with the wrong size, remove first.
        if fm.fileExists(atPath: dst.path) {
            try? fm.removeItem(at: dst)
        }
        try? fm.copyItem(at: source, to: dst)
    }
}
