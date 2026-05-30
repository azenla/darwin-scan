import Foundation
import Testing
@testable import DarwinScanCore

/// End-to-end coverage for `ScanPipeline.inspect` on a synthesised fixture
/// tree. The full SwiftUI scanner is exercised by the
/// `CommandLineRunner` smoke test in `ScanPackageTests.swift`; this suite
/// pokes the inspector dispatch in isolation so we can assert on the
/// classification + tag + relationship details without spinning up an
/// AsyncStream walker.
@Suite("AnalysisPipeline classification")
struct ScannerPipelineTests {
    private func makePipeline(options: ScanOptions = ScanOptions()) -> AnalysisPipeline {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pipeline-blobs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return AnalysisPipeline(options: options, blobStore: BlobStore(rootDirectory: tmp))
    }

    @Test func classifiesPlistFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Preferences.plist")
        try Data("<plist version=\"1.0\"><dict><key>x</key><integer>1</integer></dict></plist>".utf8)
            .write(to: url)

        let pipeline = makePipeline()
        let result = try #require(pipeline.analyze(url: url) as AnalysisOutput?)
        #expect(result.item.category == .plist)
        #expect(result.item.tags.contains("plist"))
    }

    @Test func classifiesLaunchServicePlist() throws {
        // The classifier triggers on the *path* "/System/Library/LaunchDaemons/"
        // or "/System/Library/LaunchAgents/". We synthesise a path that
        // includes the segment.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pipeline-\(UUID().uuidString)")
        let launchAgents = dir.appendingPathComponent("System/Library/LaunchAgents")
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = launchAgents.appendingPathComponent("io.example.agent.plist")
        let xml = #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0">
            <dict>
                <key>Label</key><string>io.example.agent</string>
                <key>ProgramArguments</key>
                <array><string>/usr/libexec/agent</string></array>
                <key>RunAtLoad</key><true/>
            </dict>
            </plist>
            """#
        try xml.write(to: url, atomically: true, encoding: .utf8)

        // The classifier checks `path.hasPrefix("/System/Library/LaunchAgents/")`,
        // which is the *real* prefix — our temp dir won't match unless we
        // pass the exact prefix string. Use a thin custom pipeline.
        // The simplest way to exercise this branch: assert
        // PlistInspector.decodeLaunchService is what the pipeline depends on.
        let info = try #require(PlistInspector.decodeLaunchService(at: url))
        #expect(info.kind == .agent)
        #expect(info.label == "io.example.agent")
        #expect(info.programArguments == ["/usr/libexec/agent"])
        #expect(info.runAtLoad)
    }

    @Test func classifiesLocalizationStringsFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pipeline-\(UUID().uuidString)")
        let lproj = dir.appendingPathComponent("en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = lproj.appendingPathComponent("Localizable.strings")
        try "\"k\" = \"v\";".write(to: url, atomically: true, encoding: .utf8)

        let pipeline = makePipeline()
        let result = try #require(pipeline.analyze(url: url) as AnalysisOutput?)
        #expect(result.item.category == .localization)
        #expect(result.item.tags.contains("strings"))
        #expect(result.item.localization?.language == "en")
    }

    @Test func classifiesScriptViaShebang() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hello.sh")
        try "#!/bin/bash\necho hi\n".write(to: url, atomically: true, encoding: .utf8)

        let pipeline = makePipeline()
        let result = try #require(pipeline.analyze(url: url) as AnalysisOutput?)
        #expect(result.item.category == .script)
        #expect(result.item.script?.language == "shell")
    }

    @Test func classifiesManPageInProperDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Pipeline checks `path.contains("/share/man/man")` — we synthesise
        // a matching structure.
        let shareMan1 = dir.appendingPathComponent("share/man/man1")
        try FileManager.default.createDirectory(at: shareMan1, withIntermediateDirectories: true)
        let url = shareMan1.appendingPathComponent("toolio.1")
        try """
            .TH TOOLIO 1
            .SH NAME
            toolio \\- example tool
            """.write(to: url, atomically: true, encoding: .utf8)
        let pipeline = makePipeline()
        let result = try #require(pipeline.analyze(url: url) as AnalysisOutput?)
        #expect(result.item.category == .manPage)
        #expect(result.item.manPage?.section == "1")
        #expect(result.item.manPage?.title == "toolio")
    }

    @Test func machOFileClassifiedAsExecutable() throws {
        let url = URL(fileURLWithPath: "/bin/ls")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let pipeline = makePipeline()
        let result = try #require(pipeline.analyze(url: url) as AnalysisOutput?)
        #expect(result.item.category == .executable)
        #expect(result.item.executable?.kind == .executable)
        // The `isApple` heuristic is path-prefix based and does NOT include
        // `/bin` — only /System, /usr/lib, /usr/libexec, /usr/sbin, and a
        // specific list of /usr/bin names. So /bin/ls comes back false even
        // though it's Apple-shipped. Asserting on the heuristic's *current*
        // behavior here so a future refactor surfaces this explicitly.
        #expect(result.item.executable?.isApple == false)
        // Context falls through to parent-dir name for top-level items.
        #expect(result.item.context == "bin")
    }

    @Test func ownedByBundleRelationshipForBundleChild() throws {
        // Synthesise an .app bundle and a child file inside it. The
        // pipeline assigns owningBundlePath and emits an ownedByBundle
        // relationship.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pipeline-\(UUID().uuidString)")
        let appURL = dir.appendingPathComponent("Test.app")
        let contents = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plistURL = contents.appendingPathComponent("Resources/en.lproj/Localizable.strings")
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "\"k\" = \"v\";".write(to: plistURL, atomically: true, encoding: .utf8)
        let pipeline = makePipeline()
        let result = pipeline.analyze(url: plistURL)
        #expect(result.item.insideBundle)
        #expect(result.item.owningBundlePath?.hasSuffix(".app") == true)
        #expect(result.item.relationships.contains { $0.kind == Relationship.Kind.ownedByBundle })
    }
}

@Suite("ScanOptions")
struct ScanOptionsTests {
    @Test func defaultsMatchDocumentedScope() {
        let opts = ScanOptions()
        #expect(opts.roots == ["/System", "/bin", "/sbin", "/usr"])
        // The /System/Volumes prefix must be excluded — that's the rule
        // the CLAUDE.md scope guarantees.
        #expect(opts.excludedPrefixes.contains("/System/Volumes"))
        #expect(opts.excludedPrefixes.contains("/usr/local"))
        #expect(!opts.followSymlinks)
        #expect(opts.hashFiles)
        #expect(!opts.extractStrings)
        #expect(opts.indexManPages)
    }

    @Test func codableRoundTrip() throws {
        var opts = ScanOptions()
        opts.hashFiles = false
        opts.extractStrings = true
        opts.stringsMinLength = 12
        opts.roots = ["/usr/bin"]
        let data = try JSONEncoder().encode(opts)
        let decoded = try JSONDecoder().decode(ScanOptions.self, from: data)
        #expect(decoded == opts)
    }
}

/// `ScanStore.search` and the in-memory `items` dict are gone — the list
/// view now streams via SQL through `ScanStore.forEachHeader` (with an
/// in-memory `SearchQuery` filter wrapped around it). The closest
/// behavioral equivalent we can unit-test is the per-category stream,
/// which is exercised here against a real on-disk bundle.
@Suite("ScanStore category stream")
struct ScanStoreSearchTests {
    @MainActor
    @Test func forEachHeaderRespectsCategoryFilter() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreStream-\(UUID().uuidString).darwinscan")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try ScanPackage.createEmpty(at: url)
        store.beginImport(source: .currentSystem, sourceRef: "test", systemInfo: nil)
        store.ingest([
            ScanItem(id: UUID(), path: "/a", name: "a", category: .executable,
                     size: 0, modifiedAt: nil, insideBundle: false, owningBundlePath: nil),
            ScanItem(id: UUID(), path: "/b", name: "b", category: .framework,
                     size: 0, modifiedAt: nil, insideBundle: false, owningBundlePath: nil),
            ScanItem(id: UUID(), path: "/c", name: "c", category: .executable,
                     size: 0, modifiedAt: nil, insideBundle: false, owningBundlePath: nil),
        ])
        var executables: [ItemHeader] = []
        store.forEachHeader(category: .executable) { executables.append($0); return true }
        var frameworks: [ItemHeader] = []
        store.forEachHeader(category: .framework) { frameworks.append($0); return true }
        #expect(executables.count == 2)
        #expect(frameworks.count == 1)
    }
}
