import Foundation
import AppKit

public nonisolated enum AppBundleInspector {
    /// Best-effort PNG render of a bundle's primary icon. Returns the bytes
    /// for storage as a blob.
    ///
    /// We use a TIFF round-trip rather than NSGraphicsContext drawing. The
    /// drawing path needs main-thread serialization to be safe; the TIFF
    /// approach (`NSWorkspace` → `NSImage.tiffRepresentation` →
    /// `NSBitmapImageRep` → PNG) only touches data buffers and works fine
    /// from many concurrent worker tasks. The output is the icon's natural
    /// representation rather than a forced resize, so users see crisp icons.
    public static func renderIconPNG(forBundle url: URL) -> Data? {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
