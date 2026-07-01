import AppKit
import UniformTypeIdentifiers

/// Rasterizes file icons into fixed-size bitmaps.
nonisolated enum IconRenderer {
    private static let probe = 64

    static func iconBitmap(forFile path: String, pixelSize: Int) -> IconBitmap? {
        let workspace = bitmap(from: NSWorkspace.shared.icon(forFile: path), pixelSize: pixelSize)
        // NSWorkspace sometimes hands back the dashed "no icon" placeholder
        // or the stock generic app tile (seen on Tahoe for Notion Calendar,
        // Codex, cmux). The bundle's own artwork is the reliable fallback.
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
        guard let px = rgbaSamples(image) else { return false }
        var opaque = 0
        for i in 0..<(probe * probe) where px[i * 4 + 3] >= 250 {
            opaque += 1
        }
        if Double(opaque) / Double(probe * probe) < 0.04 { return true }
        // NSWorkspace can also fail "successfully" by returning the stock
        // generic app tile — treat pixel-identical output as a placeholder.
        guard let generic = genericIconSamples, generic.count == px.count else { return false }
        var diff = 0
        for i in px.indices {
            diff += abs(Int(px[i]) - Int(generic[i]))
        }
        return Double(diff) / Double(px.count) < 6
    }

    /// The stock "generic app" tile downsampled to probe size, rendered once
    /// for pixel comparison in `isPlaceholder`.
    private static let genericIconSamples: [UInt8]? = {
        guard let rendered = bitmap(
            from: NSWorkspace.shared.icon(for: .applicationBundle),
            pixelSize: 256
        ) else { return nil }
        return rgbaSamples(rendered.image)
    }()

    /// The app's own artwork, tried in order of reliability: the icns named
    /// in Info.plist, the asset-catalog icon (modern apps often ship only
    /// Assets.car), then any icns in Resources.
    private static func bundleIconImage(forAppAt path: String) -> NSImage? {
        guard let bundle = Bundle(url: URL(filePath: path)) else { return nil }
        let resources = URL(filePath: path).appending(path: "Contents/Resources")

        if let declared = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            let file = declared.hasSuffix(".icns") ? declared : declared + ".icns"
            if let image = NSImage(contentsOf: resources.appending(path: file)), image.isValid {
                return image
            }
        }
        // CFBundleIconName points into the compiled asset catalog; NSImage
        // resolves it through the bundle's image lookup.
        if let assetName = bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String,
           let image = bundle.image(forResource: assetName), image.isValid {
            return image
        }
        // Last resort: any icns shipped in Resources, largest file first —
        // that's almost always the app icon rather than a document icon.
        let candidates = ((try? FileManager.default.contentsOfDirectory(
            at: resources,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? [])
            .filter { $0.pathExtension.lowercased() == "icns" }
            .sorted { fileSize($0) > fileSize($1) }
        for url in candidates {
            if let image = NSImage(contentsOf: url), image.isValid {
                return image
            }
        }
        return nil
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Downsamples to a small RGBA buffer for pixel analysis.
    private static func rgbaSamples(_ image: CGImage) -> [UInt8]? {
        guard let ctx = CGContext(
            data: nil,
            width: probe,
            height: probe,
            bitsPerComponent: 8,
            bytesPerRow: probe * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: probe, height: probe))
        guard let data = ctx.data else { return nil }
        let buffer = UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self),
            count: probe * probe * 4
        )
        return Array(buffer)
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
