import CoreGraphics
import Foundation
import Testing

struct IconPNGTests {
    @Test func roundTripPreservesPixels() throws {
        let image = try #require(Self.makeImage(width: 64, height: 64))
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(IconPNG.write(image, to: url))
        let decoded = try #require(IconPNG.image(contentsOf: url))
        #expect(decoded.width == 64)
        #expect(decoded.height == 64)

        let original = try #require(Self.rgbaSamples(image))
        let restored = try #require(Self.rgbaSamples(decoded))
        #expect(original.count == restored.count)
        // PNG is lossless; allow ±1 for color-management rounding.
        let maxDiff = zip(original, restored)
            .map { abs(Int($0) - Int($1)) }
            .max() ?? .max
        #expect(maxDiff <= 1)
    }

    @Test func decodeDownsamplesToMaxPixelSize() throws {
        let image = try #require(Self.makeImage(width: 256, height: 256))
        let url = Self.temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(IconPNG.write(image, to: url))
        let thumbnail = try #require(IconPNG.image(contentsOf: url, maxPixelSize: 64))
        #expect(max(thumbnail.width, thumbnail.height) == 64)
    }

    @Test func missingFileDecodesToNil() {
        #expect(IconPNG.image(contentsOf: Self.temporaryURL()) == nil)
    }

    // MARK: - Helpers

    private static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "icon-png-tests-\(UUID().uuidString).png")
    }

    private static func makeImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = rgbaContext(width: width, height: height) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        return ctx.makeImage()
    }

    private static func rgbaSamples(_ image: CGImage) -> [UInt8]? {
        guard let ctx = rgbaContext(width: image.width, height: image.height) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { return nil }
        let buffer = UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self),
            count: image.width * image.height * 4
        )
        return Array(buffer)
    }

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
}
