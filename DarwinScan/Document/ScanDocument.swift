import SwiftUI
import UniformTypeIdentifiers
import DarwinScanCore

extension UTType {
    static let darwinScan: UTType = UTType(
        exportedAs: "io.zenla.DarwinScan.scan",
        conformingTo: .package
    )
}

/// A live, in-memory handle to one open `.darwinscan` bundle.
///
/// **Two-step open** so big bundles don't freeze MainActor:
///
/// 1. `open(at:)` / `createNew(at:)` (sync, fast) — opens the SQLite handle
///    and the blob store. `loadingState` starts as `.pendingFirstLoad`.
/// 2. `populateInitialView()` (async, off-main) — actually loads the active
///    snapshot's headers into memory. ContentView calls this on first
///    appear via `.task`.
@Observable
@MainActor
final class ScanSession {
    let bundleURL: URL
    let store: ScanStore

    enum LoadingState: Equatable {
        case pendingFirstLoad   // bundle opened, headers not yet read
        case loading            // headers being read off-main
        case ready              // in-memory view is up to date
        case failed(String)
    }

    var loadingState: LoadingState = .pendingFirstLoad

    var displayName: String { bundleURL.deletingPathExtension().lastPathComponent }

    init(bundleURL: URL, store: ScanStore) {
        self.bundleURL = bundleURL
        self.store = store
    }

    /// Open an existing bundle on disk into a new session. Cheap — only
    /// opens the SQLite handle and blob store. The in-memory view is
    /// loaded asynchronously by `populateInitialView()`.
    static func open(at bundleURL: URL) throws -> ScanSession {
        let store = ScanStore()
        try ScanPackage.openInPlace(at: bundleURL, into: store)
        return ScanSession(bundleURL: bundleURL, store: store)
    }

    /// Create a brand-new empty bundle. Already-empty stores skip the
    /// header-load step entirely — the welcome view shows immediately.
    static func createNew(at bundleURL: URL) throws -> ScanSession {
        let store = try ScanPackage.createEmpty(at: bundleURL)
        let session = ScanSession(bundleURL: bundleURL, store: store)
        session.loadingState = .ready  // nothing to load
        return session
    }

    /// Async populate of the active snapshot's headers. Idempotent —
    /// re-running re-reads from disk (used after analysis to pick up the
    /// refined items). The heavy SQLite scan + ItemHeader hydration runs
    /// off MainActor so the window stays responsive.
    func populateInitialView() async {
        guard loadingState != .loading, loadingState != .ready else { return }
        loadingState = .loading
        let store = self.store
        await Task.detached(priority: .userInitiated) {
            try? ScanPackage.populateActiveSnapshot(store: store)
        }.value
        loadingState = .ready
    }

    /// Force a re-read of the active snapshot — e.g. after analysis
    /// completes and the refined items need to land in the in-memory view.
    func refreshActiveSnapshot() async {
        loadingState = .loading
        let store = self.store
        await Task.detached(priority: .userInitiated) {
            try? ScanPackage.populateActiveSnapshot(store: store)
        }.value
        loadingState = .ready
    }

    func checkpoint() {
        try? store.database?.checkpoint()
    }
}
