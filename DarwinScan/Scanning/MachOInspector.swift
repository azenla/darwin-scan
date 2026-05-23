import Foundation

// MARK: - Mach-O constants
// Defined inline rather than importing `MachO` because the C structs there are
// `_Sendable`-unfriendly and the constants are tiny. These match
// <mach-o/loader.h> and <mach-o/fat.h> as of the Darwin sources.
//
// All file-scope constants and helpers are `nonisolated` so they can be used
// from the background `ScanWorker` actor — the project defaults file-scope
// declarations to `@MainActor` (SWIFT_DEFAULT_ACTOR_ISOLATION).

nonisolated private let MH_MAGIC: UInt32     = 0xfeedface
nonisolated private let MH_CIGAM: UInt32     = 0xcefaedfe
nonisolated private let MH_MAGIC_64: UInt32  = 0xfeedfacf
nonisolated private let MH_CIGAM_64: UInt32  = 0xcffaedfe
nonisolated private let FAT_MAGIC: UInt32    = 0xcafebabe
nonisolated private let FAT_CIGAM: UInt32    = 0xbebafeca
nonisolated private let FAT_MAGIC_64: UInt32 = 0xcafebabf
nonisolated private let FAT_CIGAM_64: UInt32 = 0xbfbafeca

nonisolated private let MH_OBJECT: UInt32      = 0x1
nonisolated private let MH_EXECUTE: UInt32     = 0x2
nonisolated private let MH_FVMLIB: UInt32      = 0x3
nonisolated private let MH_CORE: UInt32        = 0x4
nonisolated private let MH_PRELOAD: UInt32     = 0x5
nonisolated private let MH_DYLIB: UInt32       = 0x6
nonisolated private let MH_DYLINKER: UInt32    = 0x7
nonisolated private let MH_BUNDLE: UInt32      = 0x8
nonisolated private let MH_DYLIB_STUB: UInt32  = 0x9
nonisolated private let MH_DSYM: UInt32        = 0xa
nonisolated private let MH_KEXT_BUNDLE: UInt32 = 0xb

nonisolated private let LC_REQ_DYLD: UInt32         = 0x80000000
nonisolated private let LC_SEGMENT: UInt32          = 0x1
nonisolated private let LC_SEGMENT_64: UInt32       = 0x19
nonisolated private let LC_LOAD_DYLIB: UInt32       = 0xc
nonisolated private let LC_ID_DYLIB: UInt32         = 0xd
nonisolated private let LC_LOAD_WEAK_DYLIB: UInt32  = 0x18 | LC_REQ_DYLD
nonisolated private let LC_RPATH: UInt32            = 0x1c | LC_REQ_DYLD
nonisolated private let LC_REEXPORT_DYLIB: UInt32   = 0x1f | LC_REQ_DYLD
nonisolated private let LC_VERSION_MIN_MACOSX: UInt32   = 0x24
nonisolated private let LC_VERSION_MIN_IPHONEOS: UInt32 = 0x25
nonisolated private let LC_VERSION_MIN_TVOS: UInt32     = 0x2f
nonisolated private let LC_VERSION_MIN_WATCHOS: UInt32  = 0x30
nonisolated private let LC_BUILD_VERSION: UInt32        = 0x32
nonisolated private let LC_CODE_SIGNATURE: UInt32       = 0x1d

nonisolated private let CPU_ARCH_ABI64: UInt32     = 0x01000000
nonisolated private let CPU_ARCH_ABI64_32: UInt32  = 0x02000000

private struct CPUArch: Sendable {
    let cputype: UInt32
    let cpusubtype: UInt32
}

/// Returns a human name for a (cputype, cpusubtype). We don't bother with
/// every Apple subtype — just enough to differentiate arm64, arm64e, x86_64h, etc.
nonisolated private func archName(cputype: UInt32, cpusubtype: UInt32) -> String {
    let subtypeMask: UInt32 = 0x00FFFFFF
    let sub = cpusubtype & subtypeMask
    switch cputype {
    case 0x01000007: // CPU_TYPE_X86_64
        return sub == 8 ? "x86_64h" : "x86_64"
    case 0x7: // CPU_TYPE_X86
        return "i386"
    case 0x0100000C: // CPU_TYPE_ARM64
        // arm64e == 2, arm64v8 == 1, arm64 == 0
        return sub == 2 ? "arm64e" : "arm64"
    case 0x0200000C: // CPU_TYPE_ARM64_32 (watchOS)
        return "arm64_32"
    case 0xc: // CPU_TYPE_ARM
        return "arm"
    default:
        return String(format: "cpu-%x-%x", cputype, sub)
    }
}

