import Foundation

/// Top-level category — drives sidebar navigation and the UI's mental model of
/// what the scanner found. An item can belong to exactly one category; cross-
/// category relationships are expressed via references inside the detail payload.
public nonisolated enum ItemCategory: String, Codable, CaseIterable, Identifiable, Sendable {
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

    public var id: String { rawValue }

    public var displayName: String {
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

    public var systemImageName: String {
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
public nonisolated struct ScanItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var path: String
    public var name: String
    public var category: ItemCategory
    public var size: Int64
    public var modifiedAt: Date?
    /// SHA-256 of the file. For directory bundles, hashes the executable inside if
    /// it has one, otherwise nil. Used to detect changes across scans.
    public var sha256: String?
    /// True when the item lives inside a `.app`/`.framework`/`.bundle` wrapper.
    public var insideBundle: Bool
    /// Owning bundle path, if `insideBundle` is true.
    public var owningBundlePath: String?

    /// Optional content-addressed reference to the original file bytes, copied
    /// verbatim into the blob store. Populated when `ScanOptions.captureFiles`
    /// is on. Lets a future `darwin-scan extract` reconstruct the source tree
    /// from a `.darwinscan` bundle.
    public var fileBlobRef: String?

    // Discriminated payload — exactly one is populated to match `category`.
    public var executable: ExecutableInfo?
    public var application: AppBundleInfo?
    public var launchService: LaunchServiceInfo?
    public var framework: FrameworkInfo?
    public var mlModel: MLModelInfo?
    public var icon: IconInfo?
    public var manPage: ManPageInfo?
    public var localization: LocalizationInfo?
    public var dyldCache: DyldCacheInfo?
    public var script: ScriptInfo?
    public var plist: PlistInfo?

    /// Free-form tags surfaced as colored chips in the UI.
    public var tags: [String] = []

    /// Human-readable disambiguator surfaced next to `name` in the UI.
    public var context: String?

    /// Outgoing graph edges to other items in the same scan.
    public var relationships: [Relationship] = []

    public init(
        id: UUID,
        path: String,
        name: String,
        category: ItemCategory,
        size: Int64,
        modifiedAt: Date?,
        sha256: String? = nil,
        insideBundle: Bool,
        owningBundlePath: String?,
        fileBlobRef: String? = nil,
        executable: ExecutableInfo? = nil,
        application: AppBundleInfo? = nil,
        launchService: LaunchServiceInfo? = nil,
        framework: FrameworkInfo? = nil,
        mlModel: MLModelInfo? = nil,
        icon: IconInfo? = nil,
        manPage: ManPageInfo? = nil,
        localization: LocalizationInfo? = nil,
        dyldCache: DyldCacheInfo? = nil,
        script: ScriptInfo? = nil,
        plist: PlistInfo? = nil,
        tags: [String] = [],
        context: String? = nil,
        relationships: [Relationship] = []
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.category = category
        self.size = size
        self.modifiedAt = modifiedAt
        self.sha256 = sha256
        self.insideBundle = insideBundle
        self.owningBundlePath = owningBundlePath
        self.fileBlobRef = fileBlobRef
        self.executable = executable
        self.application = application
        self.launchService = launchService
        self.framework = framework
        self.mlModel = mlModel
        self.icon = icon
        self.manPage = manPage
        self.localization = localization
        self.dyldCache = dyldCache
        self.script = script
        self.plist = plist
        self.tags = tags
        self.context = context
        self.relationships = relationships
    }
}

public nonisolated struct Relationship: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case linksDylib
        case ownedByBundle
        case launchesProgram
        case sameBundle
        /// Virtual dylib image residing inside a dyld_shared_cache_* file.
        /// `targetPath` is the on-disk cache file (e.g.
        /// `/System/Volumes/Preboot/.../dyld_shared_cache_arm64e`); the
        /// `source` item is the virtual framework item synthesized from
        /// the cache's image table.
        case inDyldCache
        /// The opposite direction of `inDyldCache` — the cache file points
        /// at each image it contains. Useful for the cache's detail panel
        /// to list everything it ships.
        case containsImage
        /// Bundle (`.app` / `.framework` / `.kext`) points at the
        /// executable Mach-O it wraps. `targetPath` is the on-disk path
        /// of the executable; for an app it's `Contents/MacOS/<name>`,
        /// for a framework `Versions/A/<name>` (versioned) or `<name>`
        /// (unversioned), for a kext `Contents/MacOS/<name>`. The
        /// inspector emits multiple candidates when the layout is
        /// ambiguous — at most one will resolve to an item in the scan.
        case containsExecutable
    }
    public var kind: Kind
    public var targetPath: String
    public var note: String?

    public init(kind: Kind, targetPath: String, note: String? = nil) {
        self.kind = kind
        self.targetPath = targetPath
        self.note = note
    }
}

