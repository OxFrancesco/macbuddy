import AppKit

/// Rasterizes file icons into fixed-size bitmaps.
enum IconRenderer {
    static func iconBitmap(forFile path: String, pixelSize: Int) -> IconBitmap? {
        bitmap(from: NSWorkspace.shared.icon(forFile: path), pixelSize: pixelSize)
    }

    static func bitmap(from image: NSImage, pixelSize: Int) -> IconBitmap? {
        let rect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRep) else { return nil }
        NSGraphicsContext.current = graphicsContext
        graphicsContext.imageInterpolation = .high
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        graphicsContext.flushGraphics()

        guard let cgImage = bitmapRep.cgImage else { return nil }
        return IconBitmap(image: cgImage)
    }
}
