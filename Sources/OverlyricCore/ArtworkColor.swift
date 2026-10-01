import Foundation

/// Picks the "theme" colour of album artwork: the most present vivid hue, then brightened so it reads
/// as lyric text. Pure maths over sampled pixels, so it is unit-testable.
public enum ArtworkColor {
    /// The dominant vivid colour, or nil for greyscale / empty artwork.
    public static func vibrant(_ pixels: [RGB]) -> RGB? {
        guard !pixels.isEmpty else { return nil }
        struct Bucket { var count = 0; var r = 0.0; var g = 0.0; var b = 0.0; var sat = 0.0 }
        // 24 hue buckets × 3 brightness bands.
        var buckets = [Bucket](repeating: Bucket(), count: 24 * 3)
        var colourful = 0
        for p in pixels {
            let (h, s, v) = ContrastChooser.hsb(p)
            guard s >= 0.22, v >= 0.22, !(v > 0.96 && s < 0.3) else { continue }
            colourful += 1
            let hi = min(23, Int(h * 24))
            let vi = v < 0.45 ? 0 : (v < 0.75 ? 1 : 2)
            let i = hi * 3 + vi
            buckets[i].count += 1
            buckets[i].r += p.r; buckets[i].g += p.g; buckets[i].b += p.b
            buckets[i].sat += s
        }
        guard colourful >= max(4, pixels.count / 50) else { return nil }   // essentially greyscale
        var best = -1
        var bestScore = 0.0
        for (i, bk) in buckets.enumerated() where bk.count > 0 {
            let avgSat = bk.sat / Double(bk.count)
            let band = i % 3
            let bandWeight = band == 0 ? 0.7 : (band == 1 ? 1.0 : 1.05)
            let score = Double(bk.count) * (0.4 + avgSat) * bandWeight
            if score > bestScore { bestScore = score; best = i }
        }
        guard best >= 0 else { return nil }
        let bk = buckets[best]
        let n = Double(bk.count)
        return RGB(r: bk.r / n, g: bk.g / n, b: bk.b / n)
    }

    /// Turns a theme colour into lyric text: keep the hue, make it bright (luminance ≥ 0.3, i.e. ≥ 7:1 on
    /// black) by lowering saturation as needed — reds/blues are perceptually dark at full saturation.
    public static func textColor(from theme: RGB) -> RGB {
        let (h, s, _) = ContrastChooser.hsb(theme)
        var sat = min(s, 0.8)
        var c = ContrastChooser.rgb(h: h, s: sat, b: 0.97)
        while ContrastChooser.luminance(c) < 0.3, sat > 0.3 {
            sat -= 0.05
            c = ContrastChooser.rgb(h: h, s: sat, b: 0.97)
        }
        return c
    }
}
