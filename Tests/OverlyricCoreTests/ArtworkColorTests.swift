import Foundation
import Testing
@testable import OverlyricCore

@Suite struct ArtworkColorTests {
    func fill(_ c: RGB, _ n: Int) -> [RGB] { Array(repeating: c, count: n) }

    @Test func picksTheDominantVividHue() throws {
        // Mostly dark grey with a red logo and a smaller blue patch.
        let px = fill(RGB(r: 0.1, g: 0.1, b: 0.1), 600) + fill(RGB(r: 0.85, g: 0.1, b: 0.12), 120) + fill(RGB(r: 0.1, g: 0.2, b: 0.9), 60)
        let v = try #require(ArtworkColor.vibrant(px))
        #expect(v.r > 0.7 && v.g < 0.2)
    }

    @Test func ignoresGreyscaleArtwork() {
        let px = fill(RGB(r: 0.3, g: 0.3, b: 0.3), 500) + fill(RGB(r: 0.9, g: 0.9, b: 0.9), 300)
        #expect(ArtworkColor.vibrant(px) == nil)
    }

    @Test func prefersSaturatedOverWashedOut() throws {
        let px = fill(RGB(r: 0.6, g: 0.55, b: 0.5), 300) + fill(RGB(r: 0.1, g: 0.6, b: 0.3), 200)
        let v = try #require(ArtworkColor.vibrant(px))
        #expect(v.g > v.r)
    }

    @Test func textColourIsBrightAndKeepsHue() {
        let t = ArtworkColor.textColor(from: RGB(r: 0.3, g: 0.05, b: 0.05))
        let (h, s, b) = ContrastChooser.hsb(t)
        #expect(abs(h - 0) < 0.02 || abs(h - 1) < 0.02)
        #expect(b > 0.9 && s <= 0.8)
        #expect(ContrastChooser.luminance(t) > 0.25)
    }
}
