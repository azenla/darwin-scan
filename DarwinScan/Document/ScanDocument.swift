import SwiftUI
import Combine
import UniformTypeIdentifiers
import Synchronization
import DarwinScanCore

extension UTType {
    /// Custom directory-package type for `.darwinscan` documents. Conforms to
    /// `package` so Finder treats it as a single file. Declared in-code only;
    /// Finder will not auto-open these by double-click until we add the same
    /// declarations to Info.plist, but File > Open inside the app works.
    static let darwinScan: UTType = UTType(
        exportedAs: "io.zenla.DarwinScan.scan",
        conformingTo: .package
    )
}

/// SwiftUI reference document — we use a reference type because the store is
/// `@Observable` and we mutate it freely from the scanner (background actor
/// hops on completion). FileDocument's value semantics would force unnecessary
/// copies of large item arrays.
///
/// Persistence: a SQLite `data.db` is opened immediately in the BlobStore's
/// per-session cache directory. Every `upsert` writes through so an unsaved
/// document survives a crash.
///
/// ## Isolation
///
/// SwiftUI's `ReferenceFileDocument` machinery calls `newDocument`,
/// `init(configuration:)`, `snapshot(contentType:)`, and
/// `fileWrapper(snapshot:configuration:)` from background threads — the docs
/// are explicit: "Don't perform serialization and deserialization on
/// MainActor." Earlier revisions wrapped each entry point in
/// `MainActor.assumeIsolated` and trapped (EXC_BREAKPOINT) the moment SwiftUI
/// dispatched off-main. The whole document, plus its `ScanStore` and
/// `BlobStore`, are therefore `nonisolated`; the post-init contract is that
/// mutations happen on MainActor (the scanner's batch/progress/system-info
/// sinks are `@MainActor` closures, and view edits run on the main thread).
final class ScanDocument: ReferenceFileDocument {
    typealias Snapshot = ScanPackage.Snapshot

    static var readableContentTypes: [UTType] { [.darwinScan] }
    static var writableContentTypes: [UTType] { [.darwinScan] }

    /// We provide the publisher manually because `ScanStore` is `@Observable`
    /// (not `@Published`-backed), so the compiler won't auto-synthesize it.
    let objectWillChange = ObservableObjectPublisher()

    let store: ScanStore

    /// Nonisolated mirror of the state the off-main `snapshot(contentType:)`
    /// reads. Populated by `captureBacking()` at init time (and only there —
    /// the URLs and `Database` reference don't change for the doc's lifetime).
    private let saveBacking = Mutex<SaveBacking>(SaveBacking())

    private struct SaveBacking: Sendable {
        var database: Database?
        var databaseURL: URL?
        var blobCacheDirectory: URL?
    }

    init() {
        self.store = ScanStore()
        attachFreshDatabase()
        captureBacking()
    }

    required init(configuration: ReadConfiguration) throws {
        let store = ScanStore()
        try ScanPackage.load(into: store, from: configuration.file)
        self.store = store
        captureBacking()
    }

    func snapshot(contentType: UTType) throws -> Snapshot {
        // Read the mirrored pointers, checkpoint the WAL into the main file,
        // then capture the bytes — SwiftUI re-enables document edits during
        // `fileWrapper(snapshot:configuration:)`, so an auto-checkpoint can
        // otherwise rewrite the main file mid-save.
        let backing = saveBacking.withLock { $0 }
        guard let cacheDir = backing.blobCacheDirectory else {
            throw NSError(
                domain: "ScanDocument",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Document save backing was never initialized"]
            )
        }
        var dbBytes: Data?
        if let db = backing.database, let url = backing.databaseURL {
            try db.checkpoint()
            dbBytes = try Data(contentsOf: url)
        }
        return ScanPackage.Snapshot(databaseBytes: dbBytes, blobCacheDirectory: cacheDir)
    }

    func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        try ScanPackage.makeFileWrapper(snapshot: snapshot)
    }

    // MARK: - Helpers

    /// Open a brand-new SQLite database in the BlobStore's session directory
    /// and attach it to the store. Failures are logged but non-fatal — the
    /// store still works in memory; we'd just lose the persistent backing
    /// until the next reopen.
    private func attachFreshDatabase() {
        let cacheDir = store.blobStore.cacheDirectory
        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let url = cacheDir.appendingPathComponent(ScanPackage.databaseFilename)
            try? FileManager.default.removeItem(at: url)
            let db = try Database(at: url)
            store.databaseURL = url
            store.attachDatabase(db)
        } catch {
            print("[ScanDocument] attachFreshDatabase failed: \(error)")
        }
    }

    /// Copy `database` / `databaseURL` / `blobCacheDirectory` from the store
    /// into the `saveBacking` so the (potentially off-main) save path can
    /// read them under a lock without touching the live store.
    private func captureBacking() {
        let db = store.database
        let url = store.databaseURL
        let cacheDir = store.blobStore.cacheDirectory
        saveBacking.withLock { state in
            state.database = db
            state.databaseURL = url
            state.blobCacheDirectory = cacheDir
        }
    }
}