nonisolated private func platformName(_ platform: UInt32) -> String {
    switch platform {
    case 1:  return "macos"
    case 2:  return "ios"
    case 3:  return "tvos"
    case 4:  return "watchos"
    case 5:  return "bridgeos"
    case 6:  return "maccatalyst"
    case 7:  return "iossimulator"
    case 8:  return "tvossimulator"
    case 9:  return "watchossimulator"
    case 10: return "driverkit"
    case 11: return "visionos"
    case 12: return "visionossimulator"
    default: return "platform-\(platform)"
    }
}

/// Decoded version triple from a 32-bit Mach-O version word
/// (XXXX.YY.ZZ → 0xXXXXYYZZ).
nonisolated private func decodeMachOVersion(_ raw: UInt32) -> String {
    let major = (raw >> 16) & 0xFFFF
    let minor = (raw >> 8) & 0xFF
    let patch = raw & 0xFF
    return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
}

// MARK: - Inspector

/// Parses Mach-O / FAT Mach-O headers from disk to produce `ExecutableInfo`.
/// Returns nil if the file isn't Mach-O.
nonisolated struct MachOInspector: Sendable {

    nonisolated func inspect(url: URL) -> ExecutableInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // Read enough bytes to cover the largest reasonable header + load
        // commands. 256 KB is plenty for /System binaries and avoids a second
        // syscall in the common case.
        guard let bytes = try? handle.read(upToCount: 256 * 1024), bytes.count >= 8 else { return nil }
        let magic = bytes.readUInt32(at: 0, bigEndian: false)
        switch magic {
        case MH_MAGIC, MH_CIGAM, MH_MAGIC_64, MH_CIGAM_64:
            return parseSingleArch(data: bytes, sliceOffset: 0, otherArchs: [])
        case FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64:
            return parseFat(handle: handle, leadingBytes: bytes, magic: magic)
        default:
            return nil
        }
    }

    // MARK: FAT

    private nonisolated func parseFat(handle: FileHandle, leadingBytes: Data, magic: UInt32) -> ExecutableInfo? {
        let isBig = (magic == FAT_CIGAM || magic == FAT_CIGAM_64)
        let is64  = (magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64)
        guard leadingBytes.count >= 8 else { return nil }
        let nfat = leadingBytes.readUInt32(at: 4, bigEndian: isBig)
        let entrySize = is64 ? 32 : 20
        let needed = 8 + Int(nfat) * entrySize
        let header: Data
        if leadingBytes.count >= needed {
            header = leadingBytes
        } else {
            // Re-read from start.
            do {
                try handle.seek(toOffset: 0)
                guard let bigger = try handle.read(upToCount: needed) else { return nil }
                header = bigger
            } catch { return nil }
        }
        var archs: [CPUArch] = []
        var firstSliceOffset: UInt64 = 0
        for i in 0..<Int(nfat) {
            let base = 8 + i * entrySize
            let cputype     = header.readUInt32(at: base + 0, bigEndian: isBig)
            let cpusubtype  = header.readUInt32(at: base + 4, bigEndian: isBig)
            let offset: UInt64
            if is64 {
                offset = header.readUInt64(at: base + 8, bigEndian: isBig)
            } else {
                offset = UInt64(header.readUInt32(at: base + 8, bigEndian: isBig))
            }
            archs.append(CPUArch(cputype: cputype, cpusubtype: cpusubtype))
            if i == 0 { firstSliceOffset = offset }
        }
        guard !archs.isEmpty else { return nil }

        // Read the first slice for everything except architecture list.
        do {
            try handle.seek(toOffset: firstSliceOffset)
        } catch { return nil }
        guard let sliceData = try? handle.read(upToCount: 256 * 1024), sliceData.count >= 32 else { return nil }
        let extraArchs = archs.dropFirst().map { archName(cputype: $0.cputype, cpusubtype: $0.cpusubtype) }
        var info = parseSingleArch(data: sliceData, sliceOffset: 0, otherArchs: Array(extraArchs))
        info?.isFatBinary = true
        return info
    }

    // MARK: Single-arch

    private nonisolated func parseSingleArch(data: Data, sliceOffset: Int, otherArchs: [String]) -> ExecutableInfo? {
        guard data.count >= 32 else { return nil }
        let magic = data.readUInt32(at: sliceOffset, bigEndian: false)
        let isBig = (magic == MH_CIGAM || magic == MH_CIGAM_64)
        let is64  = (magic == MH_MAGIC_64 || magic == MH_CIGAM_64)

        let cputype    = data.readUInt32(at: sliceOffset + 4, bigEndian: isBig)
        let cpusubtype = data.readUInt32(at: sliceOffset + 8, bigEndian: isBig)
        let filetype   = data.readUInt32(at: sliceOffset + 12, bigEndian: isBig)
        let ncmds      = data.readUInt32(at: sliceOffset + 16, bigEndian: isBig)
        let _sizeofcmds = data.readUInt32(at: sliceOffset + 20, bigEndian: isBig)
        _ = _sizeofcmds

        let loadCommandsOffset = sliceOffset + (is64 ? 32 : 28)
        var cursor = loadCommandsOffset

        var linked: [String] = []
        var rpaths: [String] = []
        var minOS: String? = nil
        var platform: String? = nil
        var sdkVersion: String? = nil
        var hasCodeSig = false

        for _ in 0..<Int(ncmds) {
            guard cursor + 8 <= data.count else { break }
            let cmd     = data.readUInt32(at: cursor + 0, bigEndian: isBig)
            let cmdsize = data.readUInt32(at: cursor + 4, bigEndian: isBig)
            guard cmdsize >= 8, cursor + Int(cmdsize) <= data.count else { break }

            switch cmd {
            case LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB:
                // dylib_command: { cmd, cmdsize, name_offset, timestamp, current, compat }
                let nameOffset = Int(data.readUInt32(at: cursor + 8, bigEndian: isBig))
                if let name = readCString(in: data, base: cursor, offset: nameOffset, maxLen: Int(cmdsize) - nameOffset) {
                    linked.append(name)
                }
            case LC_RPATH:
                let nameOffset = Int(data.readUInt32(at: cursor + 8, bigEndian: isBig))
                if let name = readCString(in: data, base: cursor, offset: nameOffset, maxLen: Int(cmdsize) - nameOffset) {
                    rpaths.append(name)
                }
            case LC_VERSION_MIN_MACOSX:
                platform = "macos"
                minOS = decodeMachOVersion(data.readUInt32(at: cursor + 8, bigEndian: isBig))
                sdkVersion = decodeMachOVersion(data.readUInt32(at: cursor + 12, bigEndian: isBig))
            case LC_VERSION_MIN_IPHONEOS:
                platform = "ios"
                minOS = decodeMachOVersion(data.readUInt32(at: cursor + 8, bigEndian: isBig))
                sdkVersion = decodeMachOVersion(data.readUInt32(at: cursor + 12, bigEndian: isBig))
            case LC_VERSION_MIN_TVOS:
                platform = "tvos"
                minOS = decodeMachOVersion(data.readUInt32(at: cursor + 8, bigEndian: isBig))
            case LC_VERSION_MIN_WATCHOS:
                platform = "watchos"
                minOS = decodeMachOVersion(data.readUInt32(at: cursor + 8, bigEndian: isBig))
            case LC_BUILD_VERSION:
                platform = platformName(data.readUInt32(at: cursor + 8, bigEndian: isBig))
                minOS = decodeMachOVersion(data.readUInt32(at: cursor + 12, bigEndian: isBig))
                sdkVersion = decodeMachOVersion(data.readUInt32(at: cursor + 16, bigEndian: isBig))
            case LC_CODE_SIGNATURE:
                hasCodeSig = true
            default:
                break
            }
            cursor += Int(cmdsize)
        }
        _ = hasCodeSig  // future: parse code signature blob for team id

        let kind: ExecutableInfo.Kind = {
            switch filetype {
            case MH_OBJECT:      return .object
            case MH_EXECUTE:     return .executable
            case MH_DYLIB:       return .dylib
            case MH_BUNDLE:      return .bundle
            case MH_DYLINKER:    return .dylinker
            case MH_KEXT_BUNDLE: return .kext
            case MH_DSYM:        return .dsym
            case MH_CORE:        return .core
            default:             return .unknown
            }
        }()

        let firstArch = archName(cputype: cputype, cpusubtype: cpusubtype)
        var archs = [firstArch]
        archs.append(contentsOf: otherArchs)

        return ExecutableInfo(
            kind: kind,
            roles: [],
            architectures: archs,
            isFatBinary: !otherArchs.isEmpty,
            minOS: minOS,
            platform: platform,
            sdkVersion: sdkVersion,
            linkedLibraries: linked,
            rpaths: rpaths,
            entitlementsXML: nil,
            teamIdentifier: nil,
            signingIdentifier: nil,
            isHardenedRuntime: false,
            isApple: false,        // filled in by Scanner via path heuristic
            isCrossPlatformTool: false,
            usageLine: nil,
            looksLikeDaemonByStrings: false,
            stringsBlobRef: nil
        )
    }

    /// Reads a null-terminated UTF-8 string starting at `base + offset`.
    private nonisolated func readCString(in data: Data, base: Int, offset: Int, maxLen: Int) -> String? {
        let start = base + offset
        guard start >= 0, start < data.count, maxLen > 0 else { return nil }
        let end = min(start + maxLen, data.count)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(end - start)
        for i in start..<end {
            let b = data[data.startIndex.advanced(by: i)]
            if b == 0 { break }
            bytes.append(b)
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}

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
