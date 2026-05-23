import Foundation

nonisolated enum LocalizationInspector {
    /// Parse a `.strings` or `.stringsdict` file. Returns the parsed key count
    /// and the language inferred from the parent `.lproj` directory name.
    static func inspect(url: URL) -> LocalizationInfo? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "strings":     return inspectStrings(url)
        case "stringsdict": return inspectStringsDict(url)
        default:            return nil
        }
    }

    /// `.lproj` directories — we list them as their own items so users can see
    /// "this bundle ships 32 languages".
    static func inspectLprojDirectory(_ url: URL) -> LocalizationInfo? {
        let lang = languageFromLproj(url)
        return LocalizationInfo(
            kind: .lproj,
            language: lang,
            keyCount: nil,
            owningBundleId: nil
        )
    }

    private static func inspectStrings(_ url: URL) -> LocalizationInfo? {
        let lang = languageFromAncestor(url)
        // `.strings` files are usually UTF-16 LE with BOM, but xib-stripped ones
        // can be UTF-8. PropertyListSerialization handles both because Apple's
        // .strings is just a binary or xml plist representing a dict.
        guard let data = try? Data(contentsOf: url) else {
            return LocalizationInfo(kind: .strings, language: lang, keyCount: nil, owningBundleId: nil)
        }
        if let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            return LocalizationInfo(kind: .strings, language: lang, keyCount: dict.count, owningBundleId: nil)
        }
        // Fall back to a heuristic line count if it's plain text.
        let text = String(data: data, encoding: .utf16) ?? String(data: data, encoding: .utf8) ?? ""
        let approx = text.split(separator: "\n").filter { $0.contains("=") }.count
        return LocalizationInfo(kind: .strings, language: lang, keyCount: approx, owningBundleId: nil)
    }

    private static func inspectStringsDict(_ url: URL) -> LocalizationInfo? {
        let lang = languageFromAncestor(url)
        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return LocalizationInfo(kind: .stringsdict, language: lang, keyCount: nil, owningBundleId: nil)
        }
        return LocalizationInfo(kind: .stringsdict, language: lang, keyCount: dict.count, owningBundleId: nil)
    }

    /// Walk up the path until we find a `.lproj` ancestor and infer language.
    private static func languageFromAncestor(_ url: URL) -> String? {
        var current = url.deletingLastPathComponent()
        for _ in 0..<6 {
            if current.pathExtension == "lproj" {
                return current.deletingPathExtension().lastPathComponent
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    private static func languageFromLproj(_ url: URL) -> String? {
        guard url.pathExtension == "lproj" else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }
}
