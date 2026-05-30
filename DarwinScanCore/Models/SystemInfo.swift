import Foundation

/// Snapshot of host configuration at scan time. Captured once per scan; used
/// for cross-scan diffs ("what changed between macOS 26.4 and 26.5?") and as
/// a header in the inspector.
public nonisolated struct SystemInfo: Codable, Hashable, Sendable {
    public var productName: String?
    public var productVersion: String?
    public var productBuildVersion: String?
    public var kernelVersion: String?
    public var hardwareModel: String?
    public var cpuBrand: String?
    /// CPU architectures of the image — e.g. `["arm64"]` or `["arm64", "x86_64"]`.
    /// **Not** the Mac model identifier; see `supportedProductTypes` for that.
    public var architectures: [String]
    /// Mac model identifiers an IPSW supports (e.g. `Mac15,11`). Filled only
    /// for IPSW snapshots — `BuildManifest.plist#SupportedProductTypes`. Nil
    /// for current-system snapshots.
    public var supportedProductTypes: [String]?
    /// Build train name from `BuildManifest.plist#Train` — e.g. "CheerF" for
    /// macOS 26.5. IPSW snapshots only.
    public var buildTrain: String?
    public var hostName: String?
    public var bootArgs: String?
    public var sipStatus: String?
    public var capturedAt: Date

    private enum CodingKeys: String, CodingKey {
        case productName, productVersion, productBuildVersion
        case kernelVersion, hardwareModel, cpuBrand
        case architectures, supportedProductTypes, buildTrain
        case hostName, bootArgs, sipStatus, capturedAt
    }

    // Custom decoder so old snapshot rows — which stored Mac model
    // identifiers ("Mac15,11") inside `architectures` because IPSWSource
    // used to mistakenly cram them there — are rehomed into
    // `supportedProductTypes` on read. The synthesized Codable would skip
    // the back-fix that lives in the designated init.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.productName = try c.decodeIfPresent(String.self, forKey: .productName)
        self.productVersion = try c.decodeIfPresent(String.self, forKey: .productVersion)
        self.productBuildVersion = try c.decodeIfPresent(String.self, forKey: .productBuildVersion)
        self.kernelVersion = try c.decodeIfPresent(String.self, forKey: .kernelVersion)
        self.hardwareModel = try c.decodeIfPresent(String.self, forKey: .hardwareModel)
        self.cpuBrand = try c.decodeIfPresent(String.self, forKey: .cpuBrand)
        let rawArchs = try c.decodeIfPresent([String].self, forKey: .architectures) ?? []
        let priorSupportedTypes = try c.decodeIfPresent([String].self, forKey: .supportedProductTypes)
        if priorSupportedTypes == nil, rawArchs.contains(where: { Self.looksLikeProductType($0) }) {
            let (models, archs) = Self.splitArchs(rawArchs)
            self.architectures = archs.isEmpty ? ["arm64"] : archs
            self.supportedProductTypes = models.isEmpty ? nil : models
        } else {
            self.architectures = rawArchs
            self.supportedProductTypes = priorSupportedTypes
        }
        self.buildTrain = try c.decodeIfPresent(String.self, forKey: .buildTrain)
        self.hostName = try c.decodeIfPresent(String.self, forKey: .hostName)
        self.bootArgs = try c.decodeIfPresent(String.self, forKey: .bootArgs)
        self.sipStatus = try c.decodeIfPresent(String.self, forKey: .sipStatus)
        self.capturedAt = try c.decodeIfPresent(Date.self, forKey: .capturedAt) ?? Date(timeIntervalSince1970: 0)
    }

    public init(
        productName: String? = nil,
        productVersion: String? = nil,
        productBuildVersion: String? = nil,
        kernelVersion: String? = nil,
        hardwareModel: String? = nil,
        cpuBrand: String? = nil,
        architectures: [String] = [],
        supportedProductTypes: [String]? = nil,
        buildTrain: String? = nil,
        hostName: String? = nil,
        bootArgs: String? = nil,
        sipStatus: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.productName = productName
        self.productVersion = productVersion
        self.productBuildVersion = productBuildVersion
        self.kernelVersion = kernelVersion
        self.hardwareModel = hardwareModel
        self.cpuBrand = cpuBrand
        // Back-fix for snapshots written by an earlier IPSWSource that
        // stuffed SupportedProductTypes into `architectures`. Detect entries
        // shaped like `Mac15,11` and rehome them.
        if supportedProductTypes == nil, architectures.contains(where: { Self.looksLikeProductType($0) }) {
            let (models, archs) = Self.splitArchs(architectures)
            self.architectures = archs.isEmpty ? ["arm64"] : archs
            self.supportedProductTypes = models.isEmpty ? nil : models
        } else {
            self.architectures = architectures
            self.supportedProductTypes = supportedProductTypes
        }
        self.buildTrain = buildTrain
        self.hostName = hostName
        self.bootArgs = bootArgs
        self.sipStatus = sipStatus
        self.capturedAt = capturedAt
    }

    /// `Mac15,11`, `iPhone15,2`, `VirtualMac2,1` — anything that looks like
    /// an Apple model identifier (Letters, digits, then `,N`).
    private static func looksLikeProductType(_ s: String) -> Bool {
        guard let commaIdx = s.firstIndex(of: ","),
              commaIdx < s.endIndex else { return false }
        let head = s[..<commaIdx]
        let tail = s[s.index(after: commaIdx)...]
        let headOK = head.first?.isLetter == true && head.allSatisfy { $0.isLetter || $0.isNumber }
        let tailOK = !tail.isEmpty && tail.allSatisfy { $0.isNumber }
        return headOK && tailOK
    }

    private static func splitArchs(_ values: [String]) -> (models: [String], archs: [String]) {
        var models: [String] = []
        var archs: [String] = []
        for v in values {
            if looksLikeProductType(v) {
                models.append(v)
            } else {
                archs.append(v)
            }
        }
        return (models, archs)
    }
}
