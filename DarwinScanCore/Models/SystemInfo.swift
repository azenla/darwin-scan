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
    public var architectures: [String]
    public var hostName: String?
    public var bootArgs: String?
    public var sipStatus: String?
    public var capturedAt: Date

    public init(
        productName: String?,
        productVersion: String?,
        productBuildVersion: String?,
        kernelVersion: String?,
        hardwareModel: String?,
        cpuBrand: String?,
        architectures: [String],
        hostName: String?,
        bootArgs: String?,
        sipStatus: String?,
        capturedAt: Date
    ) {
        self.productName = productName
        self.productVersion = productVersion
        self.productBuildVersion = productBuildVersion
        self.kernelVersion = kernelVersion
        self.hardwareModel = hardwareModel
        self.cpuBrand = cpuBrand
        self.architectures = architectures
        self.hostName = hostName
        self.bootArgs = bootArgs
        self.sipStatus = sipStatus
        self.capturedAt = capturedAt
    }
}
