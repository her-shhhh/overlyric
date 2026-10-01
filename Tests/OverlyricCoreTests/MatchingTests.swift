import Foundation
import Testing
@testable import OverlyricCore

@Suite struct TrackNameCleanerTests {
    @Test func titleVariantsStripFeatDashAndBrackets() {
        let v = TrackNameCleaner.titleVariants("Industry Baby (feat. Jack Harlow) - Remastered 2021")
        #expect(v.first == "Industry Baby (feat. Jack Harlow) - Remastered 2021")
        #expect(v.contains("Industry Baby - Remastered 2021"))
        #expect(v.contains("Industry Baby"))
    }

    @Test func bracketSuffixOnlyRemovesKnownQualifiers() {
        #expect(TrackNameCleaner.titleVariants("Yellow (Live in Buenos Aires)").last == "Yellow")
        // A parenthetical that is part of the title stays.
        #expect(TrackNameCleaner.titleVariants("(I Can't Get No) Satisfaction").last == "(I Can't Get No) Satisfaction")
    }

    @Test func dedupesAndKeepsOrder() {
        #expect(TrackNameCleaner.titleVariants("Yellow") == ["Yellow"])
    }

    @Test func artistVariants() {
        #expect(TrackNameCleaner.artistVariants("Lil Nas X, Jack Harlow") == ["Lil Nas X, Jack Harlow", "Lil Nas X"])
        #expect(TrackNameCleaner.artistVariants("Coldplay") == ["Coldplay"])
    }

    @Test func primaryArtistSplitsOnSpotifyCommaOnly() {
        #expect(TrackNameCleaner.primaryArtist("Lil Nas X, Jack Harlow & Someone") == "Lil Nas X")
        #expect(TrackNameCleaner.primaryArtist("Simon & Garfunkel") == "Simon & Garfunkel")
        #expect(TrackNameCleaner.primaryArtist("Florence and the Machine") == "Florence and the Machine")
        #expect(TrackNameCleaner.primaryArtist("  Coldplay ") == "Coldplay")
    }
}

@Suite struct LyricsMatcherTests {
    func rec(_ d: Double?, synced: Bool = true) -> LRCLIBRecord {
        LRCLIBRecord(id: Int(d ?? 0), duration: d, syncedLyrics: synced ? "[00:01.00]x" : nil)
    }

    @Test func prefersClosestDurationWithinThreeSeconds() {
        let best = LyricsMatcher.best(from: [rec(260), rec(269), rec(266)], duration: 267)
        #expect(best?.duration == 266)
    }

    @Test func fallsBackToLenientWindows() {
        // Tier 2: within 5 s without a title.
        #expect(LyricsMatcher.best(from: [rec(271)], duration: 267)?.duration == 271)
        // Tier 3: within 15 s only with an exact normalised title match.
        #expect(LyricsMatcher.best(from: [rec(278)], duration: 267) == nil)
        let titled = LRCLIBRecord(id: 9, trackName: "Don’t Stop Me Now (Remastered)", duration: 278, syncedLyrics: "[00:01.00]x")
        #expect(LyricsMatcher.best(from: [titled], duration: 267, title: "dont stop me now - remastered") == titled)
        #expect(LyricsMatcher.best(from: [titled], duration: 267, title: "Don't Stop Me Now") == nil)
        #expect(LyricsMatcher.best(from: [rec(290)], duration: 267, title: "x") == nil)
    }

    @Test func tiesResolveToLowestID() {
        let a = LRCLIBRecord(id: 50, duration: 268, syncedLyrics: "[00:01.00]x")
        let b = LRCLIBRecord(id: 7, duration: 266, syncedLyrics: "[00:01.00]x")
        #expect(LyricsMatcher.best(from: [a, b], duration: 267)?.id == 7)
    }

    @Test func normalizeFoldsLikeLRCLIB() {
        #expect(LyricsMatcher.normalize("Beyoncé – Don’t Stop (Live)") == "beyonce dont stop live")
        #expect(LyricsMatcher.normalize("  ROSALÍA / DESPECHÁ ") == "rosalia despecha")
    }

    @Test func ignoresUnsyncedRecords() {
        #expect(LyricsMatcher.best(from: [rec(267, synced: false)], duration: 267) == nil)
    }

    @Test func noDurationTakesFirstSynced() {
        #expect(LyricsMatcher.best(from: [rec(1, synced: false), rec(2)], duration: nil)?.duration == 2)
    }
}

@Suite struct LRCLIBDecodingTests {
    @Test func decodesRealShape() throws {
        let json = """
        {"id":16233,"name":"Yellow","trackName":"Yellow","artistName":"Coldplay","albumName":"Parachutes","duration":267.0,"instrumental":false,"plainLyrics":"Look at the stars","syncedLyrics":"[00:16.44] Look at the stars\\n[00:19.98] Look how they shine for you"}
        """
        let r = try JSONDecoder().decode(LRCLIBRecord.self, from: Data(json.utf8))
        #expect(r.id == 16233 && r.duration == 267 && r.hasSyncedLyrics)
        let l = try #require(LRCParser.parse(r.syncedLyrics!))
        #expect(l.lines.count == 2 && l.lines[0].text == "Look at the stars")
    }

    @Test func decodesNullLyrics() throws {
        let json = #"{"id":1,"trackName":"x","artistName":"y","albumName":null,"duration":10.5,"instrumental":true,"plainLyrics":null,"syncedLyrics":null}"#
        let r = try JSONDecoder().decode(LRCLIBRecord.self, from: Data(json.utf8))
        #expect(r.hasSyncedLyrics == false && r.instrumental == true)
    }
}
