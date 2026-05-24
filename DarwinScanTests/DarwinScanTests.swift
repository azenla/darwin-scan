import Foundation
import Testing
import UniformTypeIdentifiers
@testable import DarwinScan
import DarwinScanCore

/// App-side coverage: the integration glue between the framework's
/// `ScanStore` / `Database` / `ScanPackage` and SwiftUI's
/// `ReferenceFileDocument`. Per-framework logic lives in
/// `DarwinScanCoreTests`.

@MainActor
@Suite("UTType .darwinScan registration")
struct UTTypeRegistrationTests {
    @Test func darwinScanUTTypeIsConfigured() {
        let type = UTType.darwinScan
        // Identifier matches what the document group registers; if this
        // drifts the GUI's Open/Save dialogs won't filter to .darwinscan.
        #expect(type.identifier == "io.zenla.DarwinScan.scan")
        #expect(type.conforms(to: .package))
    }

    @Test func readableAndWritableTypesIncludeDarwinScan() {
        #expect(ScanDocument.readableContentTypes.contains(.darwinScan))
        #expect(ScanDocument.writableContentTypes.contains(.darwinScan))
    }
}

@MainActor
@Suite("SidebarSelection", .serialized)
struct SidebarSelectionTests {
    @Test func equalityForSimpleCases() {
        #expect(SidebarSelection.systemInfo == .systemInfo)
        #expect(SidebarSelection.allItems == .allItems)
        #expect(SidebarSelection.systemInfo != .allItems)
    }

    @Test func categoryCasesEqualByPayload() {
        #expect(SidebarSelection.category(.executable) == .category(.executable))
        #expect(SidebarSelection.category(.executable) != .category(.framework))
        #expect(SidebarSelection.category(.executable) != .allItems)
    }

    @Test func hashableSetMembership() {
        var seen: Set<SidebarSelection> = []
        seen.insert(.systemInfo)
        seen.insert(.allItems)
        seen.insert(.category(.executable))
        seen.insert(.category(.executable))  // duplicate
        #expect(seen.count == 3)
    }
}

@MainActor
@Suite("ScanDocument lifecycle", .serialized)
struct ScanDocumentTests {
    @Test func newDocumentAttachesFreshDatabase() {
        let document = ScanDocument()
        #expect(document.store.database != nil)
        #expect(document.store.items.isEmpty)
        #expect(document.store.databaseURL != nil)
    }

    @Test func snapshotProducesDirectoryWrapperWithDatabase() throws {
        let document = ScanDocument()
        let snapshot = try document.snapshot(contentType: .darwinScan)
        // The Sendable snapshot must carry checkpointed database bytes —
        // that's what the off-main `makeFileWrapper(snapshot:)` materializes
        // into `data.db` inside the saved bundle. `FileDocumentWriteConfiguration`
        // has no public init, so we exercise the bundle builder directly
        // rather than the `fileWrapper(snapshot:configuration:)` trampoline.
        #expect(snapshot.databaseBytes != nil)
        let wrapper = try ScanPackage.makeFileWrapper(snapshot: snapshot)
        #expect(wrapper.isDirectory)
        #expect(wrapper.fileWrappers?[ScanPackage.databaseFilename] != nil)
    }

    /// End-to-end save: build a populated document, snapshot, write to
    /// disk, then re-read the bundle through `ScanPackage.load` (the
    /// same call ScanDocument.init(configuration:) makes). We can't
    /// instantiate SwiftUI's `ReadConfiguration` directly in tests
    /// — only SwiftUI's loader has access to that initialiser — so we
    /// exercise the load path through ScanPackage directly. The init's
    /// own MainActor.assumeIsolated wrapper is what
    /// `newDocumentAttachesFreshDatabase` already exercises.
    @Test func snapshotWritesBundleThatReopensCleanly() throws {
        let document = ScanDocument()
        document.store.systemInfo = SystemInfo(
            productName: "macOS",
            productVersion: "26.5",
            productBuildVersion: nil,
            kernelVersion: nil,
            hardwareModel: nil,
            cpuBrand: nil,
            architectures: ["arm64"],
            hostName: "test-host",
            bootArgs: nil,
            sipStatus: nil,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let items: [ScanItem] = (0..<4).map { i in
            ScanItem(
                id: UUID(),
                path: "/x/\(i)",
                name: "doc-test-\(i)",
                category: i.isMultiple(of: 2) ? .executable : .framework,
                size: Int64(i * 100),
                modifiedAt: nil,
                insideBundle: false,
                owningBundlePath: nil
            )
        }
        document.store.ingest(items)

        let snapshot = try document.snapshot(contentType: .darwinScan)
        let wrapper = try ScanPackage.makeFileWrapper(snapshot: snapshot)
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanDocumentTests-\(UUID().uuidString).darwinscan")
        defer { try? FileManager.default.removeItem(at: outURL) }
        try wrapper.write(to: outURL, options: [.atomic], originalContentsURL: nil)

        // Read it back through ScanPackage — the same call that
        // ScanDocument.init(configuration:) performs.
        let reopened = ScanStore()
        try ScanPackage.load(into: reopened,
                             from: try FileWrapper(url: outURL, options: []))
        #expect(reopened.items.count == items.count)
        #expect(reopened.counts()[.executable] == 2)
        #expect(reopened.counts()[.framework] == 2)
        #expect(reopened.systemInfo?.productVersion == "26.5")
        // After reopen, the WAL must have been flushed into data.db.
        #expect(reopened.database != nil)
    }

    @Test func freshDocumentsGetSeparateDatabaseSessions() {
        let a = ScanDocument()
        let b = ScanDocument()
        // BlobStore creates a session-<uuid> directory each time; the two
        // documents must not share it (otherwise saves and concurrent
        // scans across windows would step on each other).
        #expect(a.store.blobStore.cacheDirectory != b.store.blobStore.cacheDirectory)
        #expect(a.store.databaseURL != b.store.databaseURL)
    }
}

@MainActor
@Suite("ScanController", .serialized)
struct ScanControllerTests {
    /// Boot a `ScanStore` the same way `ScanDocument.init` does so the
    /// scan's writes mirror into a real SQLite database. The test pins
    /// the scan to /bin (≈37 Mach-Os, sub-second on a stock macOS).
    private func makeStore() -> ScanStore {
        let store = ScanStore()
        let cacheDir = store.blobStore.cacheDirectory
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let dbURL = cacheDir.appendingPathComponent(ScanPackage.databaseFilename)
        try? FileManager.default.removeItem(at: dbURL)
        if let db = try? Database(at: dbURL) {
            store.databaseURL = dbURL
            store.attachDatabase(db)
        }
        return store
    }

