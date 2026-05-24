import Foundation

/// Extracts symbol names from Mach-O binaries by parsing LC_SYMTAB. Returns
/// `SymbolRow` values ready to insert into the database's `symbols` table.
///
/// What gets extracted:
/// - External defined symbols (`_OBJC_CLASS_$_…`, `_OBJC_METACLASS_$_…`,
///   `_$s…` Swift mangled names, plain C/C++ function/data symbols).
/// - External undefined (imported) symbols, classified as `.undefined`.
/// - Internal symbols are skipped — they bloat the index without helping
///   anyone search for "where does Foo live."
/// - STAB (debug) symbols are skipped.
///
/// What is NOT extracted:
/// - Swift demangled names. Swift's demangler ships as a private library
///   (`libswiftDemangle.dylib`) and shelling out to `swift demangle` is too
///   slow per-binary. The raw mangled name (`_$s10Foundation11FileManagerC`)
///   is still substring-searchable, and a future commit can wire in
///   demangling if it proves valuable.
/// - Obj-C class names that appear ONLY in `__objc_classlist` /
///   `__objc_classname`. This is the common case on modern macOS: the
///   Apple toolchain strips `_OBJC_CLASS_$_…` exports from on-disk
///   binaries and ships them as section data referenced from
///   `__objc_classlist` pointers. To find those names we'd need to walk
///   the section, chase the class_ro pointer into `__objc_classname`
///   strings, and re-slide for runtime addressing. Left to a future
///   commit — the LC_SYMTAB path catches everything in older binaries
///   and the dyld_shared_cache is where most modern Obj-C content lives
///   anyway.
///
/// ## Mach-O reading
///
/// We re-parse the header here rather than threading state through from
/// `MachOInspector` — the header is tiny and parsing it twice is cheaper
/// than coupling. The bulk of the cost is reading the symbol + string
/// tables, which can be 10+ MB combined for a large dylib.
///
/// Memory bound: a 50,000-symbol cap × 16-byte nlist_64 entries = 800 KB of
/// raw symbol bytes per binary. The string table is capped at 64 MB; bigger
/// (rare for application binaries; common for dyld_shared_cache slices,
/// which aren't parsed here anyway) is rejected with an empty result.
public nonisolated enum SymbolInspector {

    public struct Limits: Sendable {
        /// Maximum number of symbols to return per binary. Beyond this we
        /// keep the first N by file order and drop the rest — they're a
        /// stable subset (the symbol table is laid out external-first).
        public var maxSymbols: Int = 50_000
        /// Maximum size of the string table we'll read. If a binary's
        /// strtab is larger than this, we skip the binary entirely; the
        /// dyld shared cache subcaches are the only realistic offenders.
        public var maxStringTableBytes: Int = 64 * 1024 * 1024
        /// Maximum binary size. Files larger than this are skipped — the
        /// cost/value is bad and a quick scan should stay snappy.
        public var maxBinarySize: Int64 = 512 * 1024 * 1024

        public init() {}
    }

    /// Pure extraction. `itemID` is stamped onto every produced row so the
    /// caller can batch-insert without rewriting them.
    public static func extract(
        url: URL,
        itemID: UUID,
        limits: Limits = Limits()
    ) -> [SymbolRow] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              size <= limits.maxBinarySize else { return [] }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        // Read enough to cover FAT header + initial slice header + load commands.
        guard let head = try? handle.read(upToCount: 64 * 1024), head.count >= 8 else { return [] }
        let magic = head.readUInt32(at: 0, bigEndian: false)

        let sliceOffset: UInt64
        let sliceMagic: UInt32
        let sliceBytes: Data

        switch magic {
        case MH_MAGIC, MH_CIGAM, MH_MAGIC_64, MH_CIGAM_64:
            sliceOffset = 0
            sliceMagic = magic
            sliceBytes = head
        case FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64:
            guard let first = firstFatSlice(handle: handle, header: head, magic: magic) else { return [] }
            sliceOffset = first.offset
            do {
                try handle.seek(toOffset: first.offset)
            } catch { return [] }
            guard let slice = try? handle.read(upToCount: 64 * 1024), slice.count >= 32 else { return [] }
            sliceBytes = slice
            sliceMagic = slice.readUInt32(at: 0, bigEndian: false)
        default:
            return []
        }

        let isBig = (sliceMagic == MH_CIGAM || sliceMagic == MH_CIGAM_64)
        let is64  = (sliceMagic == MH_MAGIC_64 || sliceMagic == MH_CIGAM_64)
        guard is64 else { return [] }  // 32-bit is irrelevant on modern macOS.

        // Walk load commands to find LC_SYMTAB.
        let ncmds = sliceBytes.readUInt32(at: 16, bigEndian: isBig)
        var cursor = 32
        var symtab: SymtabLocation?
        for _ in 0..<Int(ncmds) {
            guard cursor + 8 <= sliceBytes.count else { break }
            let cmd     = sliceBytes.readUInt32(at: cursor + 0, bigEndian: isBig)
            let cmdsize = sliceBytes.readUInt32(at: cursor + 4, bigEndian: isBig)
            // Every well-formed load command carries cmd+cmdsize (8 bytes
            // minimum). Older code here required cmdsize >= 24 (the size of
            // a symtab_command), which prematurely terminated the walk when
            // a smaller command came first — and on most Apple binaries
            // LC_BUILD_VERSION / LC_UUID / LC_VERSION_MIN_* all precede
            // LC_SYMTAB. Result: 0 symbols extracted from anything but the
            // rare binary whose LC_SYMTAB happens to be the first command.
            guard cmdsize >= 8, cursor + Int(cmdsize) <= sliceBytes.count else { break }
            if cmd == LC_SYMTAB, cmdsize >= 24 {
                let symoff  = sliceBytes.readUInt32(at: cursor + 8,  bigEndian: isBig)
                let nsyms   = sliceBytes.readUInt32(at: cursor + 12, bigEndian: isBig)
                let stroff  = sliceBytes.readUInt32(at: cursor + 16, bigEndian: isBig)
                let strsize = sliceBytes.readUInt32(at: cursor + 20, bigEndian: isBig)
                symtab = SymtabLocation(
                    symoff: UInt64(symoff),
                    nsyms: Int(nsyms),
                    stroff: UInt64(stroff),
                    strsize: Int(strsize)
                )
                break
            }
            cursor += Int(cmdsize)
        }
        guard let symtab else { return [] }
        if symtab.strsize > limits.maxStringTableBytes { return [] }

        // The string table can be tens of MB. Read it once into memory; we
        // need random access into it by index, and FileHandle seeks per
        // symbol would dominate runtime. The cap above guards against the
        // pathological cases (dyld_shared_cache slices).
        do {
            try handle.seek(toOffset: sliceOffset + symtab.stroff)
        } catch { return [] }
        guard let strtab = try? handle.read(upToCount: symtab.strsize),
              strtab.count == symtab.strsize else { return [] }

        // Symbol table: nsyms entries × 16 bytes (nlist_64).
        let symtabBytes = symtab.nsyms * 16
        do {
            try handle.seek(toOffset: sliceOffset + symtab.symoff)
        } catch { return [] }
        guard let nlistBytes = try? handle.read(upToCount: symtabBytes),
              nlistBytes.count == symtabBytes else { return [] }

        var out: [SymbolRow] = []
        out.reserveCapacity(min(symtab.nsyms, limits.maxSymbols))

        for i in 0..<symtab.nsyms {
            if out.count >= limits.maxSymbols { break }
            let base = i * 16
            let n_strx  = nlistBytes.readUInt32(at: base + 0, bigEndian: isBig)
            let n_type  = nlistBytes[nlistBytes.startIndex.advanced(by: base + 4)]
            // n_sect (1 byte) and n_desc (2 bytes) come next; we don't use them.
            let n_desc  = nlistBytes.readUInt16(at: base + 6, bigEndian: isBig)

            // Skip debug (STAB) symbols.
            if (n_type & N_STAB) != 0 { continue }
            // Skip internal symbols (we want exports + imports).
            if (n_type & N_EXT) == 0 { continue }

            guard let name = readNameFromStrtab(strtab, offset: Int(n_strx)),
                  !name.isEmpty else { continue }

            let typeBits = n_type & N_TYPE
            let kind: SymbolRow.Kind
            if typeBits == N_UNDF {
                kind = .undefined
            } else {
                kind = classifyDefined(name: name)
            }

            // n_desc's low byte holds the library ordinal for two-level
            // namespace lookups (undefined symbols). Capture it so the UI
            // can show "imported from dylib #N".
            let ordinal: Int?
            if kind == .undefined {
                ordinal = Int(n_desc & 0xFF)
            } else {
                ordinal = nil
            }

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

    // MARK: - FAT helpers

    private struct FatSliceInfo {
        let offset: UInt64
        let cputype: UInt32
        let cpusubtype: UInt32
    }

    private static func firstFatSlice(handle: FileHandle, header: Data, magic: UInt32) -> FatSliceInfo? {
        let isBig = (magic == FAT_CIGAM || magic == FAT_CIGAM_64)
        let is64  = (magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64)
        guard header.count >= 8 else { return nil }
        let nfat = header.readUInt32(at: 4, bigEndian: isBig)
        guard nfat > 0 else { return nil }
        let entrySize = is64 ? 32 : 20
        let needed = 8 + entrySize
        let buf: Data
        if header.count >= needed {
            buf = header
        } else {
            do {
                try handle.seek(toOffset: 0)
                guard let bigger = try handle.read(upToCount: needed) else { return nil }
                buf = bigger
            } catch { return nil }
        }
        let cputype    = buf.readUInt32(at: 8 + 0, bigEndian: isBig)
        let cpusubtype = buf.readUInt32(at: 8 + 4, bigEndian: isBig)
        let offset: UInt64
        if is64 {
            offset = buf.readUInt64(at: 8 + 8, bigEndian: isBig)
        } else {
            offset = UInt64(buf.readUInt32(at: 8 + 8, bigEndian: isBig))
        }
        return FatSliceInfo(offset: offset, cputype: cputype, cpusubtype: cpusubtype)
    }

    // MARK: - Strtab

    /// Read a null-terminated UTF-8 string from the string table starting at
    /// `offset`. Returns nil for the empty-string sentinel (n_strx==0) and
    /// for out-of-bounds offsets.
    private static func readNameFromStrtab(_ strtab: Data, offset: Int) -> String? {
        guard offset > 0, offset < strtab.count else { return nil }
        let start = strtab.startIndex.advanced(by: offset)
        var end = start
        let dataEnd = strtab.endIndex
        while end < dataEnd && strtab[end] != 0 {
            end = strtab.index(after: end)
        }
        if start == end { return nil }
        return String(data: strtab[start..<end], encoding: .utf8)
    }

    // MARK: - Classification

    /// Classify a defined external symbol by name pattern. Cheap heuristics
    /// — full demangling would be more accurate but isn't worth the cost.
    private static func classifyDefined(name: String) -> SymbolRow.Kind {
        if name.hasPrefix("_OBJC_CLASS_$_") {
            return .objcClass
        }
        if name.hasPrefix("_OBJC_METACLASS_$_") {
            return .objcMetaClass
        }
        if name.hasPrefix("_OBJC_PROTOCOL_$_") {
            return .objcProtocol
        }
        // Swift mangled symbols: leading `_$s` or `_$S` (release vs old
        // stable). The actual type kind (class/struct/protocol) requires a
        // demangler — bucket them all into .swiftClass for now since that's
        // what users typically search for. The mangled trailer encodes the
        // kind ('C' = class, 'V' = struct, 'O' = enum, 'P' = protocol) but
        // parsing it correctly means reimplementing Swift's mangler.
        if name.hasPrefix("_$s") || name.hasPrefix("_$S") {
            // Best-effort kind from the last mangled-kind char if visible.
            if let last = name.last {
                switch last {
                case "C": return .swiftClass
                case "V", "O": return .swiftStruct
                case "P": return .swiftStruct  // promotion: protocols indexed as struct kind
                default:  return .swiftClass
                }
            }
            return .swiftClass
        }
        return .function
    }

    // MARK: - SymtabLocation

    private struct SymtabLocation {
        let symoff: UInt64
        let nsyms: Int
        let stroff: UInt64
        let strsize: Int
    }
}

// MARK: - Mach-O constants (local copies to keep this file self-contained)

nonisolated private let MH_MAGIC: UInt32     = 0xfeedface
nonisolated private let MH_CIGAM: UInt32     = 0xcefaedfe
nonisolated private let MH_MAGIC_64: UInt32  = 0xfeedfacf
nonisolated private let MH_CIGAM_64: UInt32  = 0xcffaedfe
nonisolated private let FAT_MAGIC: UInt32    = 0xcafebabe
nonisolated private let FAT_CIGAM: UInt32    = 0xbebafeca
nonisolated private let FAT_MAGIC_64: UInt32 = 0xcafebabf
nonisolated private let FAT_CIGAM_64: UInt32 = 0xbfbafeca

nonisolated private let LC_SYMTAB: UInt32 = 0x2

nonisolated private let N_STAB: UInt8 = 0xe0
nonisolated private let N_TYPE: UInt8 = 0x0e
nonisolated private let N_EXT:  UInt8 = 0x01
nonisolated private let N_UNDF: UInt8 = 0x00

// MARK: - Data helpers

nonisolated private extension Data {
    func readUInt32(at offset: Int, bigEndian: Bool) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let base = startIndex.advanced(by: offset)
        let b0 = UInt32(self[base])
        let b1 = UInt32(self[base + 1])
        let b2 = UInt32(self[base + 2])
        let b3 = UInt32(self[base + 3])
        let le = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
        return bigEndian ? le.byteSwapped : le
    }

    func readUInt16(at offset: Int, bigEndian: Bool) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        let base = startIndex.advanced(by: offset)
        let b0 = UInt16(self[base])
        let b1 = UInt16(self[base + 1])
        let le = b0 | (b1 << 8)
        return bigEndian ? le.byteSwapped : le
    }

    func readUInt64(at offset: Int, bigEndian: Bool) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        let base = startIndex.advanced(by: offset)
        var le: UInt64 = 0
        for i in 0..<8 {
            le |= UInt64(self[base + i]) << (8 * i)
        }
        return bigEndian ? le.byteSwapped : le
    }
}
