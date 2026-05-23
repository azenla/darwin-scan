import Foundation
import Darwin

nonisolated enum SystemInfoCollector {
    static func capture() -> SystemInfo {
        let plistURL = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
        var productName: String?
        var productVersion: String?
        var productBuild: String?
        if let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            productName    = plist["ProductName"] as? String
            productVersion = plist["ProductVersion"] as? String
            productBuild   = plist["ProductBuildVersion"] as? String
        }
        let kernelVersion = sysctlString("kern.version")
        let hardwareModel = sysctlString("hw.model")
        let cpuBrand      = sysctlString("machdep.cpu.brand_string")
        let bootArgs      = sysctlString("kern.bootargs")
        var archs: [String] = []
        if let runningArch = sysctlString("hw.machine") { archs.append(runningArch) }
        // `sysctl.proc_translated == 1` means we're under Rosetta; native arch differs.
        // We don't bother — running arch is what matters for scan interpretation.
        let hostName = Host.current().localizedName
        let sip = readSIPStatus()
        return SystemInfo(
            productName: productName,
            productVersion: productVersion,
            productBuildVersion: productBuild,
            kernelVersion: kernelVersion,
            hardwareModel: hardwareModel,
            cpuBrand: cpuBrand,
            architectures: archs,
            hostName: hostName,
            bootArgs: bootArgs,
            sipStatus: sip,
            capturedAt: Date()
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        if sysctlbyname(name, nil, &size, nil, 0) != 0 { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        if sysctlbyname(name, &bytes, &size, nil, 0) != 0 { return nil }
        return String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SIP status is not exposed as a sysctl on modern macOS; `csrutil status`
    /// is the canonical answer but it's a subprocess. We try the subprocess and
    /// fall back to "unknown" if it fails (sandboxed/lacks /usr/bin/csrutil).
    private static func readSIPStatus() -> String? {
        let url = URL(fileURLWithPath: "/usr/bin/csrutil")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        let process = Process()
        process.executableURL = url
        process.arguments = ["status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        if text.contains("enabled")  { return "enabled" }
        if text.contains("disabled") { return "disabled" }
        return "unknown"
    }
}
