import Foundation
import Testing
@testable import DarwinScanCore

/// Round-tripping coverage for the discriminated `ScanItem` payload. The
/// JSON form is what SQLite's `items.payload` column stores, so any
/// regression here silently breaks bundles people have already saved.
@Suite("ScanItem Codable round-trip")
struct ScanItemCodableTests {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func roundtrip(_ item: ScanItem) throws -> ScanItem {
        let data = try encoder.encode(item)
        return try decoder.decode(ScanItem.self, from: data)
    }

    @Test func minimalItem() throws {
        let original = ScanItem(
            id: UUID(),
            path: "/bin/ls",
            name: "ls",
            category: .executable,
            size: 138_320,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            insideBundle: false,
            owningBundlePath: nil
        )
        let decoded = try roundtrip(original)
        #expect(decoded == original)
    }

    @Test func executableItemWithFullPayload() throws {
        let original = ScanItem(
            id: UUID(),
            path: "/usr/bin/perl",
            name: "perl",
            category: .executable,
            size: 12_345,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sha256: "deadbeef",
            insideBundle: false,
            owningBundlePath: nil,
            executable: ExecutableInfo(
                kind: .executable,
                roles: [.cli, .interpreter],
                architectures: ["arm64", "x86_64"],
                isFatBinary: true,
                minOS: "14.0",
                platform: "macos",
                sdkVersion: "14.5",
                linkedLibraries: ["/usr/lib/libSystem.B.dylib"],
                isApple: true,
                isCrossPlatformTool: true,
                usageLine: "Usage: perl [switches]"
            ),
            tags: ["cli", "cross-platform", "arm64"],
            relationships: [
                Relationship(kind: .linksDylib, targetPath: "/usr/lib/libSystem.B.dylib")
            ]
        )
        let decoded = try roundtrip(original)
        #expect(decoded == original)
    }

    @Test func launchServicePayload() throws {
        let original = ScanItem(
            id: UUID(),
            path: "/System/Library/LaunchDaemons/com.apple.something.plist",
            name: "com.apple.something",
            category: .launchService,
            size: 1024,
            modifiedAt: nil,
            insideBundle: false,
            owningBundlePath: nil,
            launchService: LaunchServiceInfo(
                kind: .daemon,
                label: "com.apple.something",
                program: "/usr/libexec/something",
                programArguments: ["/usr/libexec/something", "--foreground"],
                runAtLoad: true,
                keepAlive: true,
                machServices: ["com.apple.something"]
            )
        )
        let decoded = try roundtrip(original)
        #expect(decoded == original)
    }

    @Test func missingOptionalPayloadsDecodeAsNil() throws {
        // Optional fields (every per-category payload) decode as nil when
        // absent — that's what lets older bundles open after a model adds
        // a new category struct.
        let payload = """
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "path": "/x",
              "name": "x",
              "category": "executable",
              "size": 0,
              "insideBundle": false,
              "tags": [],
              "relationships": []
            }
            """
        let decoded = try decoder.decode(ScanItem.self, from: Data(payload.utf8))
        #expect(decoded.executable == nil)
        #expect(decoded.application == nil)
        #expect(decoded.launchService == nil)
        #expect(decoded.framework == nil)
        #expect(decoded.mlModel == nil)
        #expect(decoded.icon == nil)
        #expect(decoded.manPage == nil)
        #expect(decoded.localization == nil)
        #expect(decoded.dyldCache == nil)
        #expect(decoded.script == nil)
        #expect(decoded.plist == nil)
    }
}

@Suite("ItemHeader projection")
struct ItemHeaderTests {
    @Test func flattensExecutablePayload() {
        let exec = ExecutableInfo(
            kind: .executable,
            roles: [.cli],
            architectures: ["arm64"],
            isFatBinary: false,
            platform: "macos",
            isApple: true,
            isCrossPlatformTool: false,
            usageLine: "usage: foo"
        )
        let item = ScanItem(
            id: UUID(),
            path: "/usr/bin/foo",
            name: "foo",
            category: .executable,
            size: 100,
            modifiedAt: nil,
            insideBundle: false,
            owningBundlePath: nil,
            executable: exec,
            tags: ["cli"]
        )
        let header = ItemHeader(from: item)
        #expect(header.architectures == ["arm64"])
        #expect(header.platform == "macos")
        #expect(header.usageLine == "usage: foo")
        #expect(header.isApple)
        #expect(!header.isFatBinary)
        #expect(header.roles == [.cli])
        #expect(header.lowercasedName == "foo")
    }

    @Test func itemWithoutPayloadHasSafeDefaults() {
        let item = ScanItem(
            id: UUID(),
            path: "/x",
            name: "X",
            category: .other,
            size: 0,
            modifiedAt: nil,
            insideBundle: false,
            owningBundlePath: nil
        )
        let header = ItemHeader(from: item)
        #expect(header.architectures.isEmpty)
        #expect(header.platform == nil)
        #expect(header.roles.isEmpty)
        #expect(!header.isApple)
        #expect(header.lowercasedName == "x")
    }

    @Test func withIdReplacesOnlyId() {
        let item = ScanItem(
            id: UUID(),
            path: "/x",
            name: "x",
            category: .other,
            size: 0,
            modifiedAt: nil,
            insideBundle: false,
            owningBundlePath: nil
        )
        let header = ItemHeader(from: item)
        let newID = UUID()
        let updated = header.withId(newID)
        #expect(updated.id == newID)
        #expect(updated.path == header.path)
        #expect(updated.name == header.name)
    }
}
