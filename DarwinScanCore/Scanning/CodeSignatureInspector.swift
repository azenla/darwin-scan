import Foundation

/// Parses the LC_CODE_SIGNATURE blob in a Mach-O slice to extract the
/// signing identifier (typically the bundle id) and the Apple Developer
/// Team Identifier. Hardened-runtime status comes from the CodeDirectory
/// flags too.
///
/// The blob is a `CS_SuperBlob` of count-many sub-blobs; the one we care
/// about is the `CodeDirectory` (type `0xFADE0C02`). All fields in the
/// blob format are stored **big-endian** on disk, regardless of host
/// byte order.
///
/// What we extract today:
///   - `signingIdentifier`: the bundle identifier the binary signed as,
///     read from `identOffset` inside the CodeDirectory.
///   - `teamIdentifier`: the developer team id (e.g. "ABCDE12345"),
///     present when the CodeDirectory version >= 0x20200.
///   - `isHardenedRuntime`: the CS_HARDENED_RUNTIME flag (0x00010000)
///     in CodeDirectory.flags.
///
/// What's deliberately skipped:
///   - Entitlements blob (XML in subblob type 5). We could expose it but
///     it'd bloat ScanItem.payload; better as an on-demand fetch.
///   - Requirements (binary blob type 2). Apple-internal format with
///     limited user value.
///   - CMS signature blob (type 0x10000). Used by codesign verify, not
///     by our index.
public nonisolated enum CodeSignatureInspector {

    public struct Info: Sendable, Hashable {
        public var signingIdentifier: String?
        public var teamIdentifier: String?
        public var isHardenedRuntime: Bool
        /// CodeDirectory version (eg 0x20400 == 132100). Surfaced for
        /// completeness; nothing in the UI uses it yet.
        public var codeDirectoryVersion: UInt32
    }

    /// Read the SuperBlob at `fileOffset` inside `url` and decode the
    /// CodeDirectory. Returns nil if the blob doesn't parse — that's the
    /// normal outcome for unsigned binaries, ad-hoc-signed test tools, and
    /// the dozen old-format edge cases we don't bother handling.
    public static func parse(url: URL, fileOffset: UInt64, size: UInt64) -> Info? {
        // Apply a sanity cap. Real signatures are <200 KB on macOS; a
        // multi-MB blob is bogus or one of the dyld cache's omnibus
        // signatures that we don't want to slurp anyway.
        let cap: UInt64 = 4 * 1024 * 1024
        let clamped = min(size, cap)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: fileOffset)
        } catch { return nil }
        guard let blob = try? handle.read(upToCount: Int(clamped)),
              blob.count >= 12 else { return nil }

        // CS_SuperBlob magic = 0xFADE0CC0 (big-endian on disk).
        let superMagic = blob.readUInt32BE(at: 0)
        guard superMagic == 0xFADE_0CC0 else { return nil }
        let count = Int(blob.readUInt32BE(at: 8))
        // BlobIndex array starts at offset 12, 8 bytes per entry
        // (type:4, offset:4).
        guard 12 + count * 8 <= blob.count else { return nil }

        for i in 0..<count {
            let entryBase = 12 + i * 8
            // type is the BlobIndex.type, NOT the magic. We use it only
            // as a hint; the authoritative kind is the inner blob's magic.
            let _ = blob.readUInt32BE(at: entryBase)
            let off = Int(blob.readUInt32BE(at: entryBase + 4))
            guard off + 8 <= blob.count else { continue }
            let innerMagic = blob.readUInt32BE(at: off)
            if innerMagic == 0xFADE_0C02 {
                // CodeDirectory.
                return decodeCodeDirectory(blob: blob, cdOffset: off)
            }
        }
        return nil
    }

    private static func decodeCodeDirectory(blob: Data, cdOffset: Int) -> Info {
        // CS_CodeDirectory layout (all big-endian):
        //   0x00 magic
        //   0x04 length
        //   0x08 version
        //   0x0C flags
        //   0x10 hashOffset
        //   0x14 identOffset      → offset from start of CodeDirectory to the bundle id string
        //   0x18 nSpecialSlots
        //   0x1C nCodeSlots
        //   0x20 codeLimit
        //   0x24 hashSize (u8)
        //   0x25 hashType (u8)
        //   0x26 platform (u8)
        //   0x27 pageSize (u8)
        //   0x28 spare2
        //   0x2C scatterOffset    (version >= 0x20100)
        //   0x30 teamOffset       (version >= 0x20200)
        //   …
        let version = blob.readUInt32BE(at: cdOffset + 0x08)
        let flags   = blob.readUInt32BE(at: cdOffset + 0x0C)
        let identOffset = Int(blob.readUInt32BE(at: cdOffset + 0x14))
        var teamOffset: Int = 0
        if version >= 0x20200 {
            teamOffset = Int(blob.readUInt32BE(at: cdOffset + 0x30))
        }

        let identifier = readCString(blob: blob, base: cdOffset, offset: identOffset)
        let teamID: String?
        if teamOffset > 0 {
            teamID = readCString(blob: blob, base: cdOffset, offset: teamOffset)
        } else {
            teamID = nil
        }

        // CS_HARDENED_RUNTIME = 0x00010000 (per Apple's cs_blobs.h).
        let hardenedFlag: UInt32 = 0x0001_0000
        let isHardened = (flags & hardenedFlag) != 0

        return Info(
            signingIdentifier: identifier,
            teamIdentifier: teamID,
            isHardenedRuntime: isHardened,
            codeDirectoryVersion: version
        )
    }

    private static func readCString(blob: Data, base: Int, offset: Int) -> String? {
        let start = base + offset
        guard start >= 0, start < blob.count else { return nil }
        var bytes: [UInt8] = []
        var i = start
        while i < blob.count {
            let b = blob[blob.startIndex.advanced(by: i)]
            if b == 0 { break }
            bytes.append(b)
            if bytes.count > 256 { break } // sanity guard
            i += 1
        }
        if bytes.isEmpty { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }
}

nonisolated private extension Data {
    func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let base = startIndex.advanced(by: offset)
        let b0 = UInt32(self[base])
        let b1 = UInt32(self[base + 1])
        let b2 = UInt32(self[base + 2])
        let b3 = UInt32(self[base + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
