import Foundation

/// Optional extractor that captures printable strings from Mach-O binaries via
/// `/usr/bin/strings`. Output streams directly to disk inside the BlobStore's
/// cache directory — we deliberately do NOT hold the bytes in worker memory
/// (a single dyld_shared_cache strings dump can be 100+ MB; multiplied by
/// concurrent workers that's GB-scale and a likely OOM).
public nonisolated enum StringsExtractor {
    /// Run `strings -n <minLen> <path>`, piping stdout straight into a file
    /// in `cacheDirectory`. The result file is hashed after writing and
    /// renamed to the content-addressed `strings-<sha>.bin` form so it
    /// dedupes across identical strings outputs.
    ///
    /// Returns the blob ref on success, nil on failure. Memory cost per call
    /// is ~zero — Process pipes bytes directly through a FileHandle.
    public static func streamStrings(
        from url: URL,
        minLength: Int,
        into cacheDirectory: URL
    ) -> String? {
        let stringsURL = URL(fileURLWithPath: "/usr/bin/strings")
        guard FileManager.default.isExecutableFile(atPath: stringsURL.path) else { return nil }

        // Write to a temp file first, hash, then rename to the
        // content-addressed name. The two-step is necessary because we don't
        // know the SHA-256 until the bytes are on disk.
        let tempName = "strings-tmp-\(UUID().uuidString).bin"
        let tempURL = cacheDirectory.appendingPathComponent(tempName)
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        guard let writer = try? FileHandle(forWritingTo: tempURL) else { return nil }

        let process = Process()
        process.executableURL = stringsURL
        process.arguments = ["-n", "\(minLength)", "-arch", "all", url.path]
        process.standardOutput = writer
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            try? writer.close()
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
        process.waitUntilExit()
        try? writer.close()

        guard process.terminationStatus == 0,
              let sha = Hash.sha256(of: tempURL) else {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
        let ref = "strings-\(sha)"
        let finalURL = cacheDirectory.appendingPathComponent("\(ref).bin")
        if FileManager.default.fileExists(atPath: finalURL.path) {
            // Identical strings output already on disk — drop the temp.
            try? FileManager.default.removeItem(at: tempURL)
        } else {
            do {
                try FileManager.default.moveItem(at: tempURL, to: finalURL)
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                return nil
            }
        }
        return ref
    }

    /// Tiny convenience used by Scanner heuristics: grep for "usage:" lines
    /// without keeping the full strings output. Reads at most 4 MB of the
    /// binary's slice; this avoids spawning `strings` and is good enough for
    /// CLI-vs-daemon classification.
    public static func grepInBinary(url: URL, needle: String, maxBytes: Int = 4 * 1024 * 1024) -> String? {
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
