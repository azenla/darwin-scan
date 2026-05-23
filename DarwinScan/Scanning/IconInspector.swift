import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum IconInspector {
    /// Detect an icon-bearing file and produce an IconInfo + a rendered PNG
    /// preview blob. Recognises `.icns`, standalone images, and `Assets.car`.
    static func inspect(url: URL) -> (IconInfo, previewPNG: Data?)? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "icns":
            return inspectICNS(url)
        case "png", "jpg", "jpeg", "tiff", "gif", "heic":
            return inspectImage(url)
        case "car":
            // Asset catalogs are opaque; we record their existence but don't
            // try to extract entries (would need private framework / asset
            // catalog parser).
            return (IconInfo(kind: .carAsset, representations: [], previewBlobRef: nil), nil)
        default:
            if url.lastPathComponent == "Assets.car" {
                return (IconInfo(kind: .carAsset, representations: [], previewBlobRef: nil), nil)
            }
            return nil
        }
    }

    private static func inspectICNS(_ url: URL) -> (IconInfo, Data?) {
        var reps: [String] = []
        if let head = try? FileHandle(forReadingFrom: url).read(upToCount: 64 * 1024) {
            reps = extractICNSElements(from: head)
        }
        let preview = renderImagePNG(url: url, size: 256)
        return (IconInfo(kind: .icns, representations: reps, previewBlobRef: nil), preview)
    }

    private static func inspectImage(_ url: URL) -> (IconInfo, Data?) {
        let preview = renderImagePNG(url: url, size: 256)
        return (IconInfo(kind: .image, representations: [], previewBlobRef: nil), preview)
    }

    /// ICNS format: 'icns' magic, then sequence of (4-byte type, 4-byte length, payload).
    /// The element types ("ic08", "ic09", "icp4", etc.) imply size — we just collect
    /// the type tags so the UI can show "contains ic08, ic09, ic10".
    private static func extractICNSElements(from data: Data) -> [String] {
        guard data.count > 8 else { return [] }
        let magic = String(data: data[0..<4], encoding: .ascii)
        guard magic == "icns" else { return [] }
        var cursor = 8
        var types: [String] = []
        while cursor + 8 <= data.count {
            let typeBytes = data[cursor..<cursor+4]
            guard let type = String(data: typeBytes, encoding: .ascii) else { break }
            let length = data.readUInt32BE(at: cursor + 4)
            if length < 8 || cursor + Int(length) > data.count { break }
            types.append(type)
            cursor += Int(length)
            if types.count > 32 { break } // safety
        }
        return types
    }

    /// Render an image at `size` and return PNG bytes. Uses ImageIO
    /// (`CGImageSource`) which is fully thread-safe — safe to call from many
    /// concurrent worker tasks without any locking.
    static func renderImagePNG(url: URL, size: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: Int(size)
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumb, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
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
        // ICNS is big-endian — most significant byte first.
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
