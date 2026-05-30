import Foundation
import Testing
@testable import DarwinScanCore

/// End-to-end coverage for the in-place `.darwinscan` bundle flow. Each
/// test creates an empty bundle on disk, populates the store via the
/// scanner's normal ingest path, then re-opens the same bundle through
/// `ScanPackage.openInPlace` and asserts the indexes + payloads round-trip.
@MainActor
@Suite("ScanPackage in-place open/save", .serialized)
struct ScanPackageTests {
    private func makeTempBundleURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DarwinScanCoreTests-\(UUID().uuidString).darwinscan")
    }

    @Test func roundTripPopulatedBundle() throws {
        let bundleURL = makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let source = try ScanPackage.createEmpty(at: bundleURL)
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
        source.beginImport(source: .currentSystem, sourceRef: "test", systemInfo: source.systemInfo)
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
        source.completeImport()
        try source.database?.checkpoint()

        // Re-open the bundle through the same code path the GUI uses.
        let loaded = ScanStore()
        try ScanPackage.openInPlace(at: bundleURL, into: loaded)
        try ScanPackage.populateActiveSnapshot(store: loaded)

        #expect(loaded.itemCount == items.count)
        #expect(loaded.counts()[.executable] == 3)
        #expect(loaded.counts()[.framework] == 2)
        #expect(loaded.systemInfo?.productVersion == "26.5")
        // Outgoing relationship persisted via SQLite.
        let firstID = loaded.itemHeader(atPath: "/x/0")?.id
        let targets = try loaded.database?.outgoingTargets(sourceID: firstID!) ?? []
        #expect(targets == ["/y"])
    }

    @Test func emptyBundleLoadsCleanly() throws {
        let bundleURL = makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let source = try ScanPackage.createEmpty(at: bundleURL)
        try source.database?.checkpoint()

        let loaded = ScanStore()
        try ScanPackage.openInPlace(at: bundleURL, into: loaded)
        try ScanPackage.populateActiveSnapshot(store: loaded)
        #expect(loaded.itemCount == 0)
        #expect(loaded.database != nil)
    }

    @Test func createEmptyRejectsExistingDestination() throws {
        let bundleURL = makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        _ = try ScanPackage.createEmpty(at: bundleURL)
        #expect(throws: (any Error).self) {
            _ = try ScanPackage.createEmpty(at: bundleURL)
        }
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

        let source = CurrentSystemSource(options: options)
        try await CommandLineRunner.runImport(
            source: source,
            options: options,
            outputBundleURL: bundleURL,
            progressHandler: { _ in }
        )

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: bundleURL.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        let dbURL = bundleURL.appendingPathComponent("data.db")
        #expect(FileManager.default.fileExists(atPath: dbURL.path))

        // Re-open the bundle through ScanPackage.openInPlace to make sure
        // the GUI's load path agrees with what the CLI produced.
        let store = ScanStore()
        try ScanPackage.openInPlace(at: bundleURL, into: store)
        try ScanPackage.populateActiveSnapshot(store: store)
        // The framework source tree contains plenty of Swift files; nothing
        // is a recognised category, but the worker should at least visit them
        // without crashing. We just assert the database opened.
        #expect(store.database != nil)
    }
}
