import Foundation

/// Top-level category — drives sidebar navigation and the UI's mental model of
/// what the scanner found. An item can belong to exactly one category; cross-
/// category relationships are expressed via references inside the detail payload.
nonisolated enum ItemCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case executable        // CLI tools and other MH_EXECUTE Mach-Os outside .app bundles
    case application       // .app bundles
    case launchService     // launchd plists (agents/daemons)
    case framework         // .framework bundles + dylibs
    case mlModel           // .mlmodel, .mlpackage, .mlmodelc
    case icon              // .icns, App icons
    case manPage           // man pages in /usr/share/man
    case localization      // .lproj / .strings / .stringsdict
    case dyldCache         // dyld_shared_cache_* files
    case kext              // .kext bundles
    case script            // shell/python/perl scripts (interpreter shebang)
    case plist             // .plist files (other than launch services)
    case configuration     // notable non-plist config files
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .executable:    return "Executables"
        case .application:   return "Applications"
        case .launchService: return "Launch Services"
        case .framework:     return "Frameworks & Libraries"
        case .mlModel:       return "ML Models"
        case .icon:          return "Images"
        case .manPage:       return "Man Pages"
        case .localization:  return "Localizations"
        case .dyldCache:     return "DYLD Shared Cache"
        case .kext:          return "Kernel Extensions"
        case .script:        return "Scripts"
        case .plist:         return "Plists"
        case .configuration: return "Configuration"
        case .other:         return "Other"
        }
    }

    var systemImageName: String {
        switch self {
        case .executable:    return "terminal"
        case .application:   return "app.dashed"
        case .launchService: return "gearshape.2"
        case .framework:     return "shippingbox"
        case .mlModel:       return "brain"
        case .icon:          return "photo.stack"
        case .manPage:       return "doc.text.magnifyingglass"
        case .localization:  return "character.bubble"
        case .dyldCache:     return "cylinder.split.1x2"
        case .kext:          return "cpu"
        case .script:        return "scroll"
        case .plist:         return "list.bullet.indent"
        case .configuration: return "slider.horizontal.3"
        case .other:         return "questionmark.folder"
        }
    }
}

/// Discriminated payload for any single discovered item. The category determines
/// which optional field is populated; that "tagged union via optionals" approach
/// keeps the manifest one-table-shaped without per-category subclassing.
///
/// Explicitly `nonisolated` because the project default isolation is
/// `@MainActor`. Without this annotation, the implicit `Codable` conformance
/// would also be MainActor-isolated, and the SQLite `Database` (which encodes
/// /decodes off the main actor) couldn't use it.
nonisolated struct ScanItem: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var path: String
    var name: String
    var category: ItemCategory
    var size: Int64
    var modifiedAt: Date?
    /// SHA-256 of the file. For directory bundles, hashes the executable inside if
    /// it has one, otherwise nil. Used to detect changes across scans.
    var sha256: String?
    /// True when the item lives inside a `.app`/`.framework`/`.bundle` wrapper.
    var insideBundle: Bool
    /// Owning bundle path, if `insideBundle` is true.
    var owningBundlePath: String?

    // Discriminated payload — exactly one is populated to match `category`.
    var executable: ExecutableInfo?
    var application: AppBundleInfo?
    var launchService: LaunchServiceInfo?
    var framework: FrameworkInfo?
    var mlModel: MLModelInfo?
    var icon: IconInfo?
    var manPage: ManPageInfo?
    var localization: LocalizationInfo?
    var dyldCache: DyldCacheInfo?
    var script: ScriptInfo?
    var plist: PlistInfo?

    /// Free-form tags surfaced as colored chips in the UI. Examples: "cli", "daemon",
    /// "cross-platform", "scripting-runtime". Cheap way to add new facets without
    /// schema changes.
    var tags: [String] = []

    /// Human-readable disambiguator surfaced next to `name` in the UI. For
    /// items inside a bundle this is the bundle's display name (e.g.
    /// "Safari" or "CoreFoundation"). For top-level items it's the parent
    /// directory or some other helpful prefix. The point: when the list shows
    /// 200 files all called `Localizable.strings`, this is what tells you which
    /// one belongs to which app at a glance.
    var context: String?

    /// Outgoing graph edges to other items in the same scan. Resolved by
    /// `targetPath` against `ScanStore.itemsByPath`. Used to render a "Related"
    /// section in the detail view and to power future graph navigation.
    var relationships: [Relationship] = []
}

