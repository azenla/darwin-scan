import Foundation

nonisolated enum PlistInspector {
    /// Reads any plist (xml or binary). Returns nil on error.
    static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// Decode a launchd plist into a `LaunchServiceInfo`. Returns nil if
    /// the plist isn't recognizable as a launchd descriptor (no `Label`).
    static func decodeLaunchService(at url: URL) -> LaunchServiceInfo? {
        guard let dict = read(url) else { return nil }
        guard let label = dict["Label"] as? String else { return nil }
        let kind: LaunchServiceInfo.Kind = url.path.contains("/LaunchDaemons/") ? .daemon : .agent

        let programArgs = (dict["ProgramArguments"] as? [String]) ?? []
        let program     = (dict["Program"] as? String) ?? programArgs.first
        let machDict    = dict["MachServices"] as? [String: Any]
        let machNames   = machDict.map { Array($0.keys) } ?? []
        let watchPaths  = (dict["WatchPaths"] as? [String]) ?? []
        return LaunchServiceInfo(
            kind: kind,
            label: label,
            program: program,
            programArguments: programArgs,
            runAtLoad: (dict["RunAtLoad"] as? Bool) ?? false,
            keepAlive: keepAliveBool(dict["KeepAlive"]),
            userName: dict["UserName"] as? String,
            groupName: dict["GroupName"] as? String,
            machServices: machNames,
            watchPaths: watchPaths,
            startInterval: dict["StartInterval"] as? Int,
            disabled: (dict["Disabled"] as? Bool) ?? false
        )
    }

    /// `KeepAlive` may be a boolean OR a dictionary of conditions. We treat
    /// any non-false value as "keepalive on" for display purposes.
    private static func keepAliveBool(_ raw: Any?) -> Bool {
        if let b = raw as? Bool { return b }
        if raw is [String: Any] { return true }
        return false
    }

    /// Decode an `Info.plist` from an `.app`/`.framework`/`.bundle` directory.
    static func decodeAppBundle(at bundleURL: URL) -> AppBundleInfo? {
        let infoURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let dict = read(infoURL) else { return nil }
        let executableName = dict["CFBundleExecutable"] as? String
        let executablePath = executableName.map { bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent($0).path }
        return AppBundleInfo(
            bundleIdentifier: dict["CFBundleIdentifier"] as? String,
            displayName: dict["CFBundleDisplayName"] as? String
                ?? dict["CFBundleName"] as? String,
            executableName: executableName,
            executablePath: executablePath,
            shortVersionString: dict["CFBundleShortVersionString"] as? String,
            bundleVersion: dict["CFBundleVersion"] as? String,
            minimumSystemVersion: dict["LSMinimumSystemVersion"] as? String,
            category: dict["LSApplicationCategoryType"] as? String,
            isHidden: (dict["LSUIElement"] as? Bool) ?? false,
            isAgentApp: (dict["LSBackgroundOnly"] as? Bool) ?? false,
            iconRef: nil,
            documentTypes: extractDocumentTypeNames(dict),
            urlSchemes: extractURLSchemes(dict)
        )
    }

    /// Decode a `.framework`'s versioned Info.plist. Frameworks store their
    /// Info.plist inside `Versions/Current/Resources/Info.plist`.
    static func decodeFrameworkBundle(at bundleURL: URL) -> FrameworkInfo? {
        let candidates = [
            bundleURL.appendingPathComponent("Versions/Current/Resources/Info.plist"),
            bundleURL.appendingPathComponent("Resources/Info.plist"),
            bundleURL.appendingPathComponent("Contents/Info.plist")
        ]
        var dict: [String: Any]?
        for c in candidates {
            if let d = read(c) { dict = d; break }
        }
        guard let dict else { return nil }
        let isPrivate = bundleURL.path.contains("/PrivateFrameworks/")
        return FrameworkInfo(
            bundleIdentifier: dict["CFBundleIdentifier"] as? String,
            shortVersionString: dict["CFBundleShortVersionString"] as? String,
            currentVersion: dict["CFBundleVersion"] as? String,
            executableName: dict["CFBundleExecutable"] as? String,
            headerCount: countHeaders(in: bundleURL),
            isPrivate: isPrivate
        )
    }

    private static func countHeaders(in bundleURL: URL) -> Int {
        let headersURL = bundleURL.appendingPathComponent("Headers", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: headersURL.path) else { return 0 }
        return entries.filter { $0.hasSuffix(".h") }.count
    }

    private static func extractDocumentTypeNames(_ dict: [String: Any]) -> [String] {
        guard let docs = dict["CFBundleDocumentTypes"] as? [[String: Any]] else { return [] }
        return docs.compactMap { $0["CFBundleTypeName"] as? String }
    }

    private static func extractURLSchemes(_ dict: [String: Any]) -> [String] {
        guard let groups = dict["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
        var out: [String] = []
        for g in groups {
            if let schemes = g["CFBundleURLSchemes"] as? [String] { out.append(contentsOf: schemes) }
        }
        return out
    }
}
