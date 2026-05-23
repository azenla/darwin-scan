import Foundation

/// Optional extractor that captures printable strings from Mach-O binaries via
/// `/usr/bin/strings`. Output is stored as a blob inside the scan bundle so
/// it can be searched later without re-reading the original binary.
nonisolated enum StringsExtractor {
    /// Run `strings -n <minLen> <path>` and return the raw UTF-8 output.
    /// Returns nil if `/usr/bin/strings` is missing or exits abnormally.
    static func extract(from url: URL, minLength: Int) -> Data? {
        let stringsURL = URL(fileURLWithPath: "/usr/bin/strings")
        guard FileManager.default.isExecutableFile(atPath: stringsURL.path) else { return nil }

        let process = Process()
        process.executableURL = stringsURL
        process.arguments = ["-n", "\(minLength)", "-arch", "all", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain in chunks to avoid pipe-buffer deadlock for large outputs
        // (strings of a multi-MB Mach-O can be ~10 MB).
        var collected = Data()
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            collected.append(chunk)
            if collected.count > 64 * 1024 * 1024 { break } // 64 MB cap per binary
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? collected : nil
    }

    /// Tiny convenience used by Scanner heuristics: grep for "usage:" lines
    /// without keeping the full strings output. Reads at most 4 MB of the
    /// binary's slice; this avoids spawning `strings` and is good enough for
    /// CLI-vs-daemon classification.
    static func grepInBinary(url: URL, needle: String, maxBytes: Int = 4 * 1024 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: maxBytes), !chunk.isEmpty else { return nil }
        guard let needleData = needle.data(using: .utf8) else { return nil }
        guard let range = chunk.range(of: needleData) else { return nil }

        // Walk forward / backward from the match to find a printable ASCII
        // "line" — bounded by NUL or by a non-printable byte.
        let startIdx = chunk.startIndex
        var start = range.lowerBound
        var end = range.upperBound
        while start > startIdx {
            let prev = chunk.index(before: start)
            let b = chunk[prev]
            if b == 0 || b == 0x0A || b == 0x0D { break }
            if !(0x20...0x7E ~= b) { break }
            start = prev
        }
        while end < chunk.endIndex {
            let b = chunk[end]
            if b == 0 || b == 0x0A || b == 0x0D { break }
            if !(0x20...0x7E ~= b) { break }
            end = chunk.index(after: end)
        }
        let slice = chunk[start..<end]
        guard let text = String(data: slice, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
