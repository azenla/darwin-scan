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
/// During a live scan, blobs live in `~/Library/Caches/io.zenla.DarwinScan/
/// <session>/`. When a document is opened from disk, blobs live inside the
/// loaded `FileWrapper` tree and we read through that.
@MainActor
@Observable
final class BlobStore {
    /// Every ref we know about — both freshly-scanned (on the cache dir) and
    /// loaded (in `loadedWrappers`).
    private(set) var refs: Set<String> = []

    /// Where freshly-produced blobs land on disk. Created lazily on first
    /// write; cleaned up when this BlobStore is deinited.
    let cacheDirectory: URL

    /// Refs that came from a loaded document point to their original
    /// FileWrapper, which Foundation reads on demand. We don't copy them into
    /// the cache directory until/unless they need to be rewritten.
    private var loadedWrappers: [String: FileWrapper] = [:]

    init() {
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

    /// Produce a `BlobWriter` that worker tasks can use without hopping back
    /// to the main actor for every write. Safe to share across concurrent
    /// tasks — writes go to distinct content-addressed paths.
    nonisolated func makeWriter() -> BlobWriter {
        BlobWriter(directory: cacheDirectory)
    }

    /// Register a ref the worker just wrote to disk. Idempotent.
    func register(ref: String) {
        refs.insert(ref)
    }

    func registerMany(_ refs: [String]) {
        for ref in refs { self.refs.insert(ref) }
    }

    /// Called by `ScanPackage` when loading a document from disk. The bytes
    /// stay inside the FileWrapper (memory-mapped or lazy by Foundation).
    func registerLoaded(ref: String, wrapper: FileWrapper) {
        refs.insert(ref)
        loadedWrappers[ref] = wrapper
    }

    /// Read the bytes for a blob ref. Returns nil if the ref isn't known.
    /// Called from the UI when rendering icons / strings dumps.
    func data(forRef ref: String) -> Data? {
        if let w = loadedWrappers[ref], let bytes = w.regularFileContents {
            return bytes
        }
        let url = blobURL(forRef: ref)
        return try? Data(contentsOf: url)
    }

    /// Build the directory FileWrapper subtree for inclusion in the saved
    /// document. We use `FileWrapper(url:)` so Foundation can stream bytes
    /// from disk into the destination rather than materializing everything.
    func makeFileWrappersForSave() -> [String: [String: FileWrapper]] {
        var bucketed: [String: [String: FileWrapper]] = [:]
        for ref in refs {
            let prefix = String(blobHashPart(ref).prefix(2))
            let filename = "\(ref).bin"
            let wrapper: FileWrapper?
            if let loaded = loadedWrappers[ref] {
                wrapper = loaded
            } else {
                let url = blobURL(forRef: ref)
                wrapper = try? FileWrapper(url: url, options: [.immediate])
                wrapper?.preferredFilename = filename
            }
            if let wrapper {
                bucketed[prefix, default: [:]][filename] = wrapper
            }
        }
        return bucketed
    }

    /// Path inside the cache directory for a given ref. Public so the
    /// `BlobWriter` and tests can introspect.
    func blobURL(forRef ref: String) -> URL {
        cacheDirectory.appendingPathComponent("\(ref).bin")
    }

    /// Strip optional "hint-" prefix to expose the raw hash for sharding.
    nonisolated private func blobHashPart(_ ref: String) -> String {
        if let dash = ref.firstIndex(of: "-") {
            return String(ref[ref.index(after: dash)...])
        }
        return ref
    }
}

/// Worker-side writer. Sendable because it carries only a directory URL —
/// concurrent writes to distinct files in the same dir are safe on APFS.
nonisolated struct BlobWriter: Sendable {
    let directory: URL

    /// Write `data` under the given ref. Idempotent: if the file exists with
    /// matching size we skip the write to avoid touching atime / mtime.
    func write(_ data: Data, ref: String) {
        let url = directory.appendingPathComponent("\(ref).bin")
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let attrs, (attrs[.size] as? Int) == data.count {
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}
