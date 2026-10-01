import Foundation
import Testing
@testable import OverlyricCore

@Suite struct LyricsDiskCacheTests {
    func freshCache(_ lifetime: TimeInterval = 3600) -> LyricsDiskCache {
        LyricsDiskCache(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("overlyric-cache-test-\(UUID().uuidString)"), negativeLifetime: lifetime)
    }

    @Test func roundTripsFoundLyrics() {
        let c = freshCache()
        #expect(c.load("spotify:track:abc") == nil)
        c.store(.found("[00:01.00]Hello"), for: "spotify:track:abc")
        #expect(c.load("spotify:track:abc") == .found("[00:01.00]Hello"))
    }

    @Test func notFoundExpires() {
        let c = freshCache(60)
        c.store(.notFound, for: "Song|Artist|200")
        #expect(c.load("Song|Artist|200") == .notFound)
        #expect(c.load("Song|Artist|200", now: Date().addingTimeInterval(120)) == nil)
    }

    @Test func oddKeysAreSafe() {
        let c = freshCache()
        let key = "Teri Yaad / Aditya Rikhari|230 ✨:..//"
        c.store(.found("x"), for: key)
        #expect(c.load(key) == .found("x"))
    }
}
