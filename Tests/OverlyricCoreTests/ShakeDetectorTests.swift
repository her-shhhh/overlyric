import Foundation
import Testing
@testable import OverlyricCore

@Suite struct ShakeDetectorTests {
    /// Feeds a zig-zag of `swings` swings of `amplitude` pt, `perSwing` seconds each, 10 samples per swing.
    func run(swings: Int, amplitude: Double, perSwing: TimeInterval) -> Bool {
        var d = ShakeDetector()
        var t = 0.0
        var fired = false
        var x = 500.0
        for s in 0..<swings {
            let dir: Double = s % 2 == 0 ? 1 : -1
            for _ in 0..<10 {
                x += dir * amplitude / 10
                t += perSwing / 10
                if d.feed(x: x, time: t) { fired = true }
            }
        }
        // One more sample heading back so the last swing is closed.
        if d.feed(x: x - (swings % 2 == 0 ? -20 : 20), time: t + 0.02) { fired = true }
        return fired
    }

    @Test func quickShakeFires() {
        #expect(run(swings: 5, amplitude: 60, perSwing: 0.12))
    }

    @Test func slowSwayDoesNotFire() {
        #expect(!run(swings: 5, amplitude: 60, perSwing: 0.6))
    }

    @Test func tinyJitterDoesNotFire() {
        #expect(!run(swings: 8, amplitude: 12, perSwing: 0.08))
    }

    @Test func plainDragDoesNotFire() {
        var d = ShakeDetector()
        var fired = false
        for i in 0..<100 { if d.feed(x: Double(i) * 4, time: Double(i) * 0.01) { fired = true } }
        #expect(!fired)
    }
}
