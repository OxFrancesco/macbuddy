import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// PNG encode/decode for icon bitmaps via ImageIO — no AppKit, so it's safe
/// off the main actor, and it decodes straight to CGImage without an
/// intermediate NSImage re-render.
nonisolated enum IconPNG {
    static func data(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Writes atomically so a crash mid-write never leaves a truncated PNG
    /// behind for the next launch to choke on.
    @discardableResult
    static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let data = data(from: image) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Decodes a stored icon. `maxPixelSize` downsamples at decode time
    /// (thumbnails), which is far cheaper than decoding full-size and
    /// re-rendering.
    static func image(contentsOf url: URL, maxPixelSize: Int? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let maxPixelSize else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
