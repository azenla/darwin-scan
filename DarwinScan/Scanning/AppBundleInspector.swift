import Foundation
import AppKit

nonisolated enum AppBundleInspector {
    /// Best-effort PNG render of the bundle's primary icon. Returns the bytes
    /// for storage as a blob. We use `NSWorkspace.icon(forFile:)` so we get
    /// whatever Launch Services hands us — works for `.icns`, asset catalogs,
    /// and bundles without explicit icon files (system synthesises one).
    static func renderIconPNG(forBundle url: URL, size: CGFloat = 256) -> Data? {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        let target = NSSize(width: size, height: size)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size),
            pixelsHigh: Int(size),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        )
        guard let rep else { return nil }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        return rep.representation(using: .png, properties: [:])
    }
}
