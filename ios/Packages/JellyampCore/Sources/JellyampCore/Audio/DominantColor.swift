import Foundation

/// A plain sRGB colour (components 0…1) — Core cannot use UIKit/SwiftUI types.
public struct RGBColor: Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Hue (0…1), saturation, brightness.
    public var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue
        var hue = 0.0
        if delta > 0 {
            if maxValue == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxValue == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maxValue > 0 ? delta / maxValue : 0, maxValue)
    }

    public init(hue: Double, saturation: Double, brightness: Double) {
        let h = (hue - hue.rounded(.down)) * 6
        let sector = Int(h) % 6
        let f = h - Double(Int(h))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        switch sector {
        case 0: self.init(red: brightness, green: t, blue: p)
        case 1: self.init(red: q, green: brightness, blue: p)
        case 2: self.init(red: p, green: brightness, blue: t)
        case 3: self.init(red: p, green: q, blue: brightness)
        case 4: self.init(red: t, green: p, blue: brightness)
        default: self.init(red: brightness, green: p, blue: q)
        }
    }
}

/// Picks the colour that characterises a piece of album art, for tinting the
/// visualizer.
public enum DominantColor {
    /// - Parameter rgba: tightly packed 8-bit RGBA pixels (a small thumbnail
    ///   is plenty — the app downsamples to 32×32 first).
    /// - Returns: nil for an empty or fully transparent image.
    public static func dominant(rgba: [UInt8]) -> RGBColor? {
        let hueBins = 12
        var weights = [Double](repeating: 0, count: hueBins)
        var sums = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: hueBins)
        var average = (r: 0.0, g: 0.0, b: 0.0)
        var opaquePixels = 0.0

        var offset = 0
        while offset + 3 < rgba.count {
            defer { offset += 4 }
            guard rgba[offset + 3] > 127 else { continue }
            let color = RGBColor(
                red: Double(rgba[offset]) / 255,
                green: Double(rgba[offset + 1]) / 255,
                blue: Double(rgba[offset + 2]) / 255
            )
            average.r += color.red
            average.g += color.green
            average.b += color.blue
            opaquePixels += 1
            let (hue, saturation, brightness) = color.hsb
            // Near-black, near-white and grey pixels carry no usable hue.
            guard saturation > 0.2, brightness > 0.15 else { continue }
            let bin = min(hueBins - 1, Int(hue * Double(hueBins)))
            let weight = saturation * brightness
            weights[bin] += weight
            sums[bin].r += color.red * weight
            sums[bin].g += color.green * weight
            sums[bin].b += color.blue * weight
        }
        guard opaquePixels > 0 else { return nil }
        if let best = weights.indices.max(by: { weights[$0] < weights[$1] }), weights[best] > 0 {
            let total = weights[best]
            return RGBColor(red: sums[best].r / total, green: sums[best].g / total, blue: sums[best].b / total)
        }
        // Monochrome artwork: fall back to its average grey.
        return RGBColor(red: average.r / opaquePixels, green: average.g / opaquePixels, blue: average.b / opaquePixels)
    }

    /// Lifts a colour so it reads on the dark Now Playing background: bright
    /// enough to see, and — when it has a hue at all — saturated enough to
    /// look intentional.
    public static func vivid(_ color: RGBColor, minimumBrightness: Double = 0.8, minimumSaturation: Double = 0.45) -> RGBColor {
        let (hue, saturation, brightness) = color.hsb
        let lifted = max(brightness, minimumBrightness)
        // Greys stay grey: inventing a hue for monochrome art would be wrong.
        let boosted = saturation < 0.08 ? saturation : max(saturation, minimumSaturation)
        return RGBColor(hue: hue, saturation: boosted, brightness: lifted)
    }
}
