import Foundation

/// Faceted search query over `ScanItem`s. Console.app-style syntax: typed
/// `field:value` filters combined with free text, AND semantics across all
/// terms.
///
/// Syntax:
/// ```
/// foo                          # free-text: substring of name / path / context / tags / usage / bundle id
/// arch:x86_64                  # architecture chip on Mach-O
/// app:Time Machine             # value is a substring; spaces OK
/// app:"Music"                  # quoted if you need a tighter match
/// bundle:something.kext        # match any kind of bundle name
/// framework:CoreFoundation
/// kext:AppleAPFS
/// lang:en
/// platform:macos
/// tag:cli
/// category:executable
/// role:daemon
/// apple:true / apple:false     # is the binary Apple-shipped
/// fat:true                     # universal/FAT Mach-O
/// cross-platform:true          # interpreter or well-known portable tool
/// private:true                 # private framework
/// min:14.0                     # minimum OS version contains "14.0"
/// ```
///
/// Multiple tokens are AND-combined. Quoting `"like this"` keeps spaces
/// inside a value. Unknown `field:value` pairs fall through to free text so
/// users don't get silently filtered to zero results.
/// `nonisolated` so off-main work (e.g. `ItemListView`'s background filter
/// pass) can call `matches(_:)` without an actor hop. The struct is a pure
/// value type — no MainActor state — so this is a no-op semantically.
public nonisolated struct SearchQuery: Equatable, Sendable {
    public var freeText: String = ""
    public var filters: [Filter] = []

    public init(freeText: String = "", filters: [Filter] = []) {
        self.freeText = freeText
        self.filters = filters
    }

    public var isEmpty: Bool { freeText.isEmpty && filters.isEmpty }

    public enum Filter: Equatable, Sendable, Hashable {
        case architecture(String)
        case bundle(String)
        case app(String)
        case kext(String)
        case framework(String)
        case language(String)
        case platform(String)
        case tag(String)
        case category(ItemCategory)
        case role(ExecutableInfo.Role)
        case apple(Bool)
        case crossPlatform(Bool)
        case fat(Bool)
        case privateBundle(Bool)
        case minOS(String)
        /// FTS5-backed: matches items whose symbol table contains `value`.
        /// Resolved via `symbols_fts` and turned into a Set<UUID> of allowed
        /// items by `resolveFTSItemIDs(against:)` before the per-item filter
        /// pass runs.
        case symbol(String)
        /// FTS5-backed: matches items whose strings dump (when extracted)
        /// contains `value`. Same resolution path as `.symbol`.
        case strings(String)

        /// User-facing label for the filter chip shown under the search box.
        public var displayLabel: String {
            switch self {
            case .architecture(let v):  return "Arch: \(v)"
            case .bundle(let v):        return "Bundle: \(v)"
            case .app(let v):           return "App: \(v)"
            case .kext(let v):          return "Kext: \(v)"
            case .framework(let v):     return "Framework: \(v)"
            case .language(let v):      return "Lang: \(v)"
            case .platform(let v):      return "Platform: \(v)"
            case .tag(let v):           return "Tag: \(v)"
            case .category(let c):      return "Category: \(c.displayName)"
            case .role(let r):          return "Role: \(r.rawValue)"
            case .apple(let b):         return b ? "Apple" : "Non-Apple"
            case .crossPlatform(let b): return b ? "Cross-platform" : "Apple-only"
            case .fat(let b):           return b ? "Fat" : "Single-arch"
            case .privateBundle(let b): return b ? "Private" : "Public"
            case .minOS(let v):         return "minOS: \(v)"
            case .symbol(let v):        return "Symbol: \(v)"
            case .strings(let v):       return "Strings: \(v)"
            }
        }

        public var systemImage: String {
            switch self {
            case .architecture: return "cpu"
            case .bundle:       return "shippingbox"
            case .app:          return "app.dashed"
            case .kext:         return "cpu.fill"
            case .framework:    return "shippingbox.fill"
            case .language:     return "character.bubble"
            case .platform:     return "macbook"
            case .tag:          return "tag"
            case .category:     return "folder"
            case .role:         return "person.crop.square"
            case .apple:        return "apple.logo"
            case .crossPlatform: return "arrow.triangle.2.circlepath"
            case .fat:          return "rectangle.split.2x1"
            case .privateBundle: return "lock"
            case .minOS:        return "circle.dashed"
            case .symbol:       return "function"
            case .strings:      return "text.magnifyingglass"
            }
        }
    }

    // MARK: - Parsing

    public static func parse(_ input: String) -> SearchQuery {
        var query = SearchQuery()
        let tokens = tokenize(input)
        var freeTextParts: [String] = []
        for token in tokens {
            if let (field, value) = splitFieldValue(token),
               let filter = filter(field: field, value: value) {
                query.filters.append(filter)
            } else {
                freeTextParts.append(token)
            }
        }
        query.freeText = freeTextParts.joined(separator: " ")
        return query
    }

    /// Split input on whitespace, respecting `"quoted strings"` so values
    /// with spaces work. Quotes are stripped from the output tokens.
    private static func tokenize(_ input: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        for ch in input {
            if ch == "\"" { inQuotes.toggle(); continue }
            if ch.isWhitespace && !inQuotes {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Find the first colon that separates a recognized field name from a
    /// value. We require the field side to be non-empty, alphanumeric (with
    /// dashes), and at most ~16 chars so paths like `/usr/bin:foo` don't get
    /// misread. The value side may be empty (treated as no-op filter).
    private static func splitFieldValue(_ token: String) -> (String, String)? {
        guard let colonIdx = token.firstIndex(of: ":") else { return nil }
        let fieldPart = token[..<colonIdx]
        let valuePart = token[token.index(after: colonIdx)...]
        guard !fieldPart.isEmpty, fieldPart.count <= 16 else { return nil }
        for ch in fieldPart {
            if !(ch.isLetter || ch == "-" || ch == "_") { return nil }
        }
        return (String(fieldPart).lowercased(), String(valuePart))
    }

    private static func filter(field: String, value: String) -> Filter? {
        switch field {
        case "arch", "architecture", "abi":
            return .architecture(value)
        case "app":
            return .app(value)
        case "bundle":
            return .bundle(value)
        case "kext", "extension":
            return .kext(value)
        case "framework", "fw":
            return .framework(value)
        case "lang", "language", "locale":
            return .language(value)
        case "platform", "os":
            return .platform(value)
        case "tag":
            return .tag(value)
        case "cat", "category":
            if let c = ItemCategory.allCases.first(where: {
                $0.rawValue.lowercased() == value.lowercased() ||
                $0.displayName.lowercased() == value.lowercased()
            }) {
                return .category(c)
            }
            return nil
        case "role":
            if let r = ExecutableInfo.Role(rawValue: value.lowercased()) {
                return .role(r)
            }
            return nil
        case "apple":
            return .apple(parseBool(value))
        case "cross", "cross-platform", "crossplatform":
            return .crossPlatform(parseBool(value))
        case "fat", "universal":
            return .fat(parseBool(value))
        case "private":
            return .privateBundle(parseBool(value))
        case "min", "minos":
            return .minOS(value)
        case "symbol", "sym":
            return .symbol(value)
        case "strings", "str":
            return .strings(value)
        default:
            return nil
        }
    }

    private static func parseBool(_ s: String) -> Bool {
        ["true", "yes", "y", "1"].contains(s.lowercased())
    }

    // MARK: - Evaluation

    /// True when the header satisfies every filter AND (if non-empty) the
    /// free-text term is found in one of the searchable fields. Operates on
    /// `ItemHeader` rather than `ScanItem` so a global filter over a /System
    /// scan never has to fetch full payloads from SQLite.
    ///
    /// Uses `lowercasedName` (cached on the header) and lowercases other
    /// fields lazily — typical items don't have all of them set.
    public func matches(_ header: ItemHeader) -> Bool {
        for filter in filters {
            if !evaluate(filter, against: header) { return false }
        }
        guard !freeText.isEmpty else { return true }
        let q = freeText.lowercased()
        if header.lowercasedName.contains(q) { return true }
        if header.path.lowercased().contains(q) { return true }
        if let ctx = header.context?.lowercased(), ctx.contains(q) { return true }
        for tag in header.tags { if tag.lowercased().contains(q) { return true } }
        if let usage = header.usageLine?.lowercased(), usage.contains(q) { return true }
        if let bundleID = header.bundleIdentifier?.lowercased(), bundleID.contains(q) { return true }
        if let label = header.launchServiceLabel?.lowercased(), label.contains(q) { return true }
        return false
    }

    private func evaluate(_ filter: Filter, against header: ItemHeader) -> Bool {
        switch filter {
        case .architecture(let val):
            let v = val.lowercased()
            return header.architectures.contains { $0.lowercased().contains(v) }

        case .app(let val):
            let v = val.lowercased()
            // The item itself is the app, or one of its ancestors is.
            if header.category == .application, header.lowercasedName.contains(v) { return true }
            if let owning = header.owningBundlePath?.lowercased(),
               owning.contains(".app/") || owning.hasSuffix(".app") {
                let base = ((owning as NSString).lastPathComponent)
                if base.contains(v) { return true }
            }
            return false

        case .bundle(let val):
            let v = val.lowercased()
            if let owning = header.owningBundlePath {
                let base = ((owning as NSString).lastPathComponent).lowercased()
                if base.contains(v) { return true }
            }
            if [.application, .framework, .kext].contains(header.category) {
                let base = ((header.path as NSString).lastPathComponent).lowercased()
                if base.contains(v) { return true }
            }
            return false

        case .kext(let val):
            let v = val.lowercased()
            if header.category == .kext, header.lowercasedName.contains(v) { return true }
            if let owning = header.owningBundlePath?.lowercased(), owning.contains(".kext") {
                let base = ((owning as NSString).lastPathComponent).lowercased()
                if base.contains(v) { return true }
            }
            return false

        case .framework(let val):
            let v = val.lowercased()
            if header.category == .framework, header.lowercasedName.contains(v) { return true }
            if let owning = header.owningBundlePath?.lowercased(), owning.contains(".framework") {
                let base = ((owning as NSString).lastPathComponent).lowercased()
                if base.contains(v) { return true }
            }
            return false

        case .language(let val):
            let v = val.lowercased()
            if let lang = header.language?.lowercased(), lang == v || lang.contains(v) {
                return true
            }
            return false

        case .platform(let val):
            return header.platform?.lowercased().contains(val.lowercased()) ?? false

        case .tag(let val):
            let v = val.lowercased()
            return header.tags.contains { $0.lowercased() == v || $0.lowercased().contains(v) }

        case .category(let c):
            return header.category == c

        case .role(let r):
            return header.roles.contains(r)

        case .apple(let want):
            return header.isApple == want

        case .crossPlatform(let want):
            return header.isCrossPlatformTool == want

        case .fat(let want):
            return header.isFatBinary == want

        case .privateBundle(let want):
            return header.isPrivateFramework == want

        case .minOS(let val):
            return header.minOS?.contains(val) ?? false

        case .symbol, .strings:
            // FTS-backed filters are answered by `resolveFTSItemIDs` before
            // this per-item pass runs. By the time we get here, the caller
            // has already restricted the input set to items whose IDs
            // appear in the resolved set — so any item we evaluate has
            // already passed the filter. (We could also assert here but
            // SearchQuery is used in performance-sensitive paths, and
            // accepting the row is correct given the precondition.)
            return true
        }
    }

    // MARK: - FTS resolution

    /// True if the query contains any FTS-backed filter (`symbol:` /
    /// `strings:`). Callers use this to decide whether to do the FTS
    /// resolution pass at all.
    public var hasFTSFilters: Bool {
        for f in filters {
            switch f {
            case .symbol, .strings: return true
            default: continue
            }
        }
        return false
    }

    /// Resolve every FTS-backed filter in this query into a `Set<UUID>` of
    /// allowed item IDs. Returns `nil` if there are no FTS filters at all
    /// (the caller should then skip the restriction). When multiple FTS
    /// filters are present (e.g. `symbol:foo strings:bar`), the returned
    /// set is the **intersection** — same AND semantics as the rest of the
    /// filter pipeline.
    public func resolveFTSItemIDs(against store: ScanStore) -> Set<UUID>? {
        guard let database = store.database, hasFTSFilters else { return nil }
        var accumulated: Set<UUID>? = nil
        for f in filters {
            let hits: [UUID]
            switch f {
            case .symbol(let v):
                guard let q = ftsPrefixMatch(for: v) else { continue }
                let rows = (try? database.searchSymbols(query: q, limit: 5000)) ?? []
                hits = rows.map(\.itemID)
            case .strings(let v):
                guard let q = ftsPrefixMatch(for: v) else { continue }
                let rows = (try? database.searchStrings(query: q, limit: 5000)) ?? []
                hits = rows.map(\.itemID)
            default:
                continue
            }
            let asSet = Set(hits)
            if let prev = accumulated {
                accumulated = prev.intersection(asSet)
            } else {
                accumulated = asSet
            }
        }
        return accumulated
    }

    /// Build an FTS5 prefix-match MATCH expression for a user-supplied value,
    /// or `nil` when the value has no tokenizable content (empty, whitespace,
    /// or punctuation-only).
    ///
    /// Wrapping the value in a double-quoted phrase makes reserved characters
    /// (`AND`, `OR`, `NOT`, `:`, `^`, parens) literal; FTS5 has no escape for
    /// an embedded double quote, so those are stripped. A trailing `*` turns
    /// the last token into a prefix match (`"NSURL"*` matches `NSURLSession` —
    /// verified against FTS5).
    ///
    /// Returning `nil` for no-token input is the important part: an empty or
    /// punctuation-only MATCH matches zero rows, and the caller *intersects*
    /// FTS results into the allowed-id set — so a stray `symbol:` would
    /// otherwise blank the entire list. The caller skips the filter instead.
    private func ftsPrefixMatch(for value: String) -> String? {
        let cleaned = value.replacingOccurrences(of: "\"", with: "")
        guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return "\"\(cleaned)\"*"
    }
}

/// Static reference list shown in the search help popover.
public enum SearchHelp {
    public struct Entry: Identifiable, Sendable {
        public var id: String { field }
        public let field: String
        public let example: String
        public let description: String

        public init(field: String, example: String, description: String) {
            self.field = field
            self.example = example
            self.description = description
        }
    }

    public static let entries: [Entry] = [
        Entry(field: "arch",       example: "arch:x86_64",        description: "Mach-O architecture (arm64, arm64e, x86_64, …)"),
        Entry(field: "app",        example: "app:Time Machine",   description: "Items inside an .app bundle whose name contains this"),
        Entry(field: "bundle",     example: "bundle:CoreFoundation", description: "Items inside any kind of bundle (.app/.framework/.kext/…)"),
        Entry(field: "framework",  example: "framework:AppKit",   description: "Items inside a .framework"),
        Entry(field: "kext",       example: "kext:AppleAPFS",     description: "Items inside a .kext"),
        Entry(field: "lang",       example: "lang:en",            description: "Localization language code"),
        Entry(field: "platform",   example: "platform:macos",     description: "Mach-O build platform"),
        Entry(field: "tag",        example: "tag:cli",            description: "Any tag on the item (cli, daemon, fat, arm64, …)"),
        Entry(field: "category",   example: "category:executable", description: "Restrict to a single category"),
        Entry(field: "role",       example: "role:daemon",        description: "Detected role (cli, daemon, agent, helper, library, …)"),
        Entry(field: "apple",      example: "apple:true",         description: "Apple-shipped binaries only / non-Apple only"),
        Entry(field: "cross",      example: "cross:true",         description: "Well-known cross-platform tools (perl, python, …)"),
        Entry(field: "fat",        example: "fat:true",           description: "Universal Mach-O binaries"),
        Entry(field: "private",    example: "private:true",       description: "Private framework"),
        Entry(field: "min",        example: "min:14.0",           description: "Minimum OS version contains this string"),
        Entry(field: "symbol",     example: "symbol:NSURL",       description: "FTS5: items whose symbol table contains the given term (prefix match)"),
        Entry(field: "strings",    example: "strings:libcurl",    description: "FTS5: items whose extracted strings dump contains the given term"),
    ]
}
