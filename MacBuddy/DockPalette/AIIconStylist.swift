import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Restyles an app icon with an image-edit model: crops the icon artwork out
/// of its transparent margins, sends it to fal.ai with the user's style
/// prompt, then masks the result back onto a standard macOS squircle canvas.
nonisolated enum AIIconStylist {
    static let canvasSize = 1024
    /// Apple icon grid: squircle content is ~80.5% of the canvas, corner
    /// radius ~22.5% of the content size (continuous-corner approximation).
    private static let contentFraction = 0.805
    private static let cornerFraction = 0.225

    @concurrent
    static func restyle(
        source: IconBitmap,
        appName: String,
        stylePrompt: String,
        strength: Double,
        apiKey: String,
        modelId: String
    ) async throws -> IconBitmap {
        let profile = FalModelProfile(modelId: modelId)
        let cropped = contentCropped(source.image)
        // Multimodal editors read alpha PNGs directly; opaque-only models
        // need the artwork flattened onto a contrasting backdrop first.
        let prepared = profile.acceptsAlphaInput
            ? cropped
            : flattenedAdaptive(cropped, size: canvasSize)
        guard let prepared, let pngData = pngData(from: prepared) else {
            throw FalClient.FalError(message: "Couldn't prepare the icon for editing.")
        }
        var generated = try await FalClient.editImage(
            pngData: pngData,
            prompt: prompt(for: stylePrompt, appName: appName, profile: profile),
            strength: strength,
            apiKey: apiKey,
            modelId: profile.modelId
        )
        try Task.checkCancellation()
        // fal's wrappers return opaque PNGs (even a painted checkerboard
        // "transparency"), so cut the backdrop off for real alpha. If the
        // cut fails, composedIcon's corner extraction still handles it.
        let outputHasTransparency = hasMeaningfulTransparency(generated)
        if profile.shouldAttemptBackgroundRemoval(outputHasMeaningfulTransparency: outputHasTransparency),
           let generatedPNG = self.pngData(from: generated),
           let cut = try? await FalClient.removeBackground(pngData: generatedPNG, apiKey: apiKey),
           profile.acceptsBackgroundRemovalResult(
               hasMeaningfulTransparency: hasMeaningfulTransparency(cut),
               opaqueCoverage: opaqueCoverage(cut)
           ) {
            // The coverage gate rejects over-aggressive cuts that hollow the
            // icon out — extraction on the uncut image handles those instead.
            generated = cut
        }
        try Task.checkCancellation()
        guard let composed = composedIcon(from: generated, canvas: canvasSize) else {
            throw FalClient.FalError(message: "Couldn't compose the generated icon.")
        }
        return IconBitmap(image: composed)
    }

    private static func prompt(for style: String, appName: String, profile: FalModelProfile) -> String {
        var prompt = "Restyle this macOS app icon of the app “\(appName)”: \(style). "
            + "Reimagine the icon artwork in that style while keeping its shape, "
            + "silhouette and composition clearly recognizable. A single centered "
            + "app icon, crisp and detailed, no text, no watermark."
        if profile.asksForTransparentOutput {
            prompt += " Keep the background fully transparent and keep the icon's "
                + "rounded-square proportions."
        }
        return prompt
    }

    // MARK: - Geometry

    /// Crops the icon to the square around its opaque artwork, dropping the
    /// transparent margins (and any baked drop shadow) around the squircle.
    private static func contentCropped(_ image: CGImage) -> CGImage {
        let size = 512
        guard let ctx = rgbaContext(width: size, height: size) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = ctx.data else { return image }
        let px = data.assumingMemoryBound(to: UInt8.self)

        var minX = size, minY = size, maxX = -1, maxY = -1
        for y in 0..<size {
            for x in 0..<size where px[(y * size + x) * 4 + 3] >= 251 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX > minX + 32, maxY > minY + 32 else { return image }

        // Expand to a centered square and map back to source pixels.
        let scaleToSource = Double(image.width) / Double(size)
        let side = max(maxX - minX + 1, maxY - minY + 1)
        let cx = Double(minX + maxX) / 2, cy = Double(minY + maxY) / 2
        let half = Double(side) / 2
        let rect = CGRect(
            x: max(0, (cx - half) * scaleToSource),
            y: max(0, (cy - half) * scaleToSource),
            width: min(Double(image.width), Double(side) * scaleToSource),
            height: min(Double(image.height), Double(side) * scaleToSource)
        )
        return image.cropping(to: rect) ?? image
    }

    /// Draws the cropped artwork full-bleed onto an opaque backdrop chosen to
    /// contrast with the artwork's brightness — opaque-only models can't read
    /// alpha, and white-on-white (or dark-on-dark) erases the icon.
    private static func flattenedAdaptive(_ image: CGImage, size: Int) -> CGImage? {
        guard let ctx = rgbaContext(width: size, height: size) else { return nil }
        let backdrop: CGColor = if alphaWeightedLuminance(of: image) > 0.7 {
            CGColor(srgbRed: 43 / 255, green: 43 / 255, blue: 48 / 255, alpha: 1)
        } else {
            CGColor(srgbRed: 237 / 255, green: 237 / 255, blue: 237 / 255, alpha: 1)
        }
        ctx.setFillColor(backdrop)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()
    }

    /// Mean luminance of the artwork weighted by alpha, so thin line-art
    /// glyphs still register as light or dark.
    private static func alphaWeightedLuminance(of image: CGImage) -> Double {
        let probe = 64
        guard let ctx = rgbaContext(width: probe, height: probe) else { return 0.5 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: probe, height: probe))
        guard let data = ctx.data else { return 0.5 }
        let px = data.assumingMemoryBound(to: UInt8.self)
        var luminance = 0.0
        var weight = 0.0
        for i in 0..<(probe * probe) {
            // Premultiplied: r/g/b are already scaled by alpha.
            let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
            luminance += 0.2126 * r + 0.7152 * g + 0.0722 * b
            weight += Double(px[i * 4 + 3])
        }
        return weight > 0 ? luminance / weight : 0.5
    }

    /// Turns whatever the model returned into a dock-ready icon. Models don't
    /// respect framing — they shrink the artwork, add margins, or draw their
    /// own tile — so locate the artwork instead of trusting the frame:
    /// transparent outputs get an alpha-bbox crop and keep their own shape;
    /// opaque outputs get a corner-estimated backdrop removed, then the
    /// artwork bbox masked onto the standard squircle.
    private static func composedIcon(from image: CGImage, canvas: Int) -> CGImage? {
        let probe = 256
        guard let px = rgbaSamples(image, probe: probe) else {
            return composedOnSquircle(image, canvas: canvas)
        }

        if hasMeaningfulTransparency(image) {
            // Real transparency — crop to the artwork and keep its own shape.
            let cropped = contentCropped(image)
            return composedCentered(cropped, canvas: canvas)
        }

        // Opaque: estimate the backdrop from corner patches, find the artwork
        // as the density-filtered region that differs from it.
        let inset = Int(Double(probe) * 0.04), patch = Int(Double(probe) * 0.08)
        var rs: [Double] = [], gs: [Double] = [], bs: [Double] = []
        for (ox, oy) in [(inset, inset), (probe - inset - patch, inset),
                         (inset, probe - inset - patch), (probe - inset - patch, probe - inset - patch)] {
            for y in oy..<(oy + patch) {
                for x in ox..<(ox + patch) {
                    let i = (y * probe + x) * 4
                    rs.append(Double(px[i]))
                    gs.append(Double(px[i + 1]))
                    bs.append(Double(px[i + 2]))
                }
            }
        }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        let bgR = median(rs), bgG = median(gs), bgB = median(bs)

        var rowHits = [Int](repeating: 0, count: probe)
        var colHits = [Int](repeating: 0, count: probe)
        var foreground = 0
        for y in 0..<probe {
            for x in 0..<probe {
                let i = (y * probe + x) * 4
                let dr = Double(px[i]) - bgR, dg = Double(px[i + 1]) - bgG, db = Double(px[i + 2]) - bgB
                if (dr * dr + dg * dg + db * db).squareRoot() > 32 {
                    rowHits[y] += 1
                    colHits[x] += 1
                    foreground += 1
                }
            }
        }
        let coverage = Double(foreground) / Double(probe * probe)
        if coverage > 0.88 {
            return composedOnSquircle(image, canvas: canvas)
        }
        let dense = Int(Double(probe) * 0.05)
        let rows = rowHits.indices.filter { rowHits[$0] > dense }
        let cols = colHits.indices.filter { colHits[$0] > dense }
        guard let r0 = rows.first, let r1 = rows.last,
              let c0 = cols.first, let c1 = cols.last,
              rows.count > probe / 4, cols.count > probe / 4 else {
            return composedOnSquircle(image, canvas: canvas)
        }
        let scale = Double(image.width) / Double(probe)
        var side = Double(max(r1 - r0, c1 - c0)) * 1.02 * scale
        side = min(side, Double(image.width))
        let cx = Double(c0 + c1) / 2 * scale, cy = Double(r0 + r1) / 2 * scale
        let x = max(0, min(Double(image.width) - side, cx - side / 2))
        let y = max(0, min(Double(image.height) - side, cy - side / 2))
        let artwork = image.cropping(to: CGRect(x: x, y: y, width: side, height: side)) ?? image
        return composedOnSquircle(artwork, canvas: canvas)
    }

    /// Centers transparent artwork on the canvas at standard content scale,
    /// preserving the artwork's own silhouette.
    private static func composedCentered(_ image: CGImage, canvas: Int) -> CGImage? {
        guard let ctx = rgbaContext(width: canvas, height: canvas) else { return nil }
        let content = Double(canvas) * contentFraction
        let origin = (Double(canvas) - content) / 2
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: origin, y: origin, width: content, height: content))
        return ctx.makeImage()
    }

    /// Fraction of pixels that are essentially opaque.
    private static func opaqueCoverage(_ image: CGImage) -> Double {
        let probe = 256
        guard let px = rgbaSamples(image, probe: probe) else { return 0 }
        var opaque = 0
        for i in 0..<(probe * probe) where px[i * 4 + 3] >= 200 {
            opaque += 1
        }
        return Double(opaque) / Double(probe * probe)
    }

    /// True when the image carries usable alpha: all four corners transparent
    /// and at least 5% of pixels transparent overall.
    private static func hasMeaningfulTransparency(_ image: CGImage) -> Bool {
        let probe = 256
        guard let px = rgbaSamples(image, probe: probe) else { return false }
        let corners = [0, probe - 1, probe * (probe - 1), probe * probe - 1]
        guard corners.allSatisfy({ px[$0 * 4 + 3] < 30 }) else { return false }
        var transparent = 0
        for i in 0..<(probe * probe) where px[i * 4 + 3] < 30 {
            transparent += 1
        }
        return Double(transparent) / Double(probe * probe) > 0.05
    }

    /// Downsamples to a small RGBA buffer for pixel analysis.
    private static func rgbaSamples(_ image: CGImage, probe: Int) -> [UInt8]? {
        guard let ctx = rgbaContext(width: probe, height: probe) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: probe, height: probe))
        guard let data = ctx.data else { return nil }
        let buffer = UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self),
            count: probe * probe * 4
        )
        return Array(buffer)
    }

    /// Masks the generated square onto the standard icon squircle with
    /// transparent margins, so it sits in the Dock like a real icon.
    private static func composedOnSquircle(_ image: CGImage, canvas: Int) -> CGImage? {
        guard let ctx = rgbaContext(width: canvas, height: canvas) else { return nil }
        let content = Double(canvas) * contentFraction
        let origin = (Double(canvas) - content) / 2
        let rect = CGRect(x: origin, y: origin, width: content, height: content)
        let radius = content * cornerFraction
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    // MARK: - Bitmap plumbing

    private static func rgbaContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
