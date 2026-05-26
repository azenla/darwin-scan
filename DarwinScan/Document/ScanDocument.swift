import SwiftUI
import UniformTypeIdentifiers
import DarwinScanCore

extension UTType {
    /// Custom directory-package type for `.darwinscan` documents. Conforms
    /// to `package` so Finder treats it as a single file. Declared in-code
    /// only; double-click open from Finder will route through our
    /// `.onOpenURL` handler in the app shell.
    static let darwinScan: UTType = UTType(
        exportedAs: "io.zenla.DarwinScan.scan",
        conformingTo: .package
    )
}

/// A live, in-memory handle to one open `.darwinscan` bundle. Replaces the
/// old `ReferenceFileDocument` setup: the bundle now exists on disk *before*
/// the window opens — `ScanPackage.createEmpty(at:)` or `openInPlace(at:)`
/// produces the on-disk state, and this class owns the resulting `ScanStore`
/// for the window's lifetime.
///
/// Mutations happen on MainActor. The underlying `ScanStore`, `BlobStore`,
/// and `Database` are explicitly `nonisolated` so background scan tasks can
/// hand off bytes and SQL writes without trapping in `assumeIsolated`.
@Observable
@MainActor
final class ScanSession {
    let bundleURL: URL
    let store: ScanStore

    /// Backed by `URL.path` on `bundleURL`; surfaced so the window title can
    /// show `Foo.darwinscan` without re-deriving from the URL on every body
    /// re-render.
    var displayName: String { bundleURL.deletingPathExtension().lastPathComponent }

    init(bundleURL: URL, store: ScanStore) {
        self.bundleURL = bundleURL
        self.store = store
    }

    /// Open an existing bundle on disk into a new session. Throws
    /// `ScanPackage.LoadError` for malformed bundles.
    static func open(at bundleURL: URL) throws -> ScanSession {
        let store = ScanStore()
        try ScanPackage.openInPlace(at: bundleURL, into: store)
        return ScanSession(bundleURL: bundleURL, store: store)
    }

    /// Create a brand-new empty bundle at `bundleURL` and wrap it in a
    /// session. Throws if the destination already exists or can't be
    /// created.
    static func createNew(at bundleURL: URL) throws -> ScanSession {
        let store = try ScanPackage.createEmpty(at: bundleURL)
        return ScanSession(bundleURL: bundleURL, store: store)
    }

    /// Checkpoint the WAL into the main DB file. Called by the File > Save
    /// menu item and at app-quit time so the bundle is consistent on disk
    /// even if the next launch happens to find the directory mid-flight.
    func checkpoint() {
        try? store.database?.checkpoint()
    }
}
