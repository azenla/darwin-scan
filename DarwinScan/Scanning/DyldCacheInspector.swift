import Foundation

/// Parses the `dyld_cache_header` (just the first ~0x200 bytes) to extract
/// architecture, mapping count, and image count.
///
/// Cache layout reference: dyld_cache_format.h in dyld's source. Fields used
/// here (offsets are stable across all supported macOS versions):
///   0x00  char[16]    magic        e.g. "dyld_v1   arm64e"
///   0x10  uint32_t    mappingOffset
///   0x14  uint32_t    mappingCount
///   0x18  uint32_t    imagesOffsetOld (zero on macOS 14+; image table moved)
///   0x1C  uint32_t    imagesCountOld  (zero on macOS 14+; image table moved)
///   ...
///
/// macOS 14+ split-cache notes: the on-disk layout now consists of a main
/// cache file plus N subcache files named `dyld_shared_cache_<arch>.<NN>`
/// (e.g. `.01`, `.02`). Each subcache file is itself a full
/// `dyld_cache_header` and starts with the `dyld_v1` magic, so they all
/// classify here. Sidecars like `.symbols`, `.dylddata`, `.atlas`, and
/// `.development` are NOT full caches and are filtered out by name.
nonisolated enum DyldCacheInspector {
    /// Returns true when `filename` looks like a real cache file we can parse.
    ///
    /// Accepts:
    ///   - `dyld_shared_cache_<arch>`                  (main cache)
    ///   - `dyld_shared_cache_<arch>.NN`               (split subcache, macOS 14+)
    ///   - `dyld_shared_cache_<arch>.development`      (development variant)
    ///
    /// Rejects sidecar files that share the prefix but aren't `dyld_v1` caches:
    ///   - `.symbols`     (separate symbol archive)
    ///   - `.dylddata`    (dyld closure data)
    ///   - `.atlas`       (debugger atlas)
    ///   - `.map`, `.json`, `.txt`, `.aside`, `.t8112`, etc.
    static func looksLikeDyldCache(filename: String) -> Bool {
        guard filename.hasPrefix("dyld_shared_cache_") else { return false }
        // Reject known non-cache sidecars by suffix.
        let rejectedSuffixes = [
            ".symbols", ".dylddata", ".atlas", ".map", ".json",
            ".txt", ".aside", ".dSYM"
        ]
        for suffix in rejectedSuffixes where filename.hasSuffix(suffix) {
            return false
        }
        return true
    }

    /// Best-effort architecture name parsed from the filename
    /// (e.g. `dyld_shared_cache_arm64e.01` -> `"arm64e"`).
    /// Used as a fallback when the in-file magic doesn't contain a clean
    /// arch token (some subcaches pad differently).
    static func archFromFilename(_ filename: String) -> String? {
        let prefix = "dyld_shared_cache_"
        guard filename.hasPrefix(prefix) else { return nil }
        let tail = filename.dropFirst(prefix.count)
        // Arch is everything up to the first '.' (if any).
        let archPart = tail.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? String(tail)
        return archPart.isEmpty ? nil : archPart
    }

    static func inspect(url: URL) -> DyldCacheInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 0x200), header.count >= 0x20 else { return nil }

        // Byte-level magic check. Avoids `String(data:encoding:.ascii)` which
        // is finicky around padding bytes and was the suspect for "0 items"
        // false negatives on some configurations.
        let magicSignature: [UInt8] = [0x64, 0x79, 0x6C, 0x64, 0x5F, 0x76, 0x31] // "dyld_v1"
        guard header.count >= magicSignature.count else { return nil }
        for (i, b) in magicSignature.enumerated() {
            if header[header.startIndex.advanced(by: i)] != b { return nil }
        }

        // Pull the 16-byte magic field, then derive arch.
        // Magic field layout: "dyld_v1" + spaces + "<arch>" + null padding.
        // Walk byte-by-byte so we don't depend on `.ascii` decoding behavior.
        var magicChars: [UInt8] = []
        magicChars.reserveCapacity(16)
        for i in 0..<16 {
            let b = header[header.startIndex.advanced(by: i)]
            if b == 0 { break }
            magicChars.append(b)
        }
        let magicText = String(bytes: magicChars, encoding: .ascii) ?? "dyld_v1"
        // Arch == last whitespace-separated token after "dyld_v1".
        // Filter out empty tokens from runs of spaces.
        let tokens = magicText
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        var arch: String? = nil
        if let last = tokens.last, last != "dyld_v1" {
            arch = last
        }
        // Fallback: derive arch from the filename if the header was ambiguous.
        if arch == nil || arch?.isEmpty == true {
            arch = archFromFilename(url.lastPathComponent)
        }

        let mappingCount = Int(header.readUInt32LE(at: 0x14))
        let imagesCount  = Int(header.readUInt32LE(at: 0x1C))

        return DyldCacheInfo(
            architecture: arch,
            formatVersion: magicText,
            imageCount: imagesCount,
            mappingCount: mappingCount
        )
    }
}

nonisolated private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let base = startIndex.advanced(by: offset)
        let b0 = UInt32(self[base])
        let b1 = UInt32(self[base + 1])
        let b2 = UInt32(self[base + 2])
        let b3 = UInt32(self[base + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}
