import Foundation
import Testing
@testable import DarwinScanCore

/// SQLite-backed manifest coverage. Every test runs against a temporary
/// file-backed database, never an in-memory one, because the production
/// path always lives on disk and a few of the WAL pragmas behave
/// differently for `:memory:` databases.
@Suite("Database persistence")
struct DatabaseTests {
    /// Make a fresh, isolated database in the system temp dir. The caller
    /// is responsible for removing it; the helper returns the URL so tests
    /// can assert on file shape too.
    private func makeTempDB() throws -> (Database, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DarwinScanCoreTests-\(UUID().uuidString)")
            .appendingPathComponent("data.db")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return (try Database(at: url), url)
    }

    @Test func opensAndPersistsSchemaVersion() throws {
        let (db, url) = try makeTempDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Initial open should write the schema version into the meta table.
        let raw = try db.meta("schema_version")
        #expect(raw != nil)
        #expect(String(data: raw ?? Data(), encoding: .utf8) == "\(Database.currentSchemaVersion)")
    }

    @Test func upsertAndFetchSingleItem() throws {
        let (db, url) = try makeTempDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = ScanItem(
            id: UUID(),
            path: "/bin/ls",
            name: "ls",
            category: .executable,
            size: 1024,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            insideBundle: false,
            owningBundlePath: nil,
            executable: ExecutableInfo(
                kind: .executable,
                architectures: ["arm64"],
                isFatBinary: false,
                isApple: true,
                isCrossPlatformTool: false
            ),
            tags: ["cli"]
        )
        try db.upsertItem(item)
        let fetched = try db.item(id: item.id)
        #expect(fetched == item)
    }

    @Test func upsertWithRelationshipsAndOutgoingTargets() throws {
        let (db, url) = try makeTempDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        let item = ScanItem(
            id: id,
            path: "/usr/bin/foo",
            name: "foo",
            category: .executable,
            size: 100,
            modifiedAt: nil,
            insideBundle: false,
            owningBundlePath: nil,
            relationships: [
                Relationship(kind: .linksDylib, targetPath: "/usr/lib/libSystem.B.dylib"),
                Relationship(kind: .linksDylib, targetPath: "/usr/lib/libc.dylib")
            ]
        )
        try db.upsertItem(item)
        let targets = try db.outgoingTargets(sourceID: id)
        #expect(Set(targets) == ["/usr/lib/libSystem.B.dylib", "/usr/lib/libc.dylib"])
    }

    @Test func upsertReplacesPreviousRelationships() throws {
        let (db, url) = try makeTempDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        var item = ScanItem(
            id: id, path: "/x", name: "x", category: .other,
            size: 0, modifiedAt: nil, insideBundle: false, owningBundlePath: nil,
            relationships: [Relationship(kind: .linksDylib, targetPath: "/old.dylib")]
        )
        try db.upsertItem(item)
        item.relationships = [Relationship(kind: .linksDylib, targetPath: "/new.dylib")]
        try db.upsertItem(item)
        let targets = try db.outgoingTargets(sourceID: id)
        #expect(targets == ["/new.dylib"])
    }

    @Test func allItemsReturnsEverythingPersisted() throws {
        let (db, url) = try makeTempDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let items: [ScanItem] = (0..<10).map { i in
            ScanItem(
                id: UUID(),
                path: "/x/\(i)",
                name: "item-\(i)",
                category: .other,
                size: Int64(i),
                modifiedAt: nil,
                insideBundle: false,
                owningBundlePath: nil
            )
        }
        try db.upsertItems(items)
        let fetched = try db.allItems()
        #expect(fetched.count == items.count)
        #expect(Set(fetched.map(\.id)) == Set(items.map(\.id)))
    }

    @Test func deleteItemAlsoClearsRelationships() throws {
        let (db, url) = try makeTempDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = ScanItem(
            id: UUID(), path: "/x", name: "x", category: .other,
            size: 0, modifiedAt: nil, insideBundle: false, owningBundlePath: nil,
            relationships: [Relationship(kind: .linksDylib, targetPath: "/y")]
        )
        try db.upsertItem(item)
        try db.deleteItem(id: item.id)
        #expect(try db.allItems().isEmpty)
        #expect(try db.outgoingTargets(sourceID: item.id).isEmpty)
    }

    @Test func metaCodableRoundTrip() throws {
        let (db, url) = try makeTempDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let info = SystemInfo(
            productName: "macOS",
            productVersion: "26.5",
            productBuildVersion: "26F1",
            kernelVersion: nil,
            hardwareModel: "Mac15,11",
            cpuBrand: "Apple M3",
            architectures: ["arm64"],
            hostName: "test",
            bootArgs: nil,
            sipStatus: "enabled",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try db.setMeta("system_info", value: info)
        let fetched: SystemInfo? = try db.meta("system_info", as: SystemInfo.self)
        #expect(fetched == info)
    }
}
