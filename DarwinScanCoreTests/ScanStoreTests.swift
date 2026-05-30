import Foundation
import Testing
@testable import DarwinScanCore

/// SQL-backed ScanStore coverage. The store no longer carries an in-memory
/// items dict; reads go through `Database` with a small LRU cache. These
/// tests open a real temp bundle so the SQL paths exercise end-to-end.
@MainActor
@Suite("ScanStore indexes", .serialized)
struct ScanStoreTests {
    private func makeAttachedStore() throws -> (ScanStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanStoreTests-\(UUID().uuidString).darwinscan")
        let store = try ScanPackage.createEmpty(at: url)
        store.beginImport(source: .currentSystem, sourceRef: "test", systemInfo: nil)
        return (store, url)
    }

    @Test func ingestPopulatesCategoryCounts() throws {
        let (store, url) = try makeAttachedStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.ingest((0..<3).map { _ in makeItem(category: .executable) })
        store.ingest((0..<2).map { _ in makeItem(category: .framework) })
        let counts = store.counts()
        #expect(counts[.executable] == 3)
        #expect(counts[.framework] == 2)
        #expect((counts[.application] ?? 0) == 0)
    }

    @Test func upsertSamePathReturnsRefinedHeader() throws {
        let (store, url) = try makeAttachedStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = makeItem(path: "/x", category: .other)
        store.ingest([first])
        #expect(store.itemHeader(atPath: "/x")?.id == first.id)

        // Upsert with a different in-memory id; same path keeps the
        // canonical row.
        let second = ScanItem(
            id: first.id,
            path: "/x",
            name: "x",
            category: .executable,
            size: 0,
            modifiedAt: nil,
            insideBundle: false,
            owningBundlePath: nil
        )
        store.upsert(second)
        #expect(store.itemHeader(atPath: "/x")?.category == .executable)
    }

    @Test func incomingReferencesViaSQL() throws {
        let (store, url) = try makeAttachedStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let target = makeItem(path: "/lib", category: .framework)
        let a = makeItem(
            path: "/a", category: .executable,
            relationships: [Relationship(kind: .linksDylib, targetPath: "/lib")]
        )
        store.ingest([target, a])
        let incoming = store.incomingReferences(toPath: "/lib")
        #expect(incoming.count == 1)
        #expect(incoming.first?.path == "/a")
    }

    @Test func contentsOfBundleAtPath() throws {
        let (store, url) = try makeAttachedStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = "/Apps/Safari.app"
        let child = makeItem(
            path: "\(bundle)/Contents/MacOS/Safari",
            category: .executable,
            owningBundlePath: bundle
        )
        let unrelated = makeItem(
            path: "/Apps/Other.app/Contents/MacOS/Other",
            category: .executable,
            owningBundlePath: "/Apps/Other.app"
        )
        store.ingest([child, unrelated])
        let contents = store.contents(ofBundleAtPath: bundle)
        #expect(contents.count == 1)
        #expect(contents.first?.path == child.path)
    }

    @Test func resetClearsCachedStats() throws {
        let (store, url) = try makeAttachedStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.ingest([
            makeItem(category: .executable),
            makeItem(category: .framework)
        ])
        store.reset()
        #expect(store.itemCount == 0)
        #expect((store.counts()[.executable] ?? 0) == 0)
        #expect((store.counts()[.framework] ?? 0) == 0)
    }
}

private func makeItem(
    path: String = "/path/\(UUID().uuidString)",
    category: ItemCategory,
    relationships: [Relationship] = [],
    owningBundlePath: String? = nil
) -> ScanItem {
    ScanItem(
        id: UUID(),
        path: path,
        name: (path as NSString).lastPathComponent,
        category: category,
        size: 0,
        modifiedAt: nil,
        insideBundle: owningBundlePath != nil,
        owningBundlePath: owningBundlePath,
        relationships: relationships
    )
}
