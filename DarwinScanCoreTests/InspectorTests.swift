import Foundation
import Testing
@testable import DarwinScanCore

/// Per-inspector unit tests. We synthesise minimal on-disk fixtures in
/// the system temp directory rather than depending on `/System` — keeps
/// tests sandbox-friendly and fast (each suite runs in <100 ms).

@Suite("PlistInspector")
struct PlistInspectorTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlistInspectorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func decodesLaunchDaemonPlist() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Mimic /System/Library/LaunchDaemons/<label>.plist by putting the
        // file in a path that contains the `LaunchDaemons` segment.
        let daemonsDir = dir.appendingPathComponent("LaunchDaemons", isDirectory: true)
        try FileManager.default.createDirectory(at: daemonsDir, withIntermediateDirectories: true)
        let plistURL = daemonsDir.appendingPathComponent("com.example.test.plist")
        let plistXML = #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>com.example.test</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/usr/libexec/example</string>
                    <string>--foreground</string>
                </array>
                <key>RunAtLoad</key><true/>
                <key>KeepAlive</key><true/>
                <key>MachServices</key>
                <dict>
                    <key>com.example.test.svc</key><true/>
                </dict>
            </dict>
            </plist>
            """#
        try plistXML.write(to: plistURL, atomically: true, encoding: .utf8)

        let info = try #require(PlistInspector.decodeLaunchService(at: plistURL))
        #expect(info.kind == .daemon)
        #expect(info.label == "com.example.test")
        #expect(info.program == "/usr/libexec/example")
        #expect(info.programArguments == ["/usr/libexec/example", "--foreground"])
        #expect(info.runAtLoad)
        #expect(info.keepAlive)
        #expect(info.machServices.contains("com.example.test.svc"))
    }

    @Test func keepAliveAsDictionaryIsTreatedAsTrue() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let daemonsDir = dir.appendingPathComponent("LaunchDaemons", isDirectory: true)
        try FileManager.default.createDirectory(at: daemonsDir, withIntermediateDirectories: true)
        let plistURL = daemonsDir.appendingPathComponent("com.example.cond.plist")
        let plistXML = #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0">
            <dict>
              <key>Label</key><string>com.example.cond</string>
              <key>Program</key><string>/usr/libexec/cond</string>
              <key>KeepAlive</key>
              <dict>
                <key>SuccessfulExit</key><false/>
              </dict>
            </dict>
            </plist>
            """#
        try plistXML.write(to: plistURL, atomically: true, encoding: .utf8)
        let info = try #require(PlistInspector.decodeLaunchService(at: plistURL))
        #expect(info.keepAlive)
    }

    @Test func plistInfoSnifferRecognisesXMLAndBinary() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // XML plist
        let xmlURL = dir.appendingPathComponent("xml.plist")
        let xml = #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
              <key>CFBundleIdentifier</key><string>io.example.foo</string>
              <key>CFBundleExecutable</key><string>foo</string>
            </dict></plist>
            """#
        try xml.write(to: xmlURL, atomically: true, encoding: .utf8)
        let xmlResult = try #require(PlistInspector.decodePlistInfo(at: xmlURL))
        #expect(xmlResult.0.format == .xml)
        #expect(xmlResult.0.topLevel == .dictionary)
        #expect(xmlResult.0.looksLikeInfoPlist)
        #expect(xmlResult.0.kind == .info)

        // Binary plist (round-trip via PropertyListSerialization)
        let binURL = dir.appendingPathComponent("bin.plist")
        let plistDict: [String: Any] = ["foo": 1, "bar": "baz"]
        let binData = try PropertyListSerialization.data(
            fromPropertyList: plistDict, format: .binary, options: 0
        )
        try binData.write(to: binURL)
        let binResult = try #require(PlistInspector.decodePlistInfo(at: binURL))
        #expect(binResult.0.format == .binary)
        #expect(binResult.0.topLevel == .dictionary)
        #expect(binResult.0.keyCount == 2)
    }

    @Test func decodesAppBundleInfoPlist() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appURL = dir.appendingPathComponent("Test.app")
        let contentsURL = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        let info: [String: Any] = [
            "CFBundleIdentifier": "io.example.Test",
            "CFBundleExecutable": "Test",
            "CFBundleDisplayName": "Test App",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "456",
            "LSUIElement": true,
            "LSApplicationCategoryType": "public.app-category.utilities"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try data.write(to: infoURL)

        let bundleInfo = try #require(PlistInspector.decodeAppBundle(at: appURL))
        #expect(bundleInfo.bundleIdentifier == "io.example.Test")
        #expect(bundleInfo.displayName == "Test App")
        #expect(bundleInfo.executableName == "Test")
        #expect(bundleInfo.shortVersionString == "1.2.3")
        #expect(bundleInfo.isHidden)
        #expect(bundleInfo.category == "public.app-category.utilities")
    }
}

@Suite("MachOInspector")
struct MachOInspectorTests {
    @Test func parsesSystemLs() throws {
        // /bin/ls is always present and is a fat Mach-O on Apple Silicon
        // (arm64 + x86_64 universal). We don't pin to specific architectures
        // here — just to "looks parseable + executable" — because the slice
        // set varies across macOS versions.
        let url = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let info = try #require(MachOInspector().inspect(url: url))
        #expect(info.kind == .executable)
        #expect(!info.architectures.isEmpty)
        // /bin/ls is signed by Apple and always built with a known platform.
        #expect(info.platform == "macos" || info.platform == nil)
    }

    @Test func rejectsNonMachOFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MachOInspector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("not-macho.txt")
        try Data("just some bytes that are not Mach-O magic".utf8).write(to: url)
        #expect(MachOInspector().inspect(url: url) == nil)
    }

    @Test func returnsNilForMissingFile() {
        let url = URL(fileURLWithPath: "/this/path/does/not/exist/anywhere")
        #expect(MachOInspector().inspect(url: url) == nil)
    }
}

@Suite("DyldCacheInspector")
struct DyldCacheInspectorTests {
    @Test func filenameHeuristic() {
        #expect(DyldCacheInspector.looksLikeDyldCache(filename: "dyld_shared_cache_arm64e"))
        #expect(DyldCacheInspector.looksLikeDyldCache(filename: "dyld_shared_cache_arm64e.01"))
        #expect(DyldCacheInspector.looksLikeDyldCache(filename: "dyld_shared_cache_x86_64"))
        #expect(!DyldCacheInspector.looksLikeDyldCache(filename: "dyld_shared_cache_arm64e.symbols"))
        #expect(!DyldCacheInspector.looksLikeDyldCache(filename: "dyld_shared_cache_arm64e.dylddata"))
        #expect(!DyldCacheInspector.looksLikeDyldCache(filename: "unrelated.bin"))
    }

    @Test func parsesSynthesisedHeader() throws {
        // Build a minimal dyld_v1 header — the inspector only needs the
        // first 0x20 bytes for the magic + mappingCount/imageCount fields.
        var bytes = [UInt8](repeating: 0, count: 0x200)
        // Magic: "dyld_v1   arm64e" padded to 16 bytes.
        let magic = Array("dyld_v1   arm64e".utf8)
        for (i, b) in magic.enumerated() { bytes[i] = b }
        // mappingCount = 7 at offset 0x14 (LE uint32)
        bytes[0x14] = 0x07
        // imageCount   = 1500 at offset 0x1C (LE uint32) — 1500 = 0x5DC
        bytes[0x1C] = 0xDC
        bytes[0x1D] = 0x05
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic-dyld-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let info = try #require(DyldCacheInspector.inspect(url: url))
        #expect(info.architecture == "arm64e")
        #expect(info.mappingCount == 7)
        #expect(info.imageCount == 1500)
        #expect(info.formatVersion?.hasPrefix("dyld_v1") == true)
    }

    @Test func rejectsFilesWithoutMagic() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("non-dyld-\(UUID().uuidString).bin")
        try Data(repeating: 0, count: 0x200).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DyldCacheInspector.inspect(url: url) == nil)
    }
}

@Suite("LocalizationInspector")
struct LocalizationInspectorTests {
    @Test func parsesSimpleStringsFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocTests-\(UUID().uuidString)")
        let lproj = dir.appendingPathComponent("en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stringsURL = lproj.appendingPathComponent("Localizable.strings")
        try "\"hello\" = \"Hello\";\n\"bye\" = \"Goodbye\";\n".write(
            to: stringsURL, atomically: true, encoding: .utf8
        )
        let info = try #require(LocalizationInspector.inspect(url: stringsURL))
        #expect(info.kind == .strings)
        #expect(info.language == "en")
        #expect(info.keyCount == 2)
    }

    @Test func lprojDirectoryYieldsLanguage() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocTests-\(UUID().uuidString)")
        let lproj = dir.appendingPathComponent("fr.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let info = try #require(LocalizationInspector.inspectLprojDirectory(lproj))
        #expect(info.kind == .lproj)
        #expect(info.language == "fr")
    }

    @Test func unsupportedExtensionReturnsNil() {
        let url = URL(fileURLWithPath: "/tmp/whatever.txt")
        #expect(LocalizationInspector.inspect(url: url) == nil)
    }
}

@Suite("ManPageInspector")
struct ManPageInspectorTests {
    @Test func parsesUncompressedManPage() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManTests-\(UUID().uuidString)")
        let man1 = dir.appendingPathComponent("man1", isDirectory: true)
        try FileManager.default.createDirectory(at: man1, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pageURL = man1.appendingPathComponent("mytool.1")
        let content = """
            .TH MYTOOL 1
            .SH NAME
            mytool \\- a really helpful test tool
            .SH SYNOPSIS
            mytool [options]
            """
        try content.write(to: pageURL, atomically: true, encoding: .utf8)
        let result = try #require(ManPageInspector.inspect(url: pageURL))
        #expect(result.0.section == "1")
        #expect(result.0.title == "mytool")
        #expect(result.0.description?.contains("really helpful") == true)
        #expect(!result.0.compressed)
    }

    @Test func returnsNilWhenSectionUnknown() throws {
        // Parent dir doesn't look like manN, so the inspector bails.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("loose.1")
        try Data("nothing".utf8).write(to: url)
        #expect(ManPageInspector.inspect(url: url) == nil)
    }
}

@Suite("StringsExtractor")
struct StringsExtractorTests {
    @Test func grepInBinaryFindsStringFromSystemBinary() {
        // /bin/ls' help output starts with "usage:" — guaranteed to be in
        // its strings table.
        let url = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let line = StringsExtractor.grepInBinary(url: url, needle: "usage:")
        #expect(line?.lowercased().contains("usage:") == true)
    }

    @Test func grepInBinaryReturnsNilForAbsentNeedle() {
        let url = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let absurd = "ZZZZZ_NOT_A_REAL_STRING_IN_LS_ZZZZZ_\(UUID().uuidString)"
        #expect(StringsExtractor.grepInBinary(url: url, needle: absurd) == nil)
    }

    @Test func grepInBinaryHandlesMissingFile() {
        let url = URL(fileURLWithPath: "/no/such/file/\(UUID().uuidString)")
        #expect(StringsExtractor.grepInBinary(url: url, needle: "anything") == nil)
    }
}

@Suite("FileWalker")
struct FileWalkerTests {
    /// Realpath helper. The temp dir is `/var/folders/...`; macOS resolves
    /// `/var` → `/private/var` symbolically, and Foundation's various URL
    /// APIs disagree on when to canonicalise it. We compare paths through
    /// this helper on both sides of every assertion.
    private func realPath(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }

    private func makeFixtureTree() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileWalker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // dir/
        //   a/
        //     deep/
        //       file.txt
        //   b/
        //     hidden/         (will be in excludes)
        //       skipme.txt
        //   top.txt
        let a = dir.appendingPathComponent("a/deep")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try Data().write(to: a.appendingPathComponent("file.txt"))
        let hidden = dir.appendingPathComponent("b/hidden")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data().write(to: hidden.appendingPathComponent("skipme.txt"))
        try Data().write(to: dir.appendingPathComponent("top.txt"))
        return dir
    }

    @Test func walkerYieldsEverythingUnderTheRoot() async throws {
        let dir = try makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: dir) }
        var options = ScanOptions()
        options.roots = [dir.path]
        options.excludedPrefixes = []
        let walker = FileWalker(options: options)

        var seen: Set<String> = []
        for await url in walker.makeStream() {
            seen.insert(realPath(url.path))
        }
        #expect(seen.contains(realPath(dir.appendingPathComponent("top.txt").path)))
        #expect(seen.contains(realPath(dir.appendingPathComponent("a/deep/file.txt").path)))
        #expect(seen.contains(realPath(dir.appendingPathComponent("b/hidden/skipme.txt").path)))
    }

    @Test func walkerHonorsExcludePrefixes() async throws {
        // Exclude-prefix matching is a string operation on `URL.path` —
        // it works on whatever canonical form the platform yields. Test
        // the contract directly with the FileWalker.isExcluded helper so
        // the test isn't entangled with macOS's /var → /private/var games.
        var options = ScanOptions()
        options.excludedPrefixes = ["/x/excluded", "/y"]
        let walker = FileWalker(options: options)
        #expect(walker.isExcluded("/x/excluded"))
        #expect(walker.isExcluded("/x/excluded/inner/file"))
        #expect(!walker.isExcluded("/x/excludedx"))         // not a prefix segment
        #expect(walker.isExcluded("/y"))
        #expect(walker.isExcluded("/y/anything"))
        #expect(!walker.isExcluded("/yz"))
        #expect(!walker.isExcluded("/x/other"))
    }


    @Test func walkerIgnoresMissingRoots() async {
        var options = ScanOptions()
        options.roots = ["/no/such/root/\(UUID().uuidString)"]
        options.excludedPrefixes = []
        let walker = FileWalker(options: options)
        var count = 0
        for await _ in walker.makeStream() { count += 1 }
        #expect(count == 0)
    }
}
