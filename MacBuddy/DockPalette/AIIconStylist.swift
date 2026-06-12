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
        stylePrompt: String,
        strength: Double,
        apiKey: String,
        modelId: String
    ) async throws -> IconBitmap {
        let cropped = contentCropped(source.image)
        guard let flattened = flattenedSquare(cropped, size: canvasSize),
              let pngData = pngData(from: flattened) else {
            throw FalClient.FalError(message: "Couldn't prepare the icon for editing.")
        }
        let generated = try await FalClient.editImage(
            pngData: pngData,
            prompt: prompt(for: stylePrompt),
            strength: strength,
            apiKey: apiKey,
            modelId: modelId
        )
        try Task.checkCancellation()
        guard let composed = composedOnSquircle(generated, canvas: canvasSize) else {
            throw FalClient.FalError(message: "Couldn't compose the generated icon.")
        }
        return IconBitmap(image: composed)
    }

    private static func prompt(for style: String) -> String {
        "Restyle this macOS app icon: \(style). Keep the original logo shape, "
            + "silhouette and composition clearly recognizable. A single centered "
            + "app icon filling the frame, clean background, no text, no watermark, "
            + "high quality."
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

    /// Draws the cropped artwork onto an opaque square — image models don't
    /// reliably handle alpha, so the squircle's corner gaps become white.
    private static func flattenedSquare(_ image: CGImage, size: Int) -> CGImage? {
        guard let ctx = rgbaContext(width: size, height: size) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()
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
