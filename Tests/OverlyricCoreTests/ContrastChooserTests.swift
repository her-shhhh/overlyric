import Foundation
import Testing
@testable import OverlyricCore

@Suite struct ContrastChooserTests {
    func c(_ hex: UInt32) -> RGB {
        RGB(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }

    @Test func luminanceAnchors() {
        #expect(abs(ContrastChooser.luminance(.white) - 1) < 1e-9)
        #expect(ContrastChooser.luminance(.black) == 0)
        #expect(abs(ContrastChooser.luminance(c(0x767676)) - 0.18) < 0.01)
    }

    @Test func hsbRoundTrip() {
        for hex: UInt32 in [0x1DB954, 0x0A1A3A, 0xFFFFFF, 0x123456, 0xFF0000, 0x00FF00, 0x0000FF, 0x808080] {
            let x = c(hex)
            let (h, s, b) = ContrastChooser.hsb(x)
            let back = ContrastChooser.rgb(h: h, s: s, b: b)
            #expect(x.distance(to: back) < 0.003, "round trip \(String(hex, radix: 16))")
        }
    }

    @Test func darkBackgroundGetsLightReadableText() {
        let bg = c(0x0A1A3A) // navy
        let ch = ContrastChooser.choose(background: bg, previousLightText: nil)
        #expect(ch.lightText)
        #expect(ContrastChooser.contrastRatio(ch.color, bg) > 10)
        // Complement of blue is warm: more red than blue.
        #expect(ch.color.r > ch.color.b)
    }

    @Test func lightBackgroundGetsDarkReadableText() {
        let bg = c(0xFFFFFF)
        let ch = ContrastChooser.choose(background: bg, previousLightText: nil)
        #expect(!ch.lightText)
        #expect(ContrastChooser.contrastRatio(ch.color, bg) > 12)
    }

    @Test func saturatedBackgroundsStayCloseToBestAchievableContrast() {
        // Spotify green, a pastel, a saturated red, a sky blue, a yellow, two blues/purples, navy, teal.
        for hex: UInt32 in [0x1DB954, 0xF7C8D0, 0xE0302A, 0x8ED6FF, 0xFFE566, 0x3B82F6, 0x7C3AED, 0x0A1A3A, 0x0F766E] {
            let bg = c(hex)
            let ch = ContrastChooser.choose(background: bg, previousLightText: nil)
            let best = max(ContrastChooser.contrastRatio(.white, bg), ContrastChooser.contrastRatio(.black, bg))
            let got = ContrastChooser.contrastRatio(ch.color, bg)
            #expect(got >= 0.8 * best, "contrast on \(String(hex, radix: 16)): \(got) vs best \(best)")
            #expect(got >= 3.5, "absolute floor on \(String(hex, radix: 16)): \(got)")
        }
    }

    @Test func greyBackgroundsAreNeutral() {
        let dark = ContrastChooser.choose(background: c(0x202020), previousLightText: nil)
        #expect(dark.color == .white)
        let light = ContrastChooser.choose(background: c(0xEEEEEE), previousLightText: nil)
        #expect(light.color.r < 0.1 && abs(light.color.r - light.color.g) < 0.02)
    }

    @Test func hysteresisHoldsPolarityInTheBand() {
        let mid = ContrastChooser.rgb(h: 0, s: 0, b: 0.49) // L ≈ 0.20, inside the 0.14…0.23 band
        #expect(ContrastChooser.choose(background: mid, previousLightText: true).lightText == true)
        #expect(ContrastChooser.choose(background: mid, previousLightText: false).lightText == false)
        // Outside the band the previous polarity is overridden.
        #expect(ContrastChooser.choose(background: c(0x101010), previousLightText: false).lightText == true)
        #expect(ContrastChooser.choose(background: c(0xF0F0F0), previousLightText: true).lightText == false)
    }

    @Test func explicitLuminanceDrivesPolarity() {
        // Mean colour looks mid, but per-pixel luminance says the region is mostly dark.
        let ch = ContrastChooser.choose(background: c(0x767676), luminance: 0.05, previousLightText: nil)
        #expect(ch.lightText)
    }
}
