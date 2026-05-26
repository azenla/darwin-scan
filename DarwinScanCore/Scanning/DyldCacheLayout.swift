import Foundation

/// Aggregated view of a `dyld_shared_cache_<arch>` and its subcaches that
/// supports translating both VM addresses and "unified file offsets" into
/// concrete `(subcache file URL, byte offset)` pairs.
///
/// Modern shared caches are split across multiple files:
///
/// ```
/// dyld_shared_cache_arm64e          ← main cache: header, image table,
///                                       initial text region
/// dyld_shared_cache_arm64e.01       ← text continued
/// dyld_shared_cache_arm64e.04.dyldlinkedit
///                                   ← LINKEDIT (symbol table, strings,
///                                       indirect symbols) for many images
/// dyld_shared_cache_arm64e.02.dylddata
/// dyld_shared_cache_arm64e.NN…
/// ```
///
/// The main cache header carries a "subcache array" describing each subcache's
/// `cacheVMOffset` — the VM-space offset where that subcache's region begins,
/// relative to the cache base. Each subcache file is itself a full
/// `dyld_cache_header` with its own mappings table that translates VM
/// addresses to byte offsets WITHIN THAT FILE.
///
/// Two translations matter for symbol extraction:
///
/// 1. **VM-address → file location.** A cached image's `address` (from the
///    main cache image table) is its load address in the cache's VM space.
///    To find its on-disk Mach-O header we locate the subcache whose
///    mappings cover that VM address, then compute
///    `fileOffset = vmAddress - mapping.address + mapping.fileOffset` within
///    that subcache's file.
///
/// 2. **Unified file offset → file location.** Fields like
///    `LC_SYMTAB.symoff` are written during cache build as offsets into the
///    *unified* file (a virtual concatenation of all subcache files ordered
///    by `cacheVMOffset`). To read those bytes we find which subcache
///    contains the offset and subtract its `cacheVMOffset`.
public nonisolated struct DyldCacheLayout: Sendable {
    public struct Subcache: Sendable {
        public let url: URL
        public let cacheVMOffset: UInt64
        /// Cached size in bytes of the subcache file. Used to bound the
        /// unified-file translation when no subsequent subcache exists.
        public let fileSize: UInt64
        public let mappings: [Mapping]
    }

    /// A single `dyld_cache_mapping_info` record: maps a VM range onto a
    /// byte range within a particular subcache file.
    public struct Mapping: Sendable {
        public let vmAddress: UInt64
        public let vmSize: UInt64
        public let fileOffset: UInt64
    }

    public let mainCacheURL: URL
    public let subcaches: [Subcache]

    /// Open and parse the main cache + all its subcaches. Returns nil if
    /// the cache header is malformed.
    public static func load(mainCacheURL: URL) -> DyldCacheLayout? {
        let fm = FileManager.default
        guard let headerHandle = try? FileHandle(forReadingFrom: mainCacheURL),
              let mainHeader = try? headerHandle.read(upToCount: 4096),
              mainHeader.count >= 0x200,
              isCacheMagic(mainHeader) else {
            return nil
        }

        let mappingOffset = UInt64(mainHeader.readUInt32LE(at: 0x10))
        let mappingCount = Int(mainHeader.readUInt32LE(at: 0x14))
        let subcacheOffset = UInt64(mainHeader.readUInt32LE(at: 0x188))
        let subcacheCount = Int(mainHeader.readUInt32LE(at: 0x18C))

        let mainMappings = readMappings(url: mainCacheURL, offset: mappingOffset, count: mappingCount)
        let mainSize = (try? fm.attributesOfItem(atPath: mainCacheURL.path)[.size] as? Int) ?? 0
        let mainSubcache = Subcache(
            url: mainCacheURL,
            cacheVMOffset: 0,
            fileSize: UInt64(mainSize),
            mappings: mainMappings
        )

        var subcaches: [Subcache] = [mainSubcache]
        // Subcache array can live well outside the first 4 KB of the
        // header — on arm64e caches it sits at ~0x39218 alongside the image
        // table. Seek to it explicitly rather than rely on the buffer we
        // already read.
        if subcacheCount > 0, subcacheOffset > 0 {
            do { try headerHandle.seek(toOffset: subcacheOffset) } catch { try? headerHandle.close(); return DyldCacheLayout(mainCacheURL: mainCacheURL, subcaches: subcaches) }
            // dyld_subcache_entry_v2 is 56 bytes: 16-byte uuid + 8-byte
            // cacheVMOffset + 32-byte ASCII fileSuffix.
            let entriesNeeded = subcacheCount * 56
            guard let entries = try? headerHandle.read(upToCount: entriesNeeded),
                  entries.count == entriesNeeded else {
                try? headerHandle.close()
                return DyldCacheLayout(mainCacheURL: mainCacheURL, subcaches: subcaches)
            }
            for i in 0..<subcacheCount {
                let entryOffset = i * 56
                let cacheVMOffset = entries.readUInt64LE(at: entryOffset + 16)
                let suffixBytes = entries.subdata(in: (entryOffset + 24)..<(entryOffset + 56))
                let suffix = trimmedASCII(suffixBytes)
                let subURL = URL(fileURLWithPath: mainCacheURL.path + suffix)
                guard fm.fileExists(atPath: subURL.path),
                      let subHandle = try? FileHandle(forReadingFrom: subURL),
                      let subHead = try? subHandle.read(upToCount: 4096),
                      subHead.count >= 0x20,
                      isCacheMagic(subHead) else { continue }
                try? subHandle.close()
                let subMappingOffset = UInt64(subHead.readUInt32LE(at: 0x10))
                let subMappingCount = Int(subHead.readUInt32LE(at: 0x14))
                let subMappings = readMappings(url: subURL, offset: subMappingOffset, count: subMappingCount)
                let subSize = (try? fm.attributesOfItem(atPath: subURL.path)[.size] as? Int) ?? 0
                subcaches.append(Subcache(
                    url: subURL,
                    cacheVMOffset: cacheVMOffset,
                    fileSize: UInt64(subSize),
                    mappings: subMappings
                ))
            }
        }
        try? headerHandle.close()
        return DyldCacheLayout(mainCacheURL: mainCacheURL, subcaches: subcaches)
    }

    /// Translate a VM address to a `(subcache file URL, byte offset)`.
    /// Returns nil if no subcache mapping covers `vmAddress`.
    public func locate(vmAddress: UInt64) -> (url: URL, fileOffset: UInt64)? {
        for sub in subcaches {
            for m in sub.mappings {
                if vmAddress >= m.vmAddress && vmAddress < m.vmAddress + m.vmSize {
                    let offset = vmAddress - m.vmAddress + m.fileOffset
                    return (sub.url, offset)
                }
            }
        }
        return nil
    }

    /// Translate a "unified file offset" (LC_SYMTAB.symoff / stroff /
    /// indirectsymoff, written during cache build as offsets into the
    /// virtual concatenation of every subcache file) to a real
    /// `(subcache URL, byte offset)`.
    ///
    /// The unified file is ordered by `cacheVMOffset`: position 0 is the
    /// start of the main cache, position `subcache.cacheVMOffset` is the
    /// start of that subcache. So we pick the largest `cacheVMOffset` that
    /// is `<= unifiedOffset` and subtract.
    public func locateUnifiedFileOffset(_ unifiedOffset: UInt64) -> (url: URL, fileOffset: UInt64)? {
        // Subcaches in declared order, but the first match wins by picking
        // the largest cacheVMOffset that doesn't exceed `unifiedOffset`.
        var best: Subcache?
        for sub in subcaches {
            if sub.cacheVMOffset <= unifiedOffset {
                if best == nil || sub.cacheVMOffset > best!.cacheVMOffset {
                    best = sub
                }
            }
        }
        guard let chosen = best else { return nil }
        let localOffset = unifiedOffset - chosen.cacheVMOffset
        guard localOffset < chosen.fileSize else { return nil }
        return (chosen.url, localOffset)
    }

    // MARK: - Helpers

    private static func isCacheMagic(_ data: Data) -> Bool {
        let sig: [UInt8] = [0x64, 0x79, 0x6C, 0x64, 0x5F, 0x76, 0x31] // "dyld_v1"
        guard data.count >= sig.count else { return false }
        for (i, b) in sig.enumerated() {
            if data[data.startIndex.advanced(by: i)] != b { return false }
        }
        return true
    }

    private static func readMappings(url: URL, offset: UInt64, count: Int) -> [Mapping] {
        guard count > 0, offset > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch { return [] }
        let bytesNeeded = count * 32
        guard let blob = try? handle.read(upToCount: bytesNeeded),
              blob.count == bytesNeeded else { return [] }
        var mappings: [Mapping] = []
        mappings.reserveCapacity(count)
        for i in 0..<count {
            let base = i * 32
            let vmAddr = blob.readUInt64LE(at: base + 0)
            let vmSize = blob.readUInt64LE(at: base + 8)
            let fileOff = blob.readUInt64LE(at: base + 16)
            mappings.append(Mapping(vmAddress: vmAddr, vmSize: vmSize, fileOffset: fileOff))
        }
        return mappings
    }

    private static func trimmedASCII(_ data: Data) -> String {
        var bytes: [UInt8] = []
        for b in data {
            if b == 0 { break }
            bytes.append(b)
        }
        return String(bytes: bytes, encoding: .ascii) ?? ""
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
