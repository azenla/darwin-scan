import Foundation
import Testing
@testable import DarwinScanCore

/// Coverage for `BlobWriter.captureHashing` — the single-pass hash+capture
/// that replaced the old two-read import flow (hash, then copy).
@Suite("BlobStore captureHashing")
struct BlobStoreCaptureTests {
    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DarwinScanBlobTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSource(_ bytes: Data, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("src-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        return url
    }

    @Test func capturesBytesAndDigestMatchesStreamingHash() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BlobStore(rootDirectory: dir.appendingPathComponent("blobs", isDirectory: true))
        let writer = store.makeWriter()

        // A payload larger than the 1 MB chunk size so the streaming loop runs
        // more than once.
        var bytes = Data(count: 0)
        for i in 0..<(3 * (1 << 20) + 7) { bytes.append(UInt8(i & 0xFF)) }
        let source = try makeSource(bytes, in: dir)

        let captured = try #require(writer.captureHashing(from: source, refPrefix: "file-"))

        // Digest must match the independent streaming hasher used elsewhere.
        let expectedSHA = try #require(Hash.sha256(of: source))
        #expect(captured.sha == expectedSHA)
        #expect(captured.ref == "file-\(expectedSHA)")

        // The blob on disk must be byte-identical to the source.
        let storedURL = store.blobURL(forRef: captured.ref)
        let stored = try Data(contentsOf: storedURL)
        #expect(stored == bytes)
    }

    @Test func deduplicatesIdenticalContent() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BlobStore(rootDirectory: dir.appendingPathComponent("blobs", isDirectory: true))
        let writer = store.makeWriter()

        let bytes = Data("the same content captured from two paths".utf8)
        let a = try makeSource(bytes, in: dir)
        let b = try makeSource(bytes, in: dir)

        let first = try #require(writer.captureHashing(from: a))
        let second = try #require(writer.captureHashing(from: b))

        // Identical content -> identical content-addressed ref, one blob file.
        #expect(first.ref == second.ref)
        let stored = try Data(contentsOf: store.blobURL(forRef: second.ref))
        #expect(stored == bytes)

        // No leftover temp files in the blob root.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: store.rootDirectory.path)) ?? []
        #expect(!leftovers.contains { $0.hasPrefix(".capture-") })
    }

    @Test func returnsNilForMissingSource() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BlobStore(rootDirectory: dir.appendingPathComponent("blobs", isDirectory: true))
        let writer = store.makeWriter()
        let missing = dir.appendingPathComponent("does-not-exist.bin")
        #expect(writer.captureHashing(from: missing) == nil)
    }
}