// MARK: - Per-category payloads

public nonisolated struct ExecutableInfo: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case object
        case executable
        case dylib
        case bundle
        case dylinker
        case kext
        case dsym
        case core
        case unknown
    }
    public enum Role: String, Codable, Sendable {
        case cli
        case daemon
        case agent
        case helper
        case library
        case interpreter
        case gui
        case unknown
    }

    public var kind: Kind
    public var roles: [Role] = []
    public var architectures: [String]
    public var isFatBinary: Bool
    public var minOS: String?
    public var platform: String?
    public var sdkVersion: String?
    public var linkedLibraries: [String] = []
    public var rpaths: [String] = []
    public var entitlementsXML: String?
    public var teamIdentifier: String?
    public var signingIdentifier: String?
    public var isHardenedRuntime: Bool = false
    public var isApple: Bool
    public var isCrossPlatformTool: Bool
    public var usageLine: String?
    public var looksLikeDaemonByStrings: Bool = false
    public var stringsBlobRef: String?
    /// Offset of the LC_CODE_SIGNATURE blob relative to the slice's start.
    /// `Scanner` combines this with `MachOInspector.sliceFileOffset(for:)`
    /// to get a file-absolute offset and hand it to `CodeSignatureInspector`.
    public var codeSignatureSliceOffset: UInt64?
    public var codeSignatureSize: UInt64?

    public init(
        kind: Kind,
        roles: [Role] = [],
        architectures: [String],
        isFatBinary: Bool,
        minOS: String? = nil,
        platform: String? = nil,
        sdkVersion: String? = nil,
        linkedLibraries: [String] = [],
        rpaths: [String] = [],
        entitlementsXML: String? = nil,
        teamIdentifier: String? = nil,
        signingIdentifier: String? = nil,
        isHardenedRuntime: Bool = false,
        isApple: Bool,
        isCrossPlatformTool: Bool,
        usageLine: String? = nil,
        looksLikeDaemonByStrings: Bool = false,
        stringsBlobRef: String? = nil,
        codeSignatureSliceOffset: UInt64? = nil,
        codeSignatureSize: UInt64? = nil
    ) {
        self.kind = kind
        self.roles = roles
        self.architectures = architectures
        self.isFatBinary = isFatBinary
        self.minOS = minOS
        self.platform = platform
        self.sdkVersion = sdkVersion
        self.linkedLibraries = linkedLibraries
        self.rpaths = rpaths
        self.entitlementsXML = entitlementsXML
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
        self.isHardenedRuntime = isHardenedRuntime
        self.isApple = isApple
        self.isCrossPlatformTool = isCrossPlatformTool
        self.usageLine = usageLine
        self.looksLikeDaemonByStrings = looksLikeDaemonByStrings
        self.stringsBlobRef = stringsBlobRef
        self.codeSignatureSliceOffset = codeSignatureSliceOffset
        self.codeSignatureSize = codeSignatureSize
    }
}

public nonisolated struct AppBundleInfo: Codable, Hashable, Sendable {
    public var bundleIdentifier: String?
    public var displayName: String?
    public var executableName: String?
    public var executablePath: String?
    public var shortVersionString: String?
    public var bundleVersion: String?
    public var minimumSystemVersion: String?
    public var category: String?
    public var isHidden: Bool
    public var isAgentApp: Bool
    public var iconRef: String?
    public var documentTypes: [String] = []
    public var urlSchemes: [String] = []

    public init(
        bundleIdentifier: String?,
        displayName: String?,
        executableName: String?,
        executablePath: String?,
        shortVersionString: String?,
        bundleVersion: String?,
        minimumSystemVersion: String?,
        category: String?,
        isHidden: Bool,
        isAgentApp: Bool,
        iconRef: String?,
        documentTypes: [String] = [],
        urlSchemes: [String] = []
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.executableName = executableName
        self.executablePath = executablePath
        self.shortVersionString = shortVersionString
        self.bundleVersion = bundleVersion
        self.minimumSystemVersion = minimumSystemVersion
        self.category = category
        self.isHidden = isHidden
        self.isAgentApp = isAgentApp
        self.iconRef = iconRef
        self.documentTypes = documentTypes
        self.urlSchemes = urlSchemes
    }
}