nonisolated struct Relationship: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case linksDylib        // Mach-O LC_LOAD_DYLIB
        case ownedByBundle     // child of a .app / .framework / .bundle / .kext
        case launchesProgram   // LaunchService → executable it runs
        case sameBundle        // sibling within the same enclosing bundle
    }
    var kind: Kind
    /// Stable identifier — the target item's *path*. We use paths instead of
    /// UUIDs because UUIDs are regenerated each scan; paths are stable across
    /// scans which lets future diff features work.
    var targetPath: String
    /// Optional human description, e.g. "weak link", "rpath: @loader_path",
    /// "ProgramArguments[0]".
    var note: String?
}

// MARK: - Per-category payloads

nonisolated struct ExecutableInfo: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case object         // MH_OBJECT
        case executable     // MH_EXECUTE
        case dylib          // MH_DYLIB
        case bundle         // MH_BUNDLE
        case dylinker       // MH_DYLINKER (i.e. dyld)
        case kext           // MH_KEXT_BUNDLE
        case dsym
        case core
        case unknown
    }
    /// Detected role from heuristics — independent from Mach-O kind. A single
    /// MH_EXECUTE can be both a CLI and a daemon-runnable in principle.
    enum Role: String, Codable, Sendable {
        case cli            // has "usage:" / "--help" / "-h" / standard CLI markers
        case daemon         // referenced by a LaunchDaemon plist or path-heuristic match
        case agent          // referenced by a LaunchAgent plist
        case helper         // app helper inside an .app/.framework
        case library        // dylib loaded by others
        case interpreter    // perl/python/ruby/etc.
        case gui            // looks like a GUI app entry point
        case unknown
    }

    var kind: Kind
    var roles: [Role] = []
    var architectures: [String]    // e.g. ["arm64", "x86_64"]
    var isFatBinary: Bool
    var minOS: String?             // platform minOS version, if found
    var platform: String?          // "macos", "iossimulator", etc.
    var sdkVersion: String?
    var linkedLibraries: [String] = []
    var rpaths: [String] = []
    var entitlementsXML: String?
    var teamIdentifier: String?
    var signingIdentifier: String?
    var isHardenedRuntime: Bool = false
    /// True when the binary appears to be Apple's. Heuristic: under /System,
    /// or signing identity prefix com.apple.*, or path-based well-known.
    var isApple: Bool
    /// True when the binary's name matches a well-known cross-platform tool
    /// (perl, python3, ruby, awk, ...). Visible as a "cross-platform" chip.
    var isCrossPlatformTool: Bool
    /// Best-effort one-line usage summary extracted from strings — e.g. the
    /// first line that starts with "usage:" or "Usage:".
    var usageLine: String?
    /// True if the binary references launchd APIs or sd_notify-style daemon idioms.
    var looksLikeDaemonByStrings: Bool = false
    /// Reference to a strings blob for this item, if the optional strings cache
    /// was enabled at scan time.
    var stringsBlobRef: String?
}

nonisolated struct AppBundleInfo: Codable, Hashable, Sendable {
    var bundleIdentifier: String?
    var displayName: String?
    var executableName: String?
    var executablePath: String?
    var shortVersionString: String?
    var bundleVersion: String?
    var minimumSystemVersion: String?
    var category: String?          // LSApplicationCategoryType
    var isHidden: Bool             // LSUIElement / hidden from Finder
    var isAgentApp: Bool           // LSBackgroundOnly
    var iconRef: String?           // blob ref for primary icon (PNG)
    var documentTypes: [String] = []
    var urlSchemes: [String] = []
}

