import Foundation

/// Snapshot of host configuration at scan time. Captured once per scan; used
/// for cross-scan diffs ("what changed between macOS 26.4 and 26.5?") and as
/// a header in the inspector.
struct SystemInfo: Codable, Hashable, Sendable {
    var productName: String?       // "macOS"
    var productVersion: String?    // "26.5"
    var productBuildVersion: String?
    var kernelVersion: String?     // uname -v
    var hardwareModel: String?     // sysctl hw.model
    var cpuBrand: String?          // sysctl machdep.cpu.brand_string
    var architectures: [String]    // running arch + native arch
    var hostName: String?
    var bootArgs: String?          // sysctl kern.bootargs (best-effort)
    var sipStatus: String?         // "enabled" / "disabled" / "unknown"
    var capturedAt: Date
}
