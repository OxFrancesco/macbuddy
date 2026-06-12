import SwiftUI

nonisolated struct TintColor: Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ color: Color) {
        if let rgb = NSColor(color).usingColorSpace(.sRGB) {
            red = rgb.redComponent
            green = rgb.greenComponent
            blue = rgb.blueComponent
        } else {
            red = 0.35
            green = 0.55
            blue = 1.0
        }
    }
}
