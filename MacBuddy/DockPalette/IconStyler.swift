import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies the chosen palette style to an icon bitmap off the main actor.
nonisolated enum IconStyler {
    private static let context = CIContext()

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
        case .ink:
            return inkImage(for: input)
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

    /// Pure two-tone: every pixel becomes either #FEFEFE or #030303 — no
    /// gradient. Threshold on luminance, remap the binary output to the two
    /// hex values, then restore the original alpha channel.
    private static func inkImage(for input: CIImage) -> CIImage {
        let gray = CIFilter.colorControls()
        gray.inputImage = input
        gray.saturation = 0
        gray.brightness = 0
        gray.contrast = 1

        let threshold = CIFilter.colorThreshold()
        threshold.inputImage = gray.outputImage ?? input
        threshold.threshold = 0.5

        let light = 0xFE / 255.0
        let dark = 0x03 / 255.0
        let scale = light - dark
        let levels = CIFilter.colorMatrix()
        levels.inputImage = threshold.outputImage ?? input
        levels.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        levels.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
        levels.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
        levels.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        levels.biasVector = CIVector(x: dark, y: dark, z: dark, w: 0)

        let masked = CIFilter.sourceInCompositing()
        masked.inputImage = levels.outputImage ?? input
        masked.backgroundImage = input
        return masked.outputImage ?? input
    }

    private static func blended(original: CIImage, filtered: CIImage, intensity: Double) -> CIImage {
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = original
        filter.targetImage = filtered
        filter.time = Float(intensity)
        return filter.outputImage ?? filtered
    }
}
