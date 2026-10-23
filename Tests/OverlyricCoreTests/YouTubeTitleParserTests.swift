import Foundation
import Testing
@testable import OverlyricCore

@Suite struct YouTubeTitleParserTests {
    @Test func cleansTheUsualNoise() {
        #expect(YouTubeTitleParser.cleanTitle("Coldplay - Yellow (Official Video)") == "Coldplay - Yellow")
        #expect(YouTubeTitleParser.cleanTitle("(2) Dua Lipa - Levitating [Official Music Video] - YouTube") == "Dua Lipa - Levitating")
        #expect(YouTubeTitleParser.cleanTitle("Blinding Lights - The Weeknd (Lyrics) HD") == "Blinding Lights - The Weeknd")
        #expect(YouTubeTitleParser.cleanTitle("Yellow - Official Video - Lyrics") == "Yellow")
        #expect(YouTubeTitleParser.cleanTitle("Pasoori | Coke Studio | Season 14 #cokestudio") == "Pasoori | Coke Studio | Season 14")
        // Parentheticals that are part of the title stay.
        #expect(YouTubeTitleParser.cleanTitle("(I Can't Get No) Satisfaction") == "(I Can't Get No) Satisfaction")
    }

    @Test func cleansChannels() {
        #expect(YouTubeTitleParser.cleanChannel("Coldplay - Topic") == "Coldplay")
        #expect(YouTubeTitleParser.cleanChannel("ColdplayVEVO") == "Coldplay")
        #expect(YouTubeTitleParser.cleanChannel("Taylor Swift Official") == "Taylor Swift")
        #expect(YouTubeTitleParser.cleanChannel("Arctic Monkeys") == "Arctic Monkeys")
    }

    @Test func primaryArtistSplitsCollaborations() {
        #expect(YouTubeTitleParser.primaryArtist("Ali Sethi x Shae Gill") == "Ali Sethi")
        #expect(YouTubeTitleParser.primaryArtist("Lil Nas X ft. Jack Harlow") == "Lil Nas X")
        #expect(YouTubeTitleParser.primaryArtist("Dua Lipa, Elton John") == "Dua Lipa")
        #expect(YouTubeTitleParser.primaryArtist("Simon & Garfunkel") == "Simon & Garfunkel")
        #expect(YouTubeTitleParser.primaryArtist("Coldplay") == "Coldplay")
    }

    @Test func artistDashSongIsTheFirstGuess() {
        let g = YouTubeTitleParser.guesses(.init(title: "Coldplay - Yellow (Official Video)", channel: "ColdplayVEVO"))
        #expect(g.first == TrackGuess(name: "Yellow", artist: "Coldplay"))
        #expect(g.contains(TrackGuess(name: "Coldplay", artist: "Yellow")))
        #expect(g.last == TrackGuess(name: "Coldplay Yellow", artist: ""))
    }

    @Test func channelStandsInWhenThereIsNoSeparator() {
        let g = YouTubeTitleParser.guesses(.init(title: "Yellow", channel: "Coldplay - Topic"))
        #expect(g.first == TrackGuess(name: "Yellow", artist: "Coldplay"))
    }

    @Test func pipesDropJunkSegments() {
        let g = YouTubeTitleParser.guesses(.init(title: "Pasoori | Coke Studio | Season 14 | Ali Sethi x Shae Gill", channel: "Coke Studio"))
        #expect(g.first == TrackGuess(name: "Pasoori", artist: "Ali Sethi x Shae Gill"))
        #expect(g.contains(TrackGuess(name: "Ali Sethi x Shae Gill", artist: "Pasoori")))
    }

    @Test func splitsOnEverySeparatorAndIgnoresLabelChannels() {
        let g = YouTubeTitleParser.guesses(.init(
            title: "BEQADRA (Official Video): FAHEEM ABDULLAH | SHANYA KASHYAP | HYDER DAR | NAJIULLAH", channel: "T-Series"))
        #expect(g.first == TrackGuess(name: "BEQADRA", artist: "FAHEEM ABDULLAH"))
        #expect(!g.contains { $0.artist == "T-Series" })
        #expect(YouTubeTitleParser.cleanChannel("Zee Music Company") == "")
        #expect(YouTubeTitleParser.cleanChannel("Coldplay") == "Coldplay")
    }

    @Test func collaborationOrChannelMarksTheArtistHalf() {
        #expect(YouTubeTitleParser.guesses(.init(title: "Industry Baby - Lil Nas X ft. Jack Harlow", channel: "x")).first
                == TrackGuess(name: "Industry Baby", artist: "Lil Nas X ft. Jack Harlow"))
        #expect(YouTubeTitleParser.guesses(.init(title: "Taylor Swift - Anti-Hero (Official Music Video)", channel: "Taylor Swift")).first
                == TrackGuess(name: "Anti-Hero", artist: "Taylor Swift"))
        #expect(YouTubeTitleParser.guesses(.init(title: "Anti-Hero | Taylor Swift", channel: "Someone")).first
                == TrackGuess(name: "Anti-Hero", artist: "Taylor Swift"))
    }

    @Test func quotedSongTitle() {
        let g = YouTubeTitleParser.guesses(.init(title: "Arctic Monkeys \"Do I Wanna Know?\" (Official Video)", channel: "Official Arctic Monkeys"))
        #expect(g.first == TrackGuess(name: "Do I Wanna Know?", artist: "Arctic Monkeys"))
    }

    @Test func musicCardComesFirst() {
        let g = YouTubeTitleParser.guesses(.init(title: "my summer edit 2024", channel: "someone", cardSong: "Levitating", cardArtist: "Dua Lipa"))
        #expect(g.first == TrackGuess(name: "Levitating", artist: "Dua Lipa"))
    }

    @Test func musicSiteMetadataIsTrusted() {
        let g = YouTubeTitleParser.guesses(.init(title: "Levitating", channel: "Dua Lipa", isMusicSite: true))
        #expect(g.first == TrackGuess(name: "Levitating", artist: "Dua Lipa"))
    }

    @Test func trackGuessesDedupeAndLongVideosAreNotSongs() {
        let t = SpotifyTrack(id: "youtube:abc", name: "Yellow", artist: "Coldplay", album: "", duration: 266,
                             alternates: [TrackGuess(name: "yellow", artist: "coldplay"), TrackGuess(name: "Coldplay", artist: "Yellow")])
        #expect(t.guesses.count == 2)
        #expect(t.isSong && t.isFromYouTube)
        #expect(!SpotifyTrack(id: "youtube:x", name: "Lofi mix", artist: "", album: "", duration: 3600).isSong)
        #expect(!SpotifyTrack(id: "youtube:ad:x", name: "Buy this", artist: "", album: "", duration: 20).isSong)
    }
}