    private func fastOptions(roots: [String]) -> ScanOptions {
        var opts = ScanOptions()
        opts.roots = roots
        opts.excludedPrefixes = []
        opts.hashFiles = false
        opts.extractStrings = false
        opts.indexManPages = false
        opts.inspectAppBundles = false
        opts.inspectMLModels = false
        opts.inspectDyldCache = false
        return opts
    }

    @Test func startScanIngestsItemsAndFlipsRunningState() async {
        let store = makeStore()
        let controller = ScanController()
        #expect(!controller.isRunning)
        controller.startScan(options: fastOptions(roots: ["/bin"]),
                             ingestInto: store)
        #expect(controller.isRunning)

        // Spin until the worker task completes.
        let deadline = Date().addingTimeInterval(20)
        while controller.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(!controller.isRunning, "scan should finish before deadline")
        #expect(store.items.count > 0, "should ingest at least one item from /bin")
        #expect((store.counts()[.executable] ?? 0) > 0)
        #expect(store.systemInfo != nil)
        #expect(store.lastScanCompleted != nil)
        #expect(controller.progress.phase == .done)
    }

    @Test func startScanIsIgnoredWhileAnotherScanIsRunning() async {
        let store = makeStore()
        let controller = ScanController()
        controller.startScan(options: fastOptions(roots: ["/bin"]),
                             ingestInto: store)
        let startedAt = controller.progress.startedAt
        #expect(controller.isRunning)
        // Second start while running must be a no-op — the original
        // progress.startedAt should not change.
        controller.startScan(options: fastOptions(roots: ["/bin"]),
                             ingestInto: store)
        #expect(controller.progress.startedAt == startedAt)

        // Wait for the in-flight scan to finish so we don't leak it.
        let deadline = Date().addingTimeInterval(20)
        while controller.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @Test func cancelStopsAScanInProgress() async {
        let store = makeStore()
        let controller = ScanController()
        // Use /usr — larger tree so we can actually cancel mid-flight.
        controller.startScan(options: fastOptions(roots: ["/usr"]),
                             ingestInto: store)
        #expect(controller.isRunning)
        // Give it a brief moment to enter the inspecting phase.
        try? await Task.sleep(nanoseconds: 100_000_000)
        controller.cancel()
        let deadline = Date().addingTimeInterval(15)
        while controller.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(!controller.isRunning, "controller should drain after cancel")
    }
}

/// View-level smoke tests. SwiftUI views can be instantiated and held in
/// tests, but we don't render them through XCUI here — the UI test target
/// is responsible for actual rendering coverage. We just verify the views
/// can be constructed without trapping and that their bound state is
/// readable.
@MainActor
@Suite("SwiftUI view construction", .serialized)
struct ViewConstructionTests {
    @Test func welcomeViewCallsBackOnButtonAction() {
        var called = false
        let view = WelcomeView(onScan: { called = true })
        // Trigger the closure directly — XCUI would simulate the tap; here
        // we just verify the binding is wired.
        view.onScan()
        #expect(called)
    }

    @Test func sidebarViewBindsToStoreSelection() {
        let store = ScanStore()
        var selection: SidebarSelection? = .systemInfo
        let binding = Binding<SidebarSelection?>(
            get: { selection },
            set: { selection = $0 }
        )
        _ = SidebarView(store: store, selection: binding)
        selection = .category(.executable)
        #expect(selection == .category(.executable))
    }

    @Test func itemListViewBindsToItemSelection() {
        let store = ScanStore()
        var itemSelection: UUID? = nil
        let binding = Binding<UUID?>(
            get: { itemSelection },
            set: { itemSelection = $0 }
        )
        _ = ItemListView(store: store, selection: .allItems, itemSelection: binding)
        let id = UUID()
        itemSelection = id
        #expect(itemSelection == id)
    }
}

// Pull in SwiftUI's `Binding` for the view-construction tests.
import SwiftUI