public nonisolated struct LaunchServiceInfo: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case daemon
        case agent
    }
    public var kind: Kind
    public var label: String?
    public var program: String?
    public var programArguments: [String] = []
    public var runAtLoad: Bool = false
    public var keepAlive: Bool = false
    public var userName: String?
    public var groupName: String?
    public var machServices: [String] = []
    public var watchPaths: [String] = []
    public var startInterval: Int?
    public var disabled: Bool = false

    public init(
        kind: Kind,
        label: String?,
        program: String?,
        programArguments: [String] = [],
        runAtLoad: Bool = false,
        keepAlive: Bool = false,
        userName: String? = nil,
        groupName: String? = nil,
        machServices: [String] = [],
        watchPaths: [String] = [],
        startInterval: Int? = nil,
        disabled: Bool = false
    ) {
        self.kind = kind
        self.label = label
        self.program = program
        self.programArguments = programArguments
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.userName = userName
        self.groupName = groupName
        self.machServices = machServices
        self.watchPaths = watchPaths
        self.startInterval = startInterval
        self.disabled = disabled
    }
}

public nonisolated struct FrameworkInfo: Codable, Hashable, Sendable {
    public var bundleIdentifier: String?
    public var shortVersionString: String?
    public var currentVersion: String?
    public var executableName: String?
    public var headerCount: Int = 0
    public var isPrivate: Bool

    public init(
        bundleIdentifier: String?,
        shortVersionString: String?,
        currentVersion: String?,
        executableName: String?,
        headerCount: Int = 0,
        isPrivate: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.shortVersionString = shortVersionString
        self.currentVersion = currentVersion
        self.executableName = executableName
        self.headerCount = headerCount
        self.isPrivate = isPrivate
    }
}

public nonisolated struct MLModelInfo: Codable, Hashable, Sendable {
    public enum Container: String, Codable, Sendable {
        case mlmodel
        case mlpackage
        case mlmodelc
        case espresso
        case onnx
        case pytorch
        case tflite
        case unknown
    }
    public var container: Container
    public var modelDescription: String?
    public var author: String?
    public var license: String?
    public var modelType: String?
    public var inputs: [String] = []
    public var outputs: [String] = []
    public var classLabelsCount: Int?
    public var inferredPurpose: String?

    public init(
        container: Container,
        modelDescription: String? = nil,
        author: String? = nil,
        license: String? = nil,
        modelType: String? = nil,
        inputs: [String] = [],
        outputs: [String] = [],
        classLabelsCount: Int? = nil,
        inferredPurpose: String? = nil
    ) {
        self.container = container
        self.modelDescription = modelDescription
        self.author = author
        self.license = license
        self.modelType = modelType
        self.inputs = inputs
        self.outputs = outputs
        self.classLabelsCount = classLabelsCount
        self.inferredPurpose = inferredPurpose
    }
}

public nonisolated struct IconInfo: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case icns
        case carAsset
        case image
    }
    public var kind: Kind
    public var representations: [String] = []
    public var previewBlobRef: String?

    public init(kind: Kind, representations: [String] = [], previewBlobRef: String? = nil) {
        self.kind = kind
        self.representations = representations
        self.previewBlobRef = previewBlobRef
    }
}

public nonisolated struct ManPageInfo: Codable, Hashable, Sendable {
    public var section: String?
    public var title: String?
    public var description: String?
    public var compressed: Bool

    public init(section: String?, title: String?, description: String?, compressed: Bool) {
        self.section = section
        self.title = title
        self.description = description
        self.compressed = compressed
    }
}

public nonisolated struct LocalizationInfo: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case strings
        case stringsdict
        case lproj
    }
    public var kind: Kind
    public var language: String?
    public var keyCount: Int?
    public var owningBundleId: String?

    public init(kind: Kind, language: String?, keyCount: Int?, owningBundleId: String?) {
        self.kind = kind
        self.language = language
        self.keyCount = keyCount
        self.owningBundleId = owningBundleId
    }
}

