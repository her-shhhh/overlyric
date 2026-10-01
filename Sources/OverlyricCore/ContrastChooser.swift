import Foundation

/// An sRGB colour with components in 0…1.
public struct RGB: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    public init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }

    public static let white = RGB(r: 1, g: 1, b: 1)
    public static let black = RGB(r: 0, g: 0, b: 0)

    /// Largest per-channel difference.
    public func distance(to o: RGB) -> Double {
        max(abs(r - o.r), abs(g - o.g), abs(b - o.b))
    }
}

/// Picks a lyric colour that reads clearly on a given background. Colourful by design: a random pick
/// from a curated palette of vivid colours (bright ones for dark backgrounds, deep ones for light
/// backgrounds), restricted to those that clear a contrast threshold against the background and do not
/// clash with its hue. The current colour is kept while it stays readable, so nothing flickers.
public enum ContrastChooser {
    // MARK: Colour science

    /// WCAG relative luminance (0 = black, 1 = white) of an sRGB colour.
    public static func luminance(_ c: RGB) -> Double {
        0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    public static func linear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// WCAG contrast ratio between two colours (1…21).
    public static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        contrastRatio(luminance(a), luminance(b))
    }

    public static func contrastRatio(_ la: Double, _ lb: Double) -> Double {
        (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    // MARK: Generated colours

    public static let neutralLight = RGB.white
    public static let neutralDark = RGB(hex: 0x111318)

    /// Generates a vivid colour of the given polarity from the whole spectrum: random hue, random vivid
    /// saturation, brightness solved so the colour's luminance lands in the readable band
    /// (bright: L ≥ 0.45; deep: L ≤ 0.07). Returns nil if this hue can't be both vivid and readable.
    public static func generate<R: RandomNumberGenerator>(bright: Bool, hue: Double, using rng: inout R) -> RGB? {
        if bright {
            // Start vivid, then desaturate only as much as the hue needs (blues/reds are perceptually dark).
            let targetL = Double.random(in: 0.45...0.75, using: &rng)
            var sat = Double.random(in: 0.5...0.85, using: &rng)
            var c = rgb(h: hue, s: sat, b: 1)
            while luminance(c) < targetL, sat > 0.28 {
                sat -= 0.03
                c = rgb(h: hue, s: sat, b: 1)
            }
            return luminance(c) >= 0.45 ? c : nil
        } else {
            // Rich, saturated, dark: pick saturation, then binary-search brightness for the target luminance.
            let targetL = Double.random(in: 0.025...0.065, using: &rng)
            let sat = Double.random(in: 0.6...0.95, using: &rng)
            var lo = 0.0, hi = 1.0
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                if luminance(rgb(h: hue, s: sat, b: mid)) > targetL { hi = mid } else { lo = mid }
            }
            guard lo >= 0.22 else { return nil }          // would read as black, not as a colour
            return rgb(h: hue, s: sat, b: lo)
        }
    }

    // MARK: Choice

    /// Below this background luminance the text goes light; above `darkTextAbove` it goes dark; in
    /// between the previous polarity is kept (hysteresis). Black and white contrast equally at L≈0.18.
    public static let lightTextBelow = 0.16
    public static let darkTextAbove = 0.20
    /// Preferred and minimum contrast ratios (WCAG AAA / AA for body text).
    public static let preferredContrast = 7.0
    public static let minimumContrast = 4.5

    public struct Choice: Equatable, Sendable {
        public let color: RGB
        public let lightText: Bool
        public init(color: RGB, lightText: Bool) { self.color = color; self.lightText = lightText }
    }

    /// - Parameters:
    ///   - background: mean colour of what is behind the lyrics (used for hue-clash avoidance).
    ///   - luminance: the luminance the text mostly sits on (median per-pixel). Defaults to the mean colour's.
    ///   - previous: what is shown now. It is kept while it remains readable on the new background.
    ///   - forceNew: pick a different colour even if the previous one is still fine (e.g. new song).
    public static func choose<R: RandomNumberGenerator>(
        background: RGB, luminance L: Double? = nil, previous: Choice?, forceNew: Bool = false, using rng: inout R
    ) -> Choice {
        let bgL = L ?? luminance(background)
        let lightText: Bool
        if bgL < lightTextBelow {
            lightText = true
        } else if bgL > darkTextAbove {
            lightText = false
        } else {
            lightText = previous?.lightText ?? (bgL < 0.18)
        }

        let (bgH, bgS, _) = hsb(background)
        func clashes(_ c: RGB) -> Bool {
            guard bgS > 0.35 else { return false }
            let d = abs(hsb(c).h - bgH)
            return min(d, 1 - d) < 0.08
        }
        func readable(_ c: RGB, _ threshold: Double) -> Bool {
            contrastRatio(luminance(c), bgL) >= threshold && !clashes(c)
        }

        // Keep the current colour while it is still the right polarity and readable.
        if !forceNew, let previous, previous.lightText == lightText, readable(previous.color, minimumContrast) {
            return previous
        }

        // Generate fresh colours from the whole spectrum until one is readable (AAA first, then AA).
        // A new pick is also a clearly different hue from the one it replaces.
        let previousHue = previous.map { hsb($0.color) }
        func farFromPrevious(_ c: RGB) -> Bool {
            guard let p = previousHue, p.s > 0.2 else { return true }
            let d = abs(hsb(c).h - p.h)
            return min(d, 1 - d) >= 0.12
        }
        for threshold in [preferredContrast, minimumContrast] {
            for _ in 0..<64 {
                let hue = Double.random(in: 0..<1, using: &rng)
                guard let c = generate(bright: lightText, hue: hue, using: &rng),
                      readable(c, threshold), farFromPrevious(c) else { continue }
                return Choice(color: c, lightText: lightText)
            }
        }
        // Nothing colourful is readable enough (mid-tone backgrounds): use a neutral of the SAME polarity,
        // so a background hovering around mid-grey cannot make the text flip between white and black.
        if lightText { return Choice(color: neutralLight, lightText: true) }
        let dark = contrastRatio(luminance(neutralDark), bgL) >= minimumContrast ? neutralDark : RGB.black
        return Choice(color: dark, lightText: false)
    }

    /// Convenience using the system random generator.
    public static func choose(background: RGB, luminance L: Double? = nil, previous: Choice?, forceNew: Bool = false) -> Choice {
        var g = SystemRandomNumberGenerator()
        return choose(background: background, luminance: L, previous: previous, forceNew: forceNew, using: &g)
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
