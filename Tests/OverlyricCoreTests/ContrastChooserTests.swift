import Foundation
import Testing
@testable import OverlyricCore

/// Deterministic RNG for tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct ContrastChooserTests {
    let c = RGB.init(hex:)

    @Test func luminanceAnchors() {
        #expect(abs(ContrastChooser.luminance(.white) - 1) < 1e-9)
        #expect(ContrastChooser.luminance(.black) == 0)
        #expect(abs(ContrastChooser.luminance(c(0x767676)) - 0.18) < 0.01)
    }

    @Test func hsbRoundTrip() {
        for hex: UInt32 in [0x1DB954, 0x0A1A3A, 0xFFFFFF, 0x123456, 0xFF0000, 0x00FF00, 0x0000FF, 0x808080] {
            let x = c(hex)
            let (h, s, b) = ContrastChooser.hsb(x)
            #expect(x.distance(to: ContrastChooser.rgb(h: h, s: s, b: b)) < 0.003)
        }
    }

    @Test func generatedColoursHaveTheRightLuminanceAndAreVivid() {
        var rng = SplitMix64(seed: 11)
        var bright = 0, deep = 0
        for i in 0..<400 {
            let hue = Double(i % 100) / 100
            if let c = ContrastChooser.generate(bright: true, hue: hue, using: &rng) {
                bright += 1
                #expect(ContrastChooser.luminance(c) >= 0.45)
                #expect(ContrastChooser.hsb(c).s >= 0.25)
            }
            if let c = ContrastChooser.generate(bright: false, hue: hue, using: &rng) {
                deep += 1
                #expect(ContrastChooser.luminance(c) <= 0.07)
                #expect(ContrastChooser.hsb(c).s >= 0.6)
            }
        }
        // Every part of the wheel is usable most of the time.
        #expect(bright >= 300)
        #expect(deep >= 300)
    }

    @Test func darkBackgroundsGetBrightColours() {
        var rng = SplitMix64(seed: 1)
        for hex: UInt32 in [0x000000, 0x0A1A3A, 0x1E1E1E, 0x202124, 0x2B0A3D] {
            let bg = c(hex)
            let ch = ContrastChooser.choose(background: bg, previous: nil, using: &rng)
            #expect(ch.lightText)
            #expect(ContrastChooser.hsb(ch.color).s >= 0.25, "colourful on \(String(hex, radix: 16))")
            #expect(ContrastChooser.contrastRatio(ch.color, bg) >= ContrastChooser.preferredContrast)
        }
    }

    @Test func lightBackgroundsGetDeepColours() {
        var rng = SplitMix64(seed: 2)
        for hex: UInt32 in [0xFFFFFF, 0xF5F5F7, 0xFFF8E7, 0xE8F0FE] {
            let bg = c(hex)
            let ch = ContrastChooser.choose(background: bg, previous: nil, using: &rng)
            #expect(!ch.lightText)
            #expect(ContrastChooser.hsb(ch.color).s >= 0.6)
            #expect(ContrastChooser.contrastRatio(ch.color, bg) >= ContrastChooser.preferredContrast)
        }
    }

    @Test func everyBackgroundGetsAtLeastAAContrast() {
        // Sweep the whole colour wheel at several saturations/brightnesses plus greys.
        var rng = SplitMix64(seed: 3)
        var bgs: [RGB] = (0...20).map { ContrastChooser.rgb(h: 0, s: 0, b: Double($0) / 20) }
        for h in stride(from: 0.0, to: 1.0, by: 0.02) {
            for s in [0.3, 0.6, 1.0] { for b in [0.15, 0.5, 0.8, 1.0] { bgs.append(ContrastChooser.rgb(h: h, s: s, b: b)) } }
        }
        for bg in bgs {
            let ch = ContrastChooser.choose(background: bg, previous: nil, using: &rng)
            let best = max(ContrastChooser.contrastRatio(.white, bg), ContrastChooser.contrastRatio(.black, bg))
            let got = ContrastChooser.contrastRatio(ch.color, bg)
            // AA, or (on the few mid-tones where nothing reaches AA) the best a neutral can do.
            #expect(got >= min(ContrastChooser.minimumContrast, best * 0.97), "bg \(bg) → \(ch.color) = \(got)")
        }
    }

    @Test func avoidsTheBackgroundsOwnHue() {
        var rng = SplitMix64(seed: 4)
        let darkGreen = c(0x0B3D1E)          // saturated dark green: mint/lime would blend in hue-wise
        for _ in 0..<50 {
            let ch = ContrastChooser.choose(background: darkGreen, previous: nil, forceNew: true, using: &rng)
            let d = abs(ContrastChooser.hsb(ch.color).h - ContrastChooser.hsb(darkGreen).h)
            #expect(min(d, 1 - d) >= 0.08)
        }
    }

    @Test func keepsCurrentColourWhileReadable() {
        var rng = SplitMix64(seed: 5)
        let first = ContrastChooser.choose(background: c(0x101010), previous: nil, using: &rng)
        // A slightly different dark background: same colour stays.
        let second = ContrastChooser.choose(background: c(0x1A1A22), previous: first, using: &rng)
        #expect(second == first)
        // A white background: must change (polarity flips).
        let third = ContrastChooser.choose(background: .white, previous: second, using: &rng)
        #expect(!third.lightText && third != second)
        // And back to a dark window: bright again.
        let fourth = ContrastChooser.choose(background: c(0x1E1E1E), previous: third, using: &rng)
        #expect(fourth.lightText)
    }

    @Test func forceNewPicksAClearlyDifferentHue() {
        var rng = SplitMix64(seed: 6)
        for bg in [RGB.black, RGB.white] {
            var prev = ContrastChooser.choose(background: bg, previous: nil, using: &rng)
            for _ in 0..<40 {
                let next = ContrastChooser.choose(background: bg, previous: prev, forceNew: true, using: &rng)
                let d = abs(ContrastChooser.hsb(next.color).h - ContrastChooser.hsb(prev.color).h)
                #expect(min(d, 1 - d) >= 0.12)
                prev = next
            }
        }
    }

    @Test func picksCoverTheWholeSpectrum() {
        var rng = SplitMix64(seed: 7)
        var colours = Set<String>()
        var hueBuckets = Set<Int>()
        for i in 0..<200 {
            let bg: RGB = i % 2 == 0 ? .black : .white
            let ch = ContrastChooser.choose(background: bg, previous: nil, forceNew: true, using: &rng)
            colours.insert(String(format: "%.3f %.3f %.3f", ch.color.r, ch.color.g, ch.color.b))
            hueBuckets.insert(Int(ContrastChooser.hsb(ch.color).h * 12))
        }
        #expect(colours.count >= 195)        // practically never the same colour twice
        #expect(hueBuckets.count == 12)      // every 30° slice of the colour wheel shows up
    }

    @Test func hysteresisHoldsPolarityInTheBand() {
        var rng = SplitMix64(seed: 8)
        let mid = ContrastChooser.rgb(h: 0, s: 0, b: 0.468)                  // L ≈ 0.185, inside [0.16, 0.20]
        let wasLight = ContrastChooser.Choice(color: .white, lightText: true)
        let wasDark = ContrastChooser.Choice(color: ContrastChooser.neutralDark, lightText: false)
        #expect(ContrastChooser.choose(background: mid, previous: wasLight, using: &rng).lightText == true)
        #expect(ContrastChooser.choose(background: mid, previous: wasDark, using: &rng).lightText == false)
        #expect(ContrastChooser.choose(background: c(0x101010), previous: wasDark, using: &rng).lightText == true)
        #expect(ContrastChooser.choose(background: c(0xF0F0F0), previous: wasLight, using: &rng).lightText == false)
    }

    @Test func medianLuminanceDrivesPolarity() {
        var rng = SplitMix64(seed: 9)
        // Mean colour looks mid-grey, but most of the area is dark.
        let ch = ContrastChooser.choose(background: c(0x767676), luminance: 0.02, previous: nil, using: &rng)
        #expect(ch.lightText)
    }
}
