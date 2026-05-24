import Foundation

public nonisolated enum PlistInspector {
    /// Reads any plist (xml or binary). Returns nil on error.
    public static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// Classify a `.plist` file without parsing its full contents. We peek
    /// the first ~64 KB which is enough to detect format, top-level kind,
    /// CFBundle keys, and capture a preview snippet for the detail view.
    public static func decodePlistInfo(at url: URL) -> (PlistInfo, previewBlob: Data?)? {
        let head: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let chunk = try handle.read(upToCount: 64 * 1024) else { return nil }
            head = chunk
        } catch {
            return nil
        }
        if head.isEmpty { return nil }

        // Format sniffing.
        let format: PlistInfo.Format
        if head.starts(with: Array("bplist".utf8)) {
            format = .binary
        } else if head.starts(with: Array("<?xml".utf8))
            || head.starts(with: Array("<plist".utf8))
            || head.starts(with: Array("<!DOCTYPE".utf8)) {
            format = .xml
        } else if head.first == 0x7B /* { */ || head.first == 0x5B /* [ */ {
            format = .json
        } else {
            format = .unknown
        }

        // Try a proper parse for accurate structure info. PropertyListSerialization
        // handles xml + binary. JSON we'll just sniff structurally below.
        var topLevel: PlistInfo.TopLevel = .other
        var keyCount: Int? = nil
        var elementCount: Int? = nil
        var looksLikeInfoPlist: Bool = false
        var dictKeys: [String] = []

        if format == .xml || format == .binary,
           let parsed = try? PropertyListSerialization.propertyList(from: head, options: [], format: nil) {
            if let dict = parsed as? [String: Any] {
                topLevel = .dictionary
                keyCount = dict.count
                dictKeys = Array(dict.keys)
                looksLikeInfoPlist =
                    dict.keys.contains("CFBundleIdentifier") ||
                    dict.keys.contains("CFBundleExecutable") ||
                    dict.keys.contains("CFBundleName")
            } else if let array = parsed as? [Any] {
                topLevel = .array
                elementCount = array.count
            }
        } else if format == .json,
                  let text = String(data: head, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") { topLevel = .dictionary }
            else if trimmed.hasPrefix("[") { topLevel = .array }
        }

        let kind = classifyKind(url: url, dictKeys: dictKeys, looksLikeInfoPlist: looksLikeInfoPlist)

        // Preview snippet for the detail view. For binary plists we re-render
        // as XML so the user sees something legible; for XML/JSON we just
        // show the head.
        var previewText: String? = nil
        if format == .binary {
            if let plistObj = try? PropertyListSerialization.propertyList(from: head, options: [], format: nil),
               let xml = try? PropertyListSerialization.data(fromPropertyList: plistObj, format: .xml, options: 0),
               let xmlText = String(data: xml, encoding: .utf8) {
                previewText = String(xmlText.prefix(8 * 1024))
            }
        } else if let text = String(data: head, encoding: .utf8) {
            previewText = String(text.prefix(8 * 1024))
        }

        let info = PlistInfo(
            kind: kind,
            format: format,
            topLevel: topLevel,
            keyCount: keyCount,
            elementCount: elementCount,
            previewText: previewText,
            looksLikeInfoPlist: looksLikeInfoPlist
        )
        return (info, nil)
    }

    /// Heuristic classification — uses filename + parent directory to decide
    /// what kind of plist this is, falling back to "other".
    private static func classifyKind(url: URL, dictKeys: [String], looksLikeInfoPlist: Bool) -> PlistInfo.Kind {
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent
        if name == "Info.plist" || looksLikeInfoPlist { return .info }
        if name == "version.plist" || name == "Version.plist" { return .version }
        if url.pathExtension.lowercased() == "entitlements" { return .entitlements }
        if name.hasPrefix("com.apple.") && parent == "Preferences" { return .preference }
        if dictKeys.contains("Label") && dictKeys.contains("ProgramArguments") { return .launchService }
        return .other
    }

    /// Decode a launchd plist into a `LaunchServiceInfo`. Returns nil if
    /// the plist isn't recognizable as a launchd descriptor (no `Label`).
    public static func decodeLaunchService(at url: URL) -> LaunchServiceInfo? {
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
    public static func decodeAppBundle(at bundleURL: URL) -> AppBundleInfo? {
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
    public static func decodeFrameworkBundle(at bundleURL: URL) -> FrameworkInfo? {
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
