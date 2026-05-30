import Foundation
import Testing
import SwiftUI
import UniformTypeIdentifiers
@testable import DarwinScan
import DarwinScanCore

/// App-side coverage: the integration glue between the framework's
/// `ScanStore` / `Database` / `ScanPackage` and the new Save-first session
/// flow. Per-framework logic lives in `DarwinScanCoreTests`.

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
@Suite("ScanSession lifecycle", .serialized)
struct ScanSessionTests {
    private func makeTempBundleURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanSessionTests-\(UUID().uuidString).darwinscan")
    }

    @Test func createNewBuildsBundleOnDisk() throws {
        let url = makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try ScanSession.createNew(at: url)
        #expect(session.bundleURL == url)
        #expect(session.store.database != nil)
        #expect(session.store.itemCount == 0)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        let dbURL = url.appendingPathComponent("data.db")
        #expect(FileManager.default.fileExists(atPath: dbURL.path))
        let blobsDir = url.appendingPathComponent("blobs")
        #expect(FileManager.default.fileExists(atPath: blobsDir.path))
    }

    @Test func createNewRejectsExistingDestination() throws {
        let url = makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try ScanSession.createNew(at: url)
        #expect(throws: (any Error).self) {
            _ = try ScanSession.createNew(at: url)
        }
    }

    @Test func createThenOpenRoundTripsContent() async throws {
        let url = makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let session = try ScanSession.createNew(at: url)
        session.store.systemInfo = SystemInfo(
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
        session.store.beginImport(source: .currentSystem, sourceRef: "test", systemInfo: session.store.systemInfo)
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
        session.store.ingest(items)
        session.store.completeImport()
        session.checkpoint()

        // Reopen as a fresh session and confirm the items round-trip.
        // `ScanSession.open` is now two-phase; populate explicitly so the
        // synchronous test can assert against `store.items`.
        let reopened = try ScanSession.open(at: url)
        await reopened.populateInitialView()
        #expect(reopened.store.itemCount == items.count)
        #expect(reopened.store.counts()[.executable] == 2)
        #expect(reopened.store.counts()[.framework] == 2)
        #expect(reopened.store.systemInfo?.productVersion == "26.5")
        #expect(reopened.store.database != nil)
    }
}

@MainActor
@Suite("ScanController", .serialized)
struct ScanControllerTests {
    /// Boot a `ScanStore` backed by a real on-disk bundle so the scan's
    /// writes hit the same code path the GUI uses. /bin (≈37 Mach-Os,
    /// sub-second on a stock macOS) is the slowest sanctioned scan root.
    private func makeBundle() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanControllerTests-\(UUID().uuidString).darwinscan")
        _ = try ScanPackage.createEmpty(at: url)
        return url
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

    @Test func startImportIngestsItemsAndFlipsRunningState() async throws {
        let url = try makeBundle()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try ScanSession.open(at: url)
        let controller = ScanController()
        let options = fastOptions(roots: ["/bin"])
        let source = CurrentSystemSource(options: options)
        #expect(!controller.isRunning)
        controller.startImport(source: source, options: options, into: session.store)
        #expect(controller.isRunning)

        let deadline = Date().addingTimeInterval(20)
        while controller.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(!controller.isRunning, "import should finish before deadline")
        #expect(session.store.itemCount > 0, "should ingest at least one item from /bin")
        // After import every item is `.unanalyzed` — analysis is the second phase.
        #expect(session.store.counts()[.unanalyzed] ?? 0 > 0)
        #expect(session.store.systemInfo != nil)
        #expect(session.store.lastScanCompleted != nil)
        #expect(controller.progress.phase == .done)
    }

    @Test func startImportIsIgnoredWhileAnotherIsRunning() async throws {
        let url = try makeBundle()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try ScanSession.open(at: url)
        let controller = ScanController()
        let options = fastOptions(roots: ["/bin"])
        controller.startImport(source: CurrentSystemSource(options: options), options: options, into: session.store)
        let startedAt = controller.progress.startedAt
        #expect(controller.isRunning)
        controller.startImport(source: CurrentSystemSource(options: options), options: options, into: session.store)
        #expect(controller.progress.startedAt == startedAt)

        let deadline = Date().addingTimeInterval(20)
        while controller.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @Test func cancelStopsAnImportInProgress() async throws {
        let url = try makeBundle()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try ScanSession.open(at: url)
        let controller = ScanController()
        let options = fastOptions(roots: ["/usr"])
        controller.startImport(source: CurrentSystemSource(options: options), options: options, into: session.store)
        #expect(controller.isRunning)
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
