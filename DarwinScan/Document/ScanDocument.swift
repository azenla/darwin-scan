import SwiftUI
import Combine
import UniformTypeIdentifiers

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
/// document survives a crash, and `snapshot(contentType:)` just checkpoints
/// the WAL and asks `ScanPackage` to bundle the file alongside the blobs.
final class ScanDocument: ReferenceFileDocument {
    typealias Snapshot = FileWrapper

    static var readableContentTypes: [UTType] { [.darwinScan] }
    static var writableContentTypes: [UTType] { [.darwinScan] }

    /// We provide the publisher manually because `ScanStore` is `@Observable`
    /// (not `@Published`-backed), so the compiler won't auto-synthesize it.
    let objectWillChange = ObservableObjectPublisher()

    let store: ScanStore

    init() {
        self.store = ScanStore()
        attachFreshDatabase()
    }

    required init(configuration: ReadConfiguration) throws {
        self.store = ScanStore()
        // ScanPackage.load opens (or migrates from legacy JSON) the database
        // inside the BlobStore cache dir and attaches it to the store.
        try ScanPackage.load(into: store, from: configuration.file)
    }

    func snapshot(contentType: UTType) throws -> FileWrapper {
        // Force WAL → main file before we hand the bytes to FileWrapper.
        try store.database?.checkpoint()
        return try ScanPackage.makeFileWrapper(from: store)
    }

    func fileWrapper(snapshot: FileWrapper, configuration: WriteConfiguration) throws -> FileWrapper {
        snapshot
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
}
