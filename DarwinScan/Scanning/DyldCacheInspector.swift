import Foundation

/// Parses the `dyld_cache_header` (just the first ~0x200 bytes) to extract
/// architecture, mapping count, and image count.
///
/// Cache layout reference: dyld_cache_format.h in dyld's source. Fields used
/// here (offsets are stable across all supported macOS versions):
///   0x00  char[16]    magic        e.g. "dyld_v1   arm64e"
///   0x10  uint32_t    mappingOffset
///   0x14  uint32_t    mappingCount
///   0x18  uint32_t    imagesOffsetOld
///   0x1C  uint32_t    imagesCountOld
///   ...
nonisolated enum DyldCacheInspector {
    static func looksLikeDyldCache(filename: String) -> Bool {
        // Names: dyld_shared_cache_arm64e, dyld_shared_cache_arm64e.1, ...
        filename.hasPrefix("dyld_shared_cache_")
    }

    static func inspect(url: URL) -> DyldCacheInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 0x200), header.count >= 0x20 else { return nil }
        let magicBytes = header.prefix(16)
        guard let magic = String(data: magicBytes, encoding: .ascii) else { return nil }
        guard magic.hasPrefix("dyld_v1") else { return nil }
        // Magic is "dyld_v1<spaces><arch>" — the arch is the last token.
        let formatVersion = magic.trimmingCharacters(in: .controlCharacters)
        let arch = formatVersion
            .replacingOccurrences(of: "dyld_v1", with: "")
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))

        let mappingCount = Int(header.readUInt32LE(at: 0x14))
        let imagesCount  = Int(header.readUInt32LE(at: 0x1C))

        return DyldCacheInfo(
            architecture: arch.isEmpty ? nil : arch,
            formatVersion: formatVersion.trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
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
