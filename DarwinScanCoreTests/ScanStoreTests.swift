import Foundation
import Testing
@testable import DarwinScanCore

/// In-memory store + indexes coverage. The indexes are the bit most likely
/// to drift when a new category or relationship kind is added — anything
/// that changes `addIndexes`/`removeIndexes` should be covered here.
@MainActor
@Suite("ScanStore indexes", .serialized)
struct ScanStoreTests {
    @Test func ingestPopulatesCategoryCounts() {
        let store = ScanStore()
        store.ingest((0..<3).map { _ in makeItem(category: .executable) })
        store.ingest((0..<2).map { _ in makeItem(category: .framework) })
        let counts = store.counts()
        #expect(counts[.executable] == 3)
        #expect(counts[.framework] == 2)
        #expect(counts[.application] == 0)
    }

    @Test func upsertSamePathReusesUUID() {
        let store = ScanStore()
        let first = makeItem(path: "/x", category: .other)
        store.upsert(first)
        let originalID = store.itemsByPath["/x"]
        #expect(originalID == first.id)

        // Touch a different in-memory id but the same path — store should
        // reuse the previous UUID so UI selection stays stable.
        let second = makeItem(path: "/x", category: .executable)
        let collisionID = second.id
        store.upsert(second)
        let storedID = store.itemsByPath["/x"]
        #expect(storedID == originalID)
        #expect(storedID != collisionID)
        #expect(store.items[originalID!]?.category == .executable)
    }

    @Test func pathReferencedByIsIncremental() {
        let store = ScanStore()
        let a = makeItem(
            path: "/a", category: .executable,
            relationships: [Relationship(kind: .linksDylib, targetPath: "/lib")]
        )
        let b = makeItem(
            path: "/b", category: .executable,
            relationships: [Relationship(kind: .linksDylib, targetPath: "/lib")]
        )
        store.upsert(a)
        store.upsert(b)
        let referrers = store.pathReferencedBy["/lib"] ?? []
        #expect(Set(referrers) == [a.id, b.id])
    }

    @Test func incomingReferencesMaterializesHeaders() {
        let store = ScanStore()
        let target = makeItem(path: "/lib", category: .framework)
        store.upsert(target)
        let a = makeItem(
            path: "/a", category: .executable,
            relationships: [Relationship(kind: .linksDylib, targetPath: "/lib")]
        )
        store.upsert(a)
        let incoming = store.incomingReferences(toPath: "/lib")
        #expect(incoming.count == 1)
        #expect(incoming.first?.path == "/a")
    }

    @Test func contentsOfBundleAtPath() {
        let store = ScanStore()
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
        store.upsert(child)
        store.upsert(unrelated)
        let contents = store.contents(ofBundleAtPath: bundle)
        #expect(contents.count == 1)
        #expect(contents.first?.path == child.path)
    }

    @Test func resetClearsIndexes() {
        let store = ScanStore()
        store.upsert(makeItem(category: .executable))
        store.upsert(makeItem(category: .framework))
        store.reset()
        #expect(store.items.isEmpty)
        #expect(store.counts()[.executable] == 0)
        #expect(store.counts()[.framework] == 0)
        #expect(store.itemsByPath.isEmpty)
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
