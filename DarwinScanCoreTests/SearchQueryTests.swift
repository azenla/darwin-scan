import Foundation
import Testing
@testable import DarwinScanCore

/// Parser and evaluator coverage for `SearchQuery`. The parser is the bit
/// most likely to silently break — if a token's `field:value` shape stops
/// matching the recognised field set, the filter silently degrades to free
/// text, so the surface area gets specific tests rather than smoke tests.
@Suite("SearchQuery parser")
struct SearchQueryParserTests {
    @Test func parsesEmptyInput() {
        let q = SearchQuery.parse("")
        #expect(q.isEmpty)
        #expect(q.freeText.isEmpty)
        #expect(q.filters.isEmpty)
    }

    @Test func freeTextOnly() {
        let q = SearchQuery.parse("safari")
        #expect(q.freeText == "safari")
        #expect(q.filters.isEmpty)
    }

    @Test func singleFilter() {
        let q = SearchQuery.parse("arch:arm64")
        #expect(q.filters == [.architecture("arm64")])
        #expect(q.freeText.isEmpty)
    }

    @Test func filterPlusFreeText() {
        let q = SearchQuery.parse("foo arch:x86_64 bar")
        #expect(q.filters == [.architecture("x86_64")])
        #expect(q.freeText == "foo bar")
    }

    @Test func quotedValueKeepsSpaces() {
        let q = SearchQuery.parse("app:\"Time Machine\"")
        #expect(q.filters == [.app("Time Machine")])
    }

    @Test func fieldAliases() {
        // arch / architecture / abi → architecture
        for alias in ["arch:x", "architecture:x", "abi:x"] {
            let q = SearchQuery.parse(alias)
            #expect(q.filters == [.architecture("x")], "alias \(alias)")
        }
        for alias in ["framework:y", "fw:y"] {
            let q = SearchQuery.parse(alias)
            #expect(q.filters == [.framework("y")], "alias \(alias)")
        }
        for alias in ["lang:en", "language:en", "locale:en"] {
            let q = SearchQuery.parse(alias)
            #expect(q.filters == [.language("en")], "alias \(alias)")
        }
    }

    @Test func categoryMatchesByRawAndDisplayName() {
        let q1 = SearchQuery.parse("category:executable")
        #expect(q1.filters == [.category(.executable)])
        let q2 = SearchQuery.parse("category:Executables")
        #expect(q2.filters == [.category(.executable)])
    }

    @Test func roleParsesRawValue() {
        let q = SearchQuery.parse("role:daemon")
        #expect(q.filters == [.role(.daemon)])
    }

    @Test func unknownFieldFallsThroughToFreeText() {
        let q = SearchQuery.parse("notafield:value rest")
        #expect(q.filters.isEmpty)
        #expect(q.freeText == "notafield:value rest")
    }

    @Test func booleanTruthyValues() {
        for truthy in ["true", "yes", "y", "1"] {
            let q = SearchQuery.parse("apple:\(truthy)")
            #expect(q.filters == [.apple(true)], "truthy \(truthy)")
        }
        for falsy in ["false", "no", "0", "off"] {
            let q = SearchQuery.parse("apple:\(falsy)")
            #expect(q.filters == [.apple(false)], "falsy \(falsy)")
        }
    }
}

@Suite("SearchQuery evaluator")
struct SearchQueryEvaluatorTests {
    /// Helper to build a synthetic ItemHeader. Going through `ScanItem`
    /// exercises the same denormalisation `ScanStore.ingest` would.
    private func makeHeader(
        name: String = "ls",
        category: ItemCategory = .executable,
        path: String = "/bin/ls",
        executable: ExecutableInfo? = nil,
        tags: [String] = [],
        owningBundle: String? = nil
    ) -> ItemHeader {
        let item = ScanItem(
            id: UUID(),
            path: path,
            name: name,
            category: category,
            size: 0,
            modifiedAt: nil,
            insideBundle: owningBundle != nil,
            owningBundlePath: owningBundle,
            executable: executable,
            tags: tags
        )
        return ItemHeader(from: item)
    }

    @Test func emptyQueryMatchesEverything() {
        let q = SearchQuery()
        #expect(q.matches(makeHeader()))
    }

    @Test func architectureFilter() {
        let exec = ExecutableInfo(
            kind: .executable,
            architectures: ["arm64", "x86_64"],
            isFatBinary: true,
            isApple: true,
            isCrossPlatformTool: false
        )
        let header = makeHeader(executable: exec)
        #expect(SearchQuery.parse("arch:arm64").matches(header))
        #expect(SearchQuery.parse("arch:x86").matches(header))
        #expect(!SearchQuery.parse("arch:i386").matches(header))
    }

    @Test func categoryFilter() {
        let app = makeHeader(category: .application)
        let exe = makeHeader(category: .executable)
        let q = SearchQuery.parse("category:application")
        #expect(q.matches(app))
        #expect(!q.matches(exe))
    }

    @Test func tagFilter() {
        let h = makeHeader(tags: ["cli", "arm64", "apple-shipped"])
        #expect(SearchQuery.parse("tag:cli").matches(h))
        #expect(!SearchQuery.parse("tag:daemon").matches(h))
    }

    @Test func privateFrameworkFilter() {
        let item = ScanItem(
            id: UUID(),
            path: "/System/Library/PrivateFrameworks/X.framework",
            name: "X",
            category: .framework,
            size: 0,
            modifiedAt: nil,
            insideBundle: false,
            owningBundlePath: nil,
            framework: FrameworkInfo(
                bundleIdentifier: nil,
                shortVersionString: nil,
                currentVersion: nil,
                executableName: nil,
                isPrivate: true
            )
        )
        let header = ItemHeader(from: item)
        #expect(SearchQuery.parse("private:true").matches(header))
        #expect(!SearchQuery.parse("private:false").matches(header))
    }

    @Test func freeTextSearchesMultipleFields() {
        let exec = ExecutableInfo(
            kind: .executable,
            architectures: ["arm64"],
            isFatBinary: false,
            isApple: true,
            isCrossPlatformTool: false,
            usageLine: "usage: ls [-AaCFGHLO@]"
        )
        let h = makeHeader(executable: exec)
        #expect(SearchQuery.parse("ls").matches(h))           // name
        #expect(SearchQuery.parse("usage").matches(h))         // usageLine
        #expect(SearchQuery.parse("/bin").matches(h))          // path
        #expect(!SearchQuery.parse("perl").matches(h))
    }

    @Test func combinedFiltersAreAnded() {
        let exec = ExecutableInfo(
            kind: .executable,
            architectures: ["arm64"],
            isFatBinary: false,
            isApple: true,
            isCrossPlatformTool: false
        )
        let h = makeHeader(executable: exec, tags: ["cli"])
        let q = SearchQuery.parse("arch:arm64 tag:cli")
        #expect(q.matches(h))
        let nope = SearchQuery.parse("arch:arm64 tag:gui")
        #expect(!nope.matches(h))
    }
}
