import Foundation

/// Extract symbols and `__TEXT,__cstring` strings from a single image
/// embedded inside a `dyld_shared_cache_<arch>` file.
///
/// The shared cache spreads each image's Mach-O across multiple files: the
/// header + load commands live in one subcache (the "text" subcaches like
/// `.01`, `.05`, `.09`), while LC_SYMTAB's symbol and string tables live in
/// LINKEDIT subcaches (`.04.dyldlinkedit`, `.08.dyldlinkedit`, …). `LC_SYMTAB`
/// fields are stored as "unified file offsets" — offsets into the virtual
/// concatenation of every subcache file in `cacheVMOffset` order.
///
/// This inspector translates those offsets through `DyldCacheLayout` so a
/// symbol enumeration that would normally need to mmap the entire cache as a
/// single image can be done with two `read()` calls per image (one for the
/// nlist table, one for the string table).
///
/// **What we extract.**
/// - LC_SYMTAB external symbols (defined exports + undefined imports). Classified
///   by the same name patterns SymbolInspector uses: `_OBJC_CLASS_$_…`,
///   `_$s…`, etc. Internal and STAB symbols are skipped.
/// - Bytes of the `__TEXT,__cstring` section — the C string pool the image
///   actually references. We use the section's `addr` field, translated to a
///   file location, to read just that range.
///
/// **What we don't extract.**
/// - Obj-C section raw bytes (`__objc_classname` / `__objc_methname`). Same
///   reasoning as the dyld-cache symbol comment in SymbolInspector: those
///   sections, like `__TEXT,__cstring`, are merged across the whole cache, and
///   the per-image header references shared regions. A future commit can
///   apply the same per-image addr-and-size slicing we use for `__cstring`.
/// - LC_DYLD_INFO export tries / LC_DYLD_EXPORTS_TRIE. Modern Apple binaries
///   move their public exports there; without parsing the trie we miss them.
///   Not blocking for "find things by string" — those names usually appear in
///   the `__cstring` section as Obj-C selectors or string literals.
public nonisolated enum DyldCachedImageInspector {

    public struct Result: Sendable {
        public let symbols: [SymbolRow]
        /// Raw bytes of the image's `__TEXT,__cstring` slice. Caller decides
        /// whether to index into `strings_fts`.
        public let cstringBytes: Data?

        public init(symbols: [SymbolRow], cstringBytes: Data?) {
            self.symbols = symbols
            self.cstringBytes = cstringBytes
        }
    }

    public struct Limits: Sendable {
        public var maxSymbols: Int = 50_000
        public var maxCStringBytes: Int = 8 * 1024 * 1024

        public init() {}
    }

    /// Cache for already-opened LINKEDIT subcache files. For modern arm64e
    /// caches every image's `LC_SYMTAB.stroff` is a file offset within the
    /// `.NN.dyldlinkedit` subcache that holds the image's `__LINKEDIT`
    /// segment — typically one of three linkedit subcaches in a /System
    /// cache. We memory-map each one on first use so subsequent name
    /// lookups across thousands of images don't re-read hundreds of MB.
    public final class SharedStringTable: @unchecked Sendable {
        private let layout: DyldCacheLayout
        // url → mmap'd Data of the entire subcache file. `Data` with
        // `mappedIfSafe` keeps pages lazy: we only resident-fault the
        // bytes we actually read.
        private var mapped: [URL: Data] = [:]

        public init(layout: DyldCacheLayout) {
            self.layout = layout
        }

        /// Read a null-terminated C string at `nameOffset` from the
        /// subcache file backing the image whose `__LINKEDIT` segment
        /// lives at VM address `linkeditVMAddress`. `stroff` is the
        /// `LC_SYMTAB.stroff` field (a file offset within that subcache).
        public func lookup(linkeditVMAddress: UInt64, stroff: UInt64, nameOffset: Int) -> String? {
            guard nameOffset > 0 else { return nil }
            guard let loc = layout.locate(vmAddress: linkeditVMAddress) else { return nil }
            guard let data = ensureMapped(url: loc.url) else { return nil }
            let absoluteOffset = Int(stroff) + nameOffset
            guard absoluteOffset > 0, absoluteOffset < data.count else { return nil }
            let base = data.startIndex.advanced(by: absoluteOffset)
            var end = base
            let dataEnd = data.endIndex
            while end < dataEnd && data[end] != 0 {
                end = data.index(after: end)
            }
            if base == end { return nil }
            return String(data: data[base..<end], encoding: .utf8)
        }

        private func ensureMapped(url: URL) -> Data? {
            if let cached = mapped[url] { return cached }
            // mmap rather than read — a /System dyld_shared_cache linkedit
            // subcache is 200-600 MB and we only touch the string
            // pool ranges referenced by symbol names. Foundation marks
            // mappedIfSafe as a hint; on APFS we get the standard
            // mmap-with-MAP_FILE backing, which the kernel pages in on
            // demand.
            if let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
                mapped[url] = data
                return data
            }
            return nil
        }
    }

    /// Extract symbols and `__cstring` bytes for one cached image.
    ///
    /// `sharedStrtab` must outlive the call. It caches the cache's merged
    /// string pool across images so symbol-name lookups are O(1) instead of
    /// re-reading hundreds of MB per image.
    public static func extract(
        layout: DyldCacheLayout,
        sharedStrtab: SharedStringTable,
        imageAddress: UInt64,
        itemID: UUID,
        limits: Limits = Limits()
    ) -> Result? {
        guard let machO = layout.locate(vmAddress: imageAddress) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: machO.url) else { return nil }
        defer { try? handle.close() }

        do { try handle.seek(toOffset: machO.fileOffset) } catch { return nil }
        // 256 KB headroom for header + load commands. Cached dylibs typically
        // have under 64 KB of LCs, but stub-rich Swift binaries can grow.
        guard let head = try? handle.read(upToCount: 256 * 1024), head.count >= 32 else { return nil }

        let magic = head.readUInt32LE(at: 0)
        // Only 64-bit images are relevant in modern shared caches.
        let MH_MAGIC_64: UInt32 = 0xfeedfacf
        guard magic == MH_MAGIC_64 else { return nil }
        let ncmds = head.readUInt32LE(at: 16)

        var cursor = 32
        var symtab: SymtabFields?
        var cstring: SectionLocation?
        var linkeditVMAddress: UInt64 = 0
        // Walk load commands. We need LC_SYMTAB, __TEXT.__cstring's
        // location, and __LINKEDIT's VM address (so we can resolve which
        // subcache file the symbol/string tables live in — on modern
        // split caches that's a separate `.NN.dyldlinkedit` file).
        let LC_SYMTAB: UInt32 = 0x2
        let LC_SEGMENT_64: UInt32 = 0x19
        for _ in 0..<Int(ncmds) {
            guard cursor + 8 <= head.count else { break }
            let cmd = head.readUInt32LE(at: cursor + 0)
            let cmdsize = Int(head.readUInt32LE(at: cursor + 4))
            guard cmdsize >= 8, cursor + cmdsize <= head.count else { break }

            if cmd == LC_SYMTAB, cmdsize >= 24 {
                let symoff = head.readUInt32LE(at: cursor + 8)
                let nsyms  = head.readUInt32LE(at: cursor + 12)
                let stroff = head.readUInt32LE(at: cursor + 16)
                let strsize = head.readUInt32LE(at: cursor + 20)
                symtab = SymtabFields(
                    symoff: UInt64(symoff),
                    nsyms: Int(nsyms),
                    stroff: UInt64(stroff),
                    strsize: Int(strsize)
                )
            } else if cmd == LC_SEGMENT_64, cmdsize >= 72 {
                // Segment name is 16 bytes at offset +8.
                let segNameBytes = head.subdata(in: (cursor + 8)..<(cursor + 24))
                let name = segName(segNameBytes)
                if name == "__LINKEDIT" {
                    linkeditVMAddress = head.readUInt64LE(at: cursor + 24)
                } else if name == "__TEXT" {
                    let nsects = head.readUInt32LE(at: cursor + 64)
                    let sectionsBase = cursor + 72
                    // Each section_64 is 80 bytes: sectname(16) +
                    // segname(16) + addr(8) + size(8) + offset(4) +
                    // align(4) + reloff(4) + nreloc(4) + flags(4) +
                    // reserved1/2/3(12).
                    for s in 0..<Int(nsects) {
                        let base = sectionsBase + s * 80
                        guard base + 80 <= cursor + cmdsize else { break }
                        let sectNameBytes = head.subdata(in: base..<(base + 16))
                        if segName(sectNameBytes) == "__cstring" {
                            let addr = head.readUInt64LE(at: base + 32)
                            let size = head.readUInt64LE(at: base + 40)
                            cstring = SectionLocation(vmAddress: addr, size: size)
                            break
                        }
                    }
                }
            }
            cursor += cmdsize
        }

        var symbols: [SymbolRow] = []
        if let symtab,
           symtab.nsyms > 0,
           symtab.strsize > 0,
           linkeditVMAddress != 0 {
            symbols = readSymbols(
                layout: layout,
                sharedStrtab: sharedStrtab,
                linkeditVMAddress: linkeditVMAddress,
                fields: symtab,
                itemID: itemID,
                limits: limits
            )
        }

        var cstringBytes: Data?
        if let cstring,
           cstring.size > 0,
           cstring.size <= UInt64(limits.maxCStringBytes),
           let loc = layout.locate(vmAddress: cstring.vmAddress),
           let cHandle = try? FileHandle(forReadingFrom: loc.url) {
            defer { try? cHandle.close() }
            do {
                try cHandle.seek(toOffset: loc.fileOffset)
                cstringBytes = try cHandle.read(upToCount: Int(cstring.size))
            } catch { /* swallow — partial result is fine */ }
        }

        return Result(symbols: symbols, cstringBytes: cstringBytes)
    }

    /// Convert a `__TEXT,__cstring` blob into a single newline-delimited
    /// string suitable for the FTS5 indexer. Drops the null terminators and
    /// short strings under `minLength`.
    public static func cstringTokensText(_ blob: Data, minLength: Int = 4) -> String {
        var out: [String] = []
        var start = blob.startIndex
        var cursor = start
        let end = blob.endIndex
        while cursor < end {
            if blob[cursor] == 0 {
                if cursor > start, cursor - start >= minLength,
                   let s = String(data: blob[start..<cursor], encoding: .utf8) {
                    out.append(s)
                }
                start = blob.index(after: cursor)
                cursor = start
            } else {
                cursor = blob.index(after: cursor)
            }
        }
        if start < end, end - start >= minLength,
           let s = String(data: blob[start..<end], encoding: .utf8) {
            out.append(s)
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Internals

    private struct SymtabFields {
        let symoff: UInt64
        let nsyms: Int
        let stroff: UInt64
        let strsize: Int
    }

    private struct SectionLocation {
        let vmAddress: UInt64
        let size: UInt64
    }

    private static func readSymbols(
        layout: DyldCacheLayout,
        sharedStrtab: SharedStringTable,
        linkeditVMAddress: UInt64,
        fields: SymtabFields,
        itemID: UUID,
        limits: Limits
    ) -> [SymbolRow] {
        // For modern shared caches, LC_SYMTAB.symoff/stroff are file
        // offsets within the subcache file containing the image's
        // __LINKEDIT segment (typically a `.NN.dyldlinkedit` file on
        // split arm64e caches, or back inside the monolithic main cache
        // on x86_64). We resolve `linkeditVMAddress` to that subcache
        // and use symoff/stroff verbatim as offsets within it.
        guard let linkeditLoc = layout.locate(vmAddress: linkeditVMAddress) else { return [] }

        let nsymsCapped = min(fields.nsyms, limits.maxSymbols)
        let nlistBytesNeeded = nsymsCapped * 16

        guard let symHandle = try? FileHandle(forReadingFrom: linkeditLoc.url) else { return [] }
        defer { try? symHandle.close() }
        do { try symHandle.seek(toOffset: fields.symoff) } catch { return [] }
        guard let nlists = try? symHandle.read(upToCount: nlistBytesNeeded),
              nlists.count == nlistBytesNeeded else { return [] }

        let N_STAB: UInt8 = 0xe0
        let N_TYPE: UInt8 = 0x0e
        let N_EXT:  UInt8 = 0x01
        let N_UNDF: UInt8 = 0x00

        var out: [SymbolRow] = []
        out.reserveCapacity(nsymsCapped)
        for i in 0..<nsymsCapped {
            let base = i * 16
            let n_strx = nlists.readUInt32LE(at: base + 0)
            let n_type = nlists[nlists.startIndex.advanced(by: base + 4)]
            let n_desc = nlists.readUInt16LE(at: base + 6)
            if (n_type & N_STAB) != 0 { continue }
            if (n_type & N_EXT) == 0 { continue }
            guard let name = sharedStrtab.lookup(
                linkeditVMAddress: linkeditVMAddress,
                stroff: fields.stroff,
                nameOffset: Int(n_strx)
            ), !name.isEmpty else { continue }
            let typeBits = n_type & N_TYPE
            let kind: SymbolRow.Kind
            if typeBits == N_UNDF {
                kind = .undefined
            } else {
                kind = classifyDefined(name: name)
            }
            let ordinal: Int? = (kind == .undefined) ? Int(n_desc & 0xFF) : nil
            out.append(SymbolRow(
                itemID: itemID,
                name: name,
                demangled: nil,
                kind: kind,
                libraryOrdinal: ordinal
            ))
        }
        return out
    }

    private static func classifyDefined(name: String) -> SymbolRow.Kind {
        if name.hasPrefix("_OBJC_CLASS_$_") { return .objcClass }
        if name.hasPrefix("_OBJC_METACLASS_$_") { return .objcMetaClass }
        if name.hasPrefix("_OBJC_PROTOCOL_$_") { return .objcProtocol }
        if name.hasPrefix("_$s") || name.hasPrefix("_$S") {
            if let last = name.last {
                switch last {
                case "C": return .swiftClass
                case "V", "O": return .swiftStruct
                case "P": return .swiftStruct
                default: return .swiftClass
                }
            }
            return .swiftClass
        }
        return .function
    }

    private static func segName(_ data: Data) -> String {
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
    func readUInt16LE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        let base = startIndex.advanced(by: offset)
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }
}