nonisolated struct LaunchServiceInfo: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case daemon         // /System/Library/LaunchDaemons
        case agent          // /System/Library/LaunchAgents
    }
    var kind: Kind
    var label: String?
    var program: String?           // ProgramArguments[0] or Program
    var programArguments: [String] = []
    var runAtLoad: Bool = false
    var keepAlive: Bool = false
    var userName: String?
    var groupName: String?
    var machServices: [String] = []
    var watchPaths: [String] = []
    var startInterval: Int?
    var disabled: Bool = false
}

nonisolated struct FrameworkInfo: Codable, Hashable, Sendable {
    var bundleIdentifier: String?
    var shortVersionString: String?
    var currentVersion: String?
    var executableName: String?
    var headerCount: Int = 0
    var isPrivate: Bool            // .../PrivateFrameworks/...
}

nonisolated struct MLModelInfo: Codable, Hashable, Sendable {
    enum Container: String, Codable, Sendable {
        case mlmodel        // source .mlmodel
        case mlpackage      // .mlpackage directory
        case mlmodelc       // compiled .mlmodelc directory
        case espresso       // .espresso.* CoreML internal files
        case onnx           // .onnx file
        case pytorch        // .pt / .pth
        case tflite         // .tflite
        case unknown
    }
    var container: Container
    var modelDescription: String?
    var author: String?
    var license: String?
    var modelType: String?         // pipeline / neural-network / treeensemble / ...
    var inputs: [String] = []
    var outputs: [String] = []
    var classLabelsCount: Int?
    /// Best guess at what the model does, from its description / labels.
    var inferredPurpose: String?
}

nonisolated struct IconInfo: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case icns           // .icns Apple icon file
        case carAsset       // Assets.car (asset catalog)
        case image          // standalone .png / .tiff
    }
    var kind: Kind
    var representations: [String] = []   // e.g. "1024x1024", "ic08"
    /// Blob ref to a rendered preview PNG, when we managed to render one.
    var previewBlobRef: String?
}

nonisolated struct ManPageInfo: Codable, Hashable, Sendable {
    var section: String?           // "1", "8", etc.
    var title: String?             // NAME line first token
    var description: String?       // NAME line, the part after the dash
    /// True if the file is gzipped (man pages on macOS are usually .gz).
    var compressed: Bool
}

nonisolated struct LocalizationInfo: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case strings        // .strings
        case stringsdict    // .stringsdict
        case lproj          // .lproj directory
    }
    var kind: Kind
    var language: String?          // e.g. "en", "fr", "Base"
    var keyCount: Int?
    var owningBundleId: String?
}

nonisolated struct DyldCacheInfo: Codable, Hashable, Sendable {
    var architecture: String?      // x86_64, arm64, arm64e
    var formatVersion: String?     // "dyld_v1 ..."
    var imageCount: Int?
    var mappingCount: Int?
}

nonisolated struct ScriptInfo: Codable, Hashable, Sendable {
    var interpreter: String?       // /bin/bash, /usr/bin/env perl, ...
    var language: String?          // bash / python / perl / ruby / ...
    var lineCount: Int?
}

nonisolated struct PlistInfo: Codable, Hashable, Sendable {
    /// Best-effort classification by filename / location, used to drive the
    /// "Kind" tag in the UI without re-parsing.
    enum Kind: String, Codable, Sendable {
        case info               // Info.plist (bundle metadata)
        case version            // Version.plist (in frameworks)
        case launchService      // a launchd plist *outside* /System/Library/LaunchDaemons|Agents
        case preference         // Preferences/*.plist
        case entitlements       // *.entitlements
        case mappedTypes        // UTI / declared-types plist
        case other
    }
    enum Format: String, Codable, Sendable {
        case xml
        case binary
        case json               // some "plists" on macOS are JSON
        case unknown
    }
    enum TopLevel: String, Codable, Sendable {
        case dictionary
        case array
        case other
    }
    var kind: Kind
    var format: Format
    var topLevel: TopLevel
    var keyCount: Int?              // top-level key count for dicts
    var elementCount: Int?          // top-level count for arrays
    /// XML/JSON-encoded snippet of the top of the plist for display. Empty for
    /// huge plists; we cap to a sensible read size at scan time.
    var previewText: String?
    /// True when the plist's top-level dictionary has a key like "CFBundleIdentifier".
    var looksLikeInfoPlist: Bool
}
