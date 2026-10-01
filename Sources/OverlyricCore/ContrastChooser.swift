import Foundation

/// An sRGB colour with components in 0…1.
public struct RGB: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    public static let white = RGB(r: 1, g: 1, b: 1)
    public static let black = RGB(r: 0, g: 0, b: 0)

    /// Largest per-channel difference.
    public func distance(to o: RGB) -> Double {
        max(abs(r - o.r), abs(g - o.g), abs(b - o.b))
    }
}

/// Picks a lyric colour that reads clearly on a given background: the complementary hue, pushed to the
/// opposite luminance (near-white tint on dark backgrounds, deep tone on light ones), neutral when the
/// background is grey. Polarity has hysteresis so a background hovering around mid-grey does not flicker.
public enum ContrastChooser {
    /// WCAG relative luminance (0 = black, 1 = white) of an sRGB colour.
    public static func luminance(_ c: RGB) -> Double {
        0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    public static func linear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// WCAG contrast ratio between two colours (1…21).
    public static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Below this background luminance the text goes light; above `darkTextAbove` it goes dark.
    /// In between the previous polarity is kept (hysteresis). Black and white have equal WCAG contrast
    /// at L ≈ 0.18, so the band is centred there.
    public static let lightTextBelow = 0.14
    public static let darkTextAbove = 0.23

    public struct Choice: Equatable, Sendable {
        public let color: RGB
        public let lightText: Bool
    }

    /// - Parameters:
    ///   - background: mean colour of what is behind the lyrics.
    ///   - luminance: mean per-pixel relative luminance of the same region (more faithful than the
    ///     luminance of the mean colour on busy backgrounds). Pass nil to derive it from `background`.
    ///   - previousLightText: the polarity currently shown, for hysteresis.
    public static func choose(background: RGB, luminance L: Double? = nil, previousLightText: Bool?) -> Choice {
        let lum = L ?? luminance(background)
        let lightText: Bool
        if lum < lightTextBelow {
            lightText = true
        } else if lum > darkTextAbove {
            lightText = false
        } else {
            lightText = previousLightText ?? (lum < 0.18)
        }

        let (h, s, _) = hsb(background)
        let neutral = s < 0.18          // grey-ish background → plain white / near-black
        let hue = (h + 0.5).truncatingRemainder(dividingBy: 1)
        var color: RGB
        if lightText {
            // A pale tint of the complementary hue, kept at ≥ 85 % of white's luminance so contrast
            // stays close to pure white (blue-ish tints are perceptually dark, so saturation is reduced
            // until the tint is bright enough).
            color = .white
            if !neutral {
                var sat = min(0.32, s * 0.5)
                color = rgb(h: hue, s: sat, b: 1)
                while luminance(color) < 0.85, sat > 0.02 {
                    sat -= 0.04
                    color = rgb(h: hue, s: sat, b: 1)
                }
            }
        } else {
            // A deep tone of the complementary hue: coloured enough to feel "opposite", dark enough
            // (luminance ≤ 0.8 %) to keep contrast close to pure black.
            color = RGB(r: 0.08, g: 0.08, b: 0.09)
            if !neutral {
                var bright = 0.2
                color = rgb(h: hue, s: min(0.7, s * 0.8), b: bright)
                while luminance(color) > 0.008, bright > 0.06 {
                    bright -= 0.02
                    color = rgb(h: hue, s: min(0.7, s * 0.8), b: bright)
                }
            }
        }
        return Choice(color: color, lightText: lightText)
    }

    // MARK: HSB

    /// Hue 0…1, saturation 0…1, brightness 0…1.
    public static func hsb(_ c: RGB) -> (h: Double, s: Double, b: Double) {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
        let d = mx - mn
        let s = mx == 0 ? 0 : d / mx
        var h = 0.0
        if d > 0 {
            if mx == c.r { h = ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == c.g { h = (c.b - c.r) / d + 2 }
            else { h = (c.r - c.g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, s, mx)
    }

    public static func rgb(h: Double, s: Double, b: Double) -> RGB {
        let i = floor(h * 6)
        let f = h * 6 - i
        let p = b * (1 - s), q = b * (1 - f * s), t = b * (1 - (1 - f) * s)
        switch Int(i) % 6 {
        case 0: return RGB(r: b, g: t, b: p)
        case 1: return RGB(r: q, g: b, b: p)
        case 2: return RGB(r: p, g: b, b: t)
        case 3: return RGB(r: p, g: q, b: b)
        case 4: return RGB(r: t, g: p, b: b)
        default: return RGB(r: b, g: p, b: q)
        }
    }
}