public nonisolated struct DyldCacheInfo: Codable, Hashable, Sendable {
    public var architecture: String?
    public var formatVersion: String?
    public var imageCount: Int?
    public var mappingCount: Int?
    /// Number of `dyld_subcache_entry` records in this cache. For a split
    /// cache, this counts the subcaches; for a single-file cache it's 0.
    /// Nil if the inspector couldn't read deep enough into the header.
    public var subCacheCount: Int?

    public init(
        architecture: String?,
        formatVersion: String?,
        imageCount: Int?,
        mappingCount: Int?,
        subCacheCount: Int? = nil
    ) {
        self.architecture = architecture
        self.formatVersion = formatVersion
        self.imageCount = imageCount
        self.mappingCount = mappingCount
        self.subCacheCount = subCacheCount
    }
}

public nonisolated struct ScriptInfo: Codable, Hashable, Sendable {
    public var interpreter: String?
    public var language: String?
    public var lineCount: Int?

    public init(interpreter: String?, language: String?, lineCount: Int?) {
        self.interpreter = interpreter
        self.language = language
        self.lineCount = lineCount
    }
}

/// Slim in-memory projection of a `ScanItem`. The runtime store keeps one
/// of these per item rather than the full payload — for a /System scan
/// that's a ~5-10× cut in RAM because the heavy fields (relationships,
/// `executable.linkedLibraries`, large per-category payloads) stay in
/// SQLite and are loaded only when the detail view actually needs them.
public nonisolated struct ItemHeader: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var path: String
    public var name: String
    public var lowercasedName: String
    public var category: ItemCategory
    public var size: Int64
    public var modifiedAt: Date?
    public var sha256: String?
    public var insideBundle: Bool
    public var owningBundlePath: String?
    public var tags: [String]
    public var context: String?

    public var architectures: [String]
    public var platform: String?
    public var usageLine: String?
    public var bundleIdentifier: String?
    public var launchServiceLabel: String?
    public var language: String?
    public var minOS: String?
    public var roles: [ExecutableInfo.Role]
    public var isApple: Bool
    public var isCrossPlatformTool: Bool
    public var isFatBinary: Bool
    public var isPrivateFramework: Bool

    public init(from item: ScanItem) {
        self.id = item.id
        self.path = item.path
        self.name = item.name
        self.lowercasedName = item.name.lowercased()
        self.category = item.category
        self.size = item.size
        self.modifiedAt = item.modifiedAt
        self.sha256 = item.sha256
        self.insideBundle = item.insideBundle
        self.owningBundlePath = item.owningBundlePath
        self.tags = item.tags
        self.context = item.context

        self.architectures        = item.executable?.architectures ?? []
        self.platform             = item.executable?.platform
        self.usageLine            = item.executable?.usageLine
        self.bundleIdentifier     = item.application?.bundleIdentifier
        self.launchServiceLabel   = item.launchService?.label
        self.language             = item.localization?.language
        self.minOS                = item.executable?.minOS
        self.roles                = item.executable?.roles ?? []
        self.isApple              = item.executable?.isApple ?? false
        self.isCrossPlatformTool  = item.executable?.isCrossPlatformTool ?? false
        self.isFatBinary          = item.executable?.isFatBinary ?? false
        self.isPrivateFramework   = item.framework?.isPrivate ?? false
    }

    public func withId(_ newId: UUID) -> ItemHeader {
        var copy = self
        copy.id = newId
        return copy
    }
}

public nonisolated struct PlistInfo: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case info
        case version
        case launchService
        case preference
        case entitlements
        case mappedTypes
        case other
    }
    public enum Format: String, Codable, Sendable {
        case xml
        case binary
        case json
        case unknown
    }
    public enum TopLevel: String, Codable, Sendable {
        case dictionary
        case array
        case other
    }
    public var kind: Kind
    public var format: Format
    public var topLevel: TopLevel
    public var keyCount: Int?
    public var elementCount: Int?
    public var previewText: String?
    public var looksLikeInfoPlist: Bool

    public init(
        kind: Kind,
        format: Format,
        topLevel: TopLevel,
        keyCount: Int?,
        elementCount: Int?,
        previewText: String?,
        looksLikeInfoPlist: Bool
    ) {
        self.kind = kind
        self.format = format
        self.topLevel = topLevel
        self.keyCount = keyCount
        self.elementCount = elementCount
        self.previewText = previewText
        self.looksLikeInfoPlist = looksLikeInfoPlist
    }
}
