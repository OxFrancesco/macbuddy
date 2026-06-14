import AppKit

/// Rasterizes file icons into fixed-size bitmaps.
enum IconRenderer {
    static func iconBitmap(forFile path: String, pixelSize: Int) -> IconBitmap? {
        let workspace = bitmap(from: NSWorkspace.shared.icon(forFile: path), pixelSize: pixelSize)
        // NSWorkspace sometimes hands back the dashed "no icon" placeholder
        // (seen on Tahoe for Notion Calendar, Codex, cmux). The bundle's own
        // .icns is the reliable fallback there.
        if let workspace, !isPlaceholder(workspace.image) {
            return workspace
        }
        if let bundleIcon = bundleIconImage(forAppAt: path),
           let rendered = bitmap(from: bundleIcon, pixelSize: pixelSize),
           !isPlaceholder(rendered.image) {
            return rendered
        }
        return workspace
    }

    /// The generic placeholder is thin dashed line art — almost no opaque
    /// pixels. Real icons have a mostly-opaque tile or glyph.
    private static func isPlaceholder(_ image: CGImage) -> Bool {
        let probe = 64
        guard let ctx = CGContext(
            data: nil,
            width: probe,
            height: probe,
            bitsPerComponent: 8,
            bytesPerRow: probe * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: probe, height: probe))
        guard let data = ctx.data else { return false }
        let px = data.assumingMemoryBound(to: UInt8.self)
        var opaque = 0
        for i in 0..<(probe * probe) where px[i * 4 + 3] >= 250 {
            opaque += 1
        }
        return Double(opaque) / Double(probe * probe) < 0.04
    }

    /// Renders the icns declared in the app's Info.plist (CFBundleIconFile).
    private static func bundleIconImage(forAppAt path: String) -> NSImage? {
        guard let bundle = Bundle(url: URL(filePath: path)) else { return nil }
        var name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String ?? "AppIcon"
        if !name.hasSuffix(".icns") {
            name += ".icns"
        }
        let url = URL(filePath: path)
            .appending(path: "Contents/Resources")
            .appending(path: name)
        return NSImage(contentsOf: url)
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
