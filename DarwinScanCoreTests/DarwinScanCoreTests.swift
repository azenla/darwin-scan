import Foundation
import Testing
@testable import DarwinScanCore

/// Cross-cutting smoke tests for the framework's most-used utilities.
/// Per-area suites live in their own files (SearchQueryTests,
/// DatabaseTests, ScanStoreTests, ScanPackageTests, ScanItemCodableTests).
@Suite("DarwinScanCore basics")
struct DarwinScanCoreBasicsTests {
    @Test func sha256RoundTripsThroughTempFile() throws {
        let payload = Data("hello, darwin\n".utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DarwinScanCore-\(UUID().uuidString).bin")
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let hex = Hash.sha256(of: url)
        // Reference value computed with `echo -n "hello, darwin" | shasum -a 256`.
        // We compare against the in-memory hash of the same bytes since the
        // file write includes a trailing newline.
        let inMemory = Hash.sha256Hex(payload)
        #expect(hex == inMemory)
        #expect(hex?.count == 64)
    }

    @Test func byteFormatRendersHumanReadable() {
        let formatted = ByteFormat.string(1_500_000)
        // Locale-dependent — just check the unit suffix shows up.
        #expect(formatted.lowercased().contains("mb")
            || formatted.lowercased().contains("kb"))
    }

    @Test func dyldCacheFilenameHeuristic() {
        #expect(DyldCacheInspector.looksLikeDyldCache(filename: "dyld_shared_cache_arm64e"))
        #expect(DyldCacheInspector.looksLikeDyldCache(filename: "dyld_shared_cache_arm64e.01"))
        #expect(DyldCacheInspector.looksLikeDyldCache(filename: "dyld_shared_cache_arm64e.development"))
        #expect(!DyldCacheInspector.looksLikeDyldCache(filename: "dyld_shared_cache_arm64e.symbols"))
        #expect(!DyldCacheInspector.looksLikeDyldCache(filename: "dyld_shared_cache_arm64e.dylddata"))
        #expect(!DyldCacheInspector.looksLikeDyldCache(filename: "something_else"))
    }

    @Test func dyldCacheArchExtraction() {
        #expect(DyldCacheInspector.archFromFilename("dyld_shared_cache_arm64e") == "arm64e")
        #expect(DyldCacheInspector.archFromFilename("dyld_shared_cache_arm64e.01") == "arm64e")
        #expect(DyldCacheInspector.archFromFilename("dyld_shared_cache_x86_64h") == "x86_64h")
    }

    @Test func fileWalkerExcludesMatchPrefix() {
        var options = ScanOptions()
        options.excludedPrefixes = ["/System/Volumes", "/usr/local"]
        let walker = FileWalker(options: options)
        #expect(walker.isExcluded("/System/Volumes"))
        #expect(walker.isExcluded("/System/Volumes/Data"))
        #expect(walker.isExcluded("/usr/local/bin/foo"))
        #expect(!walker.isExcluded("/System/Library"))
        #expect(!walker.isExcluded("/usr/localx"))  // not a prefix match
    }
}
