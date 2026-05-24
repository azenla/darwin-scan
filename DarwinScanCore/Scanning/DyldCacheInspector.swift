import Foundation

/// Parses the `dyld_cache_header` to extract architecture, mapping count,
/// and image count.
///
/// Cache layout reference: dyld_cache_format.h in dyld's source (this code
/// matches the dyld-1280 layout used by macOS 26):
///
///   0x000  char[16]    magic            e.g. "dyld_v1   arm64e"
///   0x010  uint32_t    mappingOffset
///   0x014  uint32_t    mappingCount
///   0x018  uint32_t    imagesOffsetOld  (zero on macOS 14+; image table moved)
///   0x01C  uint32_t    imagesCountOld   (zero on macOS 14+; image table moved)
///   0x138  uint32_t    mappingWithSlideOffset
///   0x13C  uint32_t    mappingWithSlideCount
///   0x1C0  uint32_t    imagesOffset     (the actual image table on macOS 14+)
///   0x1C4  uint32_t    imagesCount      (the actual image count on macOS 14+)
///
/// macOS 14+ split-cache notes: the on-disk layout consists of a main cache
/// file plus N subcache files (`dyld_shared_cache_<arch>.<NN>`, e.g. `.01`,
/// `.02`). Each subcache file is itself a full `dyld_cache_header` and
/// starts with the `dyld_v1` magic, so they all classify here. Sidecars like
/// `.symbols`, `.dylddata`, `.dyldreadonly`, `.dyldlinkedit`, `.atlas`,
/// `.map`, and `.development` are NOT full caches and are filtered out by
/// name.
///
/// Pre-fix bug: only `imagesCountOld` was read, which is zero on every
/// modern cache, so the inspector reported "0 images" for every cache file
/// it visited. The walker side of the bug — Cryptex firmlinks were treated
/// as plain symlinks and not descended into — is fixed in FileWalker.swift.
public nonisolated enum DyldCacheInspector {
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
    public static func looksLikeDyldCache(filename: String) -> Bool {
        guard filename.hasPrefix("dyld_shared_cache_") else { return false }
        // Reject known non-cache sidecars by suffix. The dyld team has added
        // several new sidecars over macOS releases; keep the list current or
        // we'll waste time trying to parse them as caches and then logging a
        // bogus rejection.
        let rejectedSuffixes = [
            ".symbols", ".dylddata", ".dyldreadonly", ".dyldlinkedit",
            ".atlas", ".map", ".json",
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
    public static func archFromFilename(_ filename: String) -> String? {
        let prefix = "dyld_shared_cache_"
        guard filename.hasPrefix(prefix) else { return nil }
        let tail = filename.dropFirst(prefix.count)
        // Arch is everything up to the first '.' (if any).
        let archPart = tail.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? String(tail)
        return archPart.isEmpty ? nil : archPart
    }

    public static func inspect(url: URL) -> DyldCacheInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Need at least through 0x1C8 to read the modern imagesCount field.
        // Reading 1024 bytes gives us comfortable headroom for future fields.
        guard let header = try? handle.read(upToCount: 1024), header.count >= 0x20 else { return nil }

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

        // Prefer `imagesCountOld` (offset 0x1C) — pre-macOS-14 caches keep
        // the count there. Fall back to the modern `imagesCount` (offset
        // 0x1C4) for caches built by macOS 14+ where the image table was
        // moved to support >0xFFFF images.
        let imagesCountOld = Int(header.readUInt32LE(at: 0x1C))
        let imagesCountNew = header.count >= 0x1C8
            ? Int(header.readUInt32LE(at: 0x1C4))
            : 0
        let imagesCount = imagesCountOld != 0 ? imagesCountOld : imagesCountNew

        // Subcaches: the count of dyld_subcache_entry records sitting beyond
        // the main header (each ~0x100 bytes). Surface this so the UI can
        // show "Subcaches: 11" for a split cache.
        let subCacheCount: Int? = header.count >= 0x190
            ? Int(header.readUInt32LE(at: 0x18C))
            : nil

        return DyldCacheInfo(
            architecture: arch,
            formatVersion: magicText,
            imageCount: imagesCount,
            mappingCount: mappingCount,
            subCacheCount: subCacheCount
        )
    }

    /// Enumerate the cached dylib images. Each entry has its runtime path
    /// (e.g. `/usr/lib/libSystem.B.dylib`), unslid load address, modTime,
    /// and inode. Only the main cache file (not subcaches) carries the
    /// image table; subcache files have imagesCount == 0 and return [].
    ///
    /// Subcaches share the address space with the main cache via the
    /// mappings table — we don't expose them as separate "images" because
    /// each cached dylib is reachable through the main cache's table.
    ///
    /// Returns nil if the file isn't a dyld cache; an empty array for a
    /// valid cache with zero images.
    public static func enumerateImages(url: URL) -> [DyldCacheImage]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Read enough to cover the header (~0x1D0) and the start of the
        // image array. We still need to seek to read path strings.
        guard let header = try? handle.read(upToCount: 4096), header.count >= 0x1C8 else {
            return nil
        }

        // Validate magic.
        let sig: [UInt8] = [0x64, 0x79, 0x6C, 0x64, 0x5F, 0x76, 0x31]
        for (i, b) in sig.enumerated() {
            if header[header.startIndex.advanced(by: i)] != b { return nil }
        }

        // Resolve image table location. Prefer the modern fields (0x1C0 /
        // 0x1C4); fall back to legacy (0x18 / 0x1C) when the modern slot is
        // zero, for forward compatibility with future caches that might
        // rearrange again.
        let imagesOffsetNew = UInt64(header.readUInt32LE(at: 0x1C0))
        let imagesCountNew  = Int(header.readUInt32LE(at: 0x1C4))
        let imagesOffsetOld = UInt64(header.readUInt32LE(at: 0x18))
        let imagesCountOld  = Int(header.readUInt32LE(at: 0x1C))
        let imagesOffset: UInt64
        let imagesCount: Int
        if imagesCountNew > 0 {
            imagesOffset = imagesOffsetNew
            imagesCount = imagesCountNew
        } else {
            imagesOffset = imagesOffsetOld
            imagesCount = imagesCountOld
        }
        guard imagesCount > 0, imagesOffset > 0 else { return [] }

        // Read the entire image array in one shot. Each entry is 32 bytes
        // (`dyld_cache_image_info`). 4096 images × 32 = 128 KB, fits
        // comfortably in a single read.
        do {
            try handle.seek(toOffset: imagesOffset)
        } catch { return nil }
        let arrayBytes = imagesCount * 32
        guard let arr = try? handle.read(upToCount: arrayBytes),
              arr.count == arrayBytes else { return nil }

        // For each entry, read the C-string at `pathFileOffset`. We could
        // batch these — adjacent images often have adjacent path strings —
        // but the kernel's read-ahead and the pageable cache make per-entry
        // pread cheap enough for a one-time scan.
        var images: [DyldCacheImage] = []
        images.reserveCapacity(imagesCount)
        for i in 0..<imagesCount {
            let base = i * 32
            let address = arr.readUInt64LE(at: base + 0)
            let modTime = arr.readUInt64LE(at: base + 8)
            let inode   = arr.readUInt64LE(at: base + 16)
            let pathFileOffset = UInt64(arr.readUInt32LE(at: base + 24))
            guard pathFileOffset > 0 else { continue }
            let path = readCString(handle: handle, fileOffset: pathFileOffset, maxLen: 1024)
            guard let path else { continue }
            images.append(DyldCacheImage(
                path: path,
                address: address,
                modTime: modTime,
                inode: inode
            ))
        }
        return images
    }

    /// Read a null-terminated UTF-8 string at `fileOffset`, up to `maxLen`.
    /// Returns nil on read failure or empty strings.
    private static func readCString(handle: FileHandle, fileOffset: UInt64, maxLen: Int) -> String? {
        do {
            try handle.seek(toOffset: fileOffset)
        } catch { return nil }
        guard let chunk = try? handle.read(upToCount: maxLen), !chunk.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chunk.count)
        for b in chunk {
            if b == 0 { break }
            bytes.append(b)
        }
        if bytes.isEmpty { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }
}

/// One image entry inside a dyld shared cache. Returned by
/// `DyldCacheInspector.enumerateImages`.
public nonisolated struct DyldCacheImage: Sendable, Hashable {
    /// Runtime path the image expects to be loaded from. The actual bytes
    /// live inside the cache file, not at this on-disk path.
    public var path: String
    /// Unslid load address inside the cache's address space. Combined with
    /// the cache's mappings, this resolves to a file offset where the
    /// Mach-O header for this image lives — useful for symbol enumeration
    /// in a follow-up commit.
    public var address: UInt64
    /// dyld records the source dylib's modTime and inode at cache-build
    /// time. Lets the runtime check whether an on-disk override has
    /// changed since the cache was built.
    public var modTime: UInt64
    public var inode: UInt64

    public init(path: String, address: UInt64, modTime: UInt64, inode: UInt64) {
        self.path = path
        self.address = address
        self.modTime = modTime
        self.inode = inode
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

    func readUInt64LE(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        let base = startIndex.advanced(by: offset)
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(self[base + i]) << (8 * i) }
        return v
    }
}
