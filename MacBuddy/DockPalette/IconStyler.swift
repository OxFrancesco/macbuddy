import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies the chosen palette style to an icon bitmap off the main actor.
nonisolated enum IconStyler {
    /// CIContext is documented thread-safe.
    nonisolated(unsafe) private static let context = CIContext()

    @concurrent
    static func render(source: IconBitmap, style: IconStyle, tint: TintColor, intensity: Double) async -> IconBitmap? {
        let input = CIImage(cgImage: source.image)
        let filtered = filteredImage(for: input, style: style, tint: tint)
        let output = if intensity >= 0.999 {
            filtered
        } else {
            blended(original: input, filtered: filtered, intensity: intensity)
        }
        guard let cgImage = context.createCGImage(output.cropped(to: input.extent), from: input.extent) else {
            return nil
        }
        return IconBitmap(image: cgImage)
    }

    private static func filteredImage(for input: CIImage, style: IconStyle, tint: TintColor) -> CIImage {
        switch style {
        case .noir:
            let filter = CIFilter.photoEffectNoir()
            filter.inputImage = input
            return filter.outputImage ?? input
        case .tint:
            let filter = CIFilter.colorMonochrome()
            filter.inputImage = input
            filter.color = CIColor(red: tint.red, green: tint.green, blue: tint.blue)
            filter.intensity = 1
            return filter.outputImage ?? input
        case .sepia:
            let filter = CIFilter.sepiaTone()
            filter.inputImage = input
            filter.intensity = 1
            return filter.outputImage ?? input
        case .pastel:
            let filter = CIFilter.colorControls()
            filter.inputImage = input
            filter.saturation = 0.45
            filter.brightness = 0.08
            filter.contrast = 0.95
            return filter.outputImage ?? input
        }
    }

    private static func blended(original: CIImage, filtered: CIImage, intensity: Double) -> CIImage {
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = original
        filter.targetImage = filtered
        filter.time = Float(intensity)
        return filter.outputImage ?? filtered
    }
}
