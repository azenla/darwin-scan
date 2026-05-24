import Foundation
import Testing
@testable import DarwinScanCore

/// End-to-end save/load coverage for the `.darwinscan` bundle format. We
/// build a populated store, serialise it via `ScanPackage.makeFileWrapper`,
/// write it to disk, then load it back from the FileWrapper and assert the
/// indexes + payloads match.
@MainActor
@Suite("ScanPackage save/load", .serialized)
struct ScanPackageTests {
    private func makeTempBundle() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DarwinScanCoreTests-\(UUID().uuidString).darwinscan")
        return url
    }

    private func attachFreshDatabase(to store: ScanStore) throws {
        let cacheDir = store.blobStore.cacheDirectory
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let dbURL = cacheDir.appendingPathComponent(ScanPackage.databaseFilename)
        try? FileManager.default.removeItem(at: dbURL)
        let db = try Database(at: dbURL)
        store.databaseURL = dbURL
        store.attachDatabase(db)
    }

    @Test func roundTripPopulatedBundle() throws {
        let source = ScanStore()
        try attachFreshDatabase(to: source)
        source.systemInfo = SystemInfo(
            productName: "macOS",
            productVersion: "26.5",
            productBuildVersion: nil,
            kernelVersion: nil,
            hardwareModel: nil,
            cpuBrand: nil,
            architectures: ["arm64"],
            hostName: nil,
            bootArgs: nil,
            sipStatus: nil,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let items: [ScanItem] = (0..<5).map { i in
            ScanItem(
                id: UUID(),
                path: "/x/\(i)",
                name: "item-\(i)",
                category: i.isMultiple(of: 2) ? .executable : .framework,
                size: Int64(i * 1024),
                modifiedAt: nil,
                insideBundle: false,
                owningBundlePath: nil,
                relationships: i == 0 ? [Relationship(kind: .linksDylib, targetPath: "/y")] : []
            )
        }
        source.ingest(items)

        let bundleURL = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let wrapper = try ScanPackage.makeFileWrapper(from: source)
        try wrapper.write(to: bundleURL, options: [.atomic], originalContentsURL: nil)

        // Reload through a fresh ScanStore via the same APIs the GUI uses
        // when opening a document.
        let loaded = ScanStore()
        let loadedWrapper = try FileWrapper(url: bundleURL, options: [])
        try ScanPackage.load(into: loaded, from: loadedWrapper)

        #expect(loaded.items.count == items.count)
        #expect(loaded.counts()[.executable] == 3)
        #expect(loaded.counts()[.framework] == 2)
        #expect(loaded.systemInfo?.productVersion == "26.5")
        // Outgoing relationship persisted via SQLite.
        let firstID = loaded.itemsByPath["/x/0"]
        let targets = try loaded.database?.outgoingTargets(sourceID: firstID!) ?? []
        #expect(targets == ["/y"])
    }

    @Test func emptyBundleLoadsCleanly() throws {
        let source = ScanStore()
        try attachFreshDatabase(to: source)
        let bundleURL = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let wrapper = try ScanPackage.makeFileWrapper(from: source)
        try wrapper.write(to: bundleURL, options: [.atomic], originalContentsURL: nil)

        let loaded = ScanStore()
        try ScanPackage.load(into: loaded, from: try FileWrapper(url: bundleURL, options: []))
        #expect(loaded.items.isEmpty)
        #expect(loaded.database != nil)
    }
}

/// Smoke coverage for the high-level CLI driver. We point it at the
/// project's own DarwinScan source directory rather than /System so the
/// test stays fast (sub-second) and self-contained.
@MainActor
@Suite("CommandLineRunner", .serialized)
struct CommandLineRunnerTests {
    @Test func generatesOpenableBundle() async throws {
        // Use the framework's own source as the scan root — a tiny, stable,
        // sandbox-friendly tree.
        let frameworkSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DarwinScanCore", isDirectory: true)
        guard FileManager.default.fileExists(atPath: frameworkSources.path) else {
            // CI / sandbox where #filePath isn't the source tree — skip.
            return
        }

        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLI-Test-\(UUID().uuidString).darwinscan")
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        var options = ScanOptions()
        options.roots = [frameworkSources.path]
        options.excludedPrefixes = []
        options.hashFiles = false
        options.extractStrings = false
        options.indexManPages = false

        try await CommandLineRunner.runScan(
            options: options,
            outputBundleURL: bundleURL,
            progressHandler: { _ in }
        )

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: bundleURL.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        let dbURL = bundleURL.appendingPathComponent("data.db")
        #expect(FileManager.default.fileExists(atPath: dbURL.path))

        // Re-open the bundle through ScanPackage.load to make sure the
        // GUI's load path agrees with what the CLI produced.
        let store = ScanStore()
        try ScanPackage.load(into: store, from: try FileWrapper(url: bundleURL, options: []))
        // The framework source tree contains plenty of Swift files; nothing
        // is a recognised category, but the worker should at least visit them
        // without crashing. We just assert the database opened.
        #expect(store.database != nil)
    }
}
