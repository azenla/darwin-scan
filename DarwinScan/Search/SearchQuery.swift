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
nonisolated struct SearchQuery: Equatable, Sendable {
    var freeText: String = ""
    var filters: [Filter] = []

    var isEmpty: Bool { freeText.isEmpty && filters.isEmpty }

    enum Filter: Equatable, Sendable, Hashable {
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

        /// User-facing label for the filter chip shown under the search box.
        var displayLabel: String {
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
            }
        }

        var systemImage: String {
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
            }
        }
    }

    // MARK: - Parsing

    static func parse(_ input: String) -> SearchQuery {
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
    func matches(_ header: ItemHeader) -> Bool {
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
        }
    }
}

/// Static reference list shown in the search help popover.
enum SearchHelp {
    struct Entry: Identifiable {
        var id: String { field }
        let field: String
        let example: String
        let description: String
    }

    static let entries: [Entry] = [
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
    ]
}
