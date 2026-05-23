import Foundation
import Compression

nonisolated enum ManPageInspector {
    /// Best-effort parse of a man page header to extract NAME and a one-line
    /// description. Handles gzipped (`.gz`) man pages, which is the dominant
    /// form on macOS — `/usr/share/man/man1/ls.1.gz`, etc.
    static func inspect(url: URL) -> (ManPageInfo, plainTextHead: String?)? {
        let filename = url.lastPathComponent
        let compressed = filename.hasSuffix(".gz")
        guard let section = sectionFromPath(url.path) else { return nil }

        let data: Data?
        if compressed {
            data = decompressGzip(url: url)
        } else {
            data = try? Data(contentsOf: url)
        }
        guard let bytes = data else { return nil }
        let text = String(data: bytes, encoding: .utf8)
            ?? String(data: bytes, encoding: .isoLatin1)
            ?? ""

        let (title, description) = extractNameLine(from: text)
        let info = ManPageInfo(
            section: section,
            title: title,
            description: description,
            compressed: compressed
        )
        return (info, text.isEmpty ? nil : text)
    }

    /// `/usr/share/man/manN/foo.N.gz` → "N". We don't trust the filename
    /// because some bundles drop man pages with arbitrary names; instead we
    /// look at the parent directory.
    private static func sectionFromPath(_ path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        let last = (parent as NSString).lastPathComponent
        guard last.hasPrefix("man") else { return nil }
        let suffix = last.dropFirst(3)
        return suffix.isEmpty ? nil : String(suffix)
    }

    /// Extracts the `.SH NAME` block's payload:
    ///     ls \- list directory contents
    /// → ("ls", "list directory contents").
    private static func extractNameLine(from text: String) -> (String?, String?) {
        let lines = text.components(separatedBy: "\n")
        var inName = false
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased() == ".SH NAME" || line.uppercased() == ".SH \"NAME\"" {
                inName = true
                continue
            }
            if inName, !line.isEmpty, !line.hasPrefix(".") {
                // The classic shape:  "ls \- list directory contents"
                let parts = line.components(separatedBy: "\\-")
                if parts.count >= 2 {
                    let titleRaw = parts[0]
                    let descRaw = parts.dropFirst().joined(separator: "-")
                    return (titleRaw.trimmingCharacters(in: .whitespacesAndNewlines),
                            descRaw.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                // Fallback: take the line itself.
                return (line, nil)
            }
            if i > 200 { break }
        }
        return (nil, nil)
    }

    /// Streaming gzip decompression via `Compression` framework. We cap the
    /// output at 1 MB because we only need the head for the NAME line.
    private static func decompressGzip(url: URL) -> Data? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        // The `Compression` framework expects raw deflate ('zlib' mode also
        // expects a 2-byte header) — gzip files have a 10-byte header. We
        // strip the header bytes and any trailing CRC/length and feed deflate.
        guard raw.count > 10 else { return nil }
        // gzip magic: 1f 8b
        guard raw[0] == 0x1f, raw[1] == 0x8b else { return nil }
        let flg = raw[3]
        var offset = 10
        if (flg & 0x04) != 0, raw.count > offset + 2 { // FEXTRA
            let xlen = Int(raw[offset]) | (Int(raw[offset+1]) << 8)
            offset += 2 + xlen
        }
        if (flg & 0x08) != 0 { // FNAME — null-terminated string
            while offset < raw.count, raw[offset] != 0 { offset += 1 }
            offset += 1
        }
        if (flg & 0x10) != 0 { // FCOMMENT — null-terminated string
            while offset < raw.count, raw[offset] != 0 { offset += 1 }
            offset += 1
        }
        if (flg & 0x02) != 0 { offset += 2 } // FHCRC
        guard offset < raw.count else { return nil }
        // The deflate stream sits between `offset` and the last 8 bytes
        // (CRC32 + ISIZE).
        let deflateEnd = raw.count - 8
        guard deflateEnd > offset else { return nil }

        let cap = 1024 * 1024
        var output = Data(count: cap)
        let written = output.withUnsafeMutableBytes { dst -> Int in
            raw.withUnsafeBytes { src -> Int in
                let srcBase = src.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                let dstBase = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
                return compression_decode_buffer(
                    dstBase, cap,
                    srcBase, deflateEnd - offset,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        output.removeSubrange(written..<output.count)
        return output
    }
}
