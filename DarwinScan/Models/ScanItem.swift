import Foundation

/// Top-level category — drives sidebar navigation and the UI's mental model of
/// what the scanner found. An item can belong to exactly one category; cross-
/// category relationships are expressed via references inside the detail payload.
enum ItemCategory: String, Codable, CaseIterable, Identifiable, Sendable {
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
    case configuration     // notable plists & config files
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .executable:    return "Executables"
        case .application:   return "Applications"
        case .launchService: return "Launch Services"
        case .framework:     return "Frameworks & Libraries"
        case .mlModel:       return "ML Models"
        case .icon:          return "Icons"
        case .manPage:       return "Man Pages"
        case .localization:  return "Localizations"
        case .dyldCache:     return "DYLD Shared Cache"
        case .kext:          return "Kernel Extensions"
        case .script:        return "Scripts"
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
        case .icon:          return "photo.on.rectangle.angled"
        case .manPage:       return "doc.text.magnifyingglass"
        case .localization:  return "character.bubble"
        case .dyldCache:     return "cylinder.split.1x2"
        case .kext:          return "cpu"
        case .script:        return "scroll"
        case .configuration: return "slider.horizontal.3"
        case .other:         return "questionmark.folder"
        }
    }
}

/// Discriminated payload for any single discovered item. The category determines
/// which optional field is populated; that "tagged union via optionals" approach
/// keeps the manifest one-table-shaped without per-category subclassing.
struct ScanItem: Codable, Identifiable, Hashable, Sendable {
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

    /// Free-form tags surfaced as colored chips in the UI. Examples: "cli", "daemon",
    /// "cross-platform", "scripting-runtime". Cheap way to add new facets without
    /// schema changes.
    var tags: [String] = []
}

// MARK: - Per-category payloads

struct ExecutableInfo: Codable, Hashable, Sendable {
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

struct AppBundleInfo: Codable, Hashable, Sendable {
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

struct LaunchServiceInfo: Codable, Hashable, Sendable {
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

struct FrameworkInfo: Codable, Hashable, Sendable {
    var bundleIdentifier: String?
    var shortVersionString: String?
    var currentVersion: String?
    var executableName: String?
    var headerCount: Int = 0
    var isPrivate: Bool            // .../PrivateFrameworks/...
}

struct MLModelInfo: Codable, Hashable, Sendable {
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

struct IconInfo: Codable, Hashable, Sendable {
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

struct ManPageInfo: Codable, Hashable, Sendable {
    var section: String?           // "1", "8", etc.
    var title: String?             // NAME line first token
    var description: String?       // NAME line, the part after the dash
    /// True if the file is gzipped (man pages on macOS are usually .gz).
    var compressed: Bool
}

struct LocalizationInfo: Codable, Hashable, Sendable {
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

struct DyldCacheInfo: Codable, Hashable, Sendable {
    var architecture: String?      // x86_64, arm64, arm64e
    var formatVersion: String?     // "dyld_v1 ..."
    var imageCount: Int?
    var mappingCount: Int?
}

struct ScriptInfo: Codable, Hashable, Sendable {
    var interpreter: String?       // /bin/bash, /usr/bin/env perl, ...
    var language: String?          // bash / python / perl / ruby / ...
    var lineCount: Int?
}
