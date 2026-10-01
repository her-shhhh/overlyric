import Foundation
import Testing
@testable import OverlyricCore

@Suite struct LRCParserTests {
    @Test func parsesCentisecondsAndMilliseconds() throws {
        let lrc = "[00:12.34]First line\n[01:02.345]Second line\n[00:00.00]\n"
        let l = try #require(LRCParser.parse(lrc))
        #expect(l.lines.count == 3)
        #expect(l.lines[0].time == 0 && l.lines[0].text == "")
        #expect(abs(l.lines[1].time - 12.34) < 0.0001 && l.lines[1].text == "First line")
        #expect(abs(l.lines[2].time - 62.345) < 0.0001 && l.lines[2].text == "Second line")
    }

    @Test func handlesMultipleTagsColonFractionCRLFAndMetadata() throws {
        let lrc = "[ar:Someone]\r\n[ti:Song]\r\n[00:10.00][00:30.00]Chorus\r\n[00:20:50]Verse  \r\n"
        let l = try #require(LRCParser.parse(lrc))
        #expect(l.lines.map(\.text) == ["Chorus", "Verse", "Chorus"])
        #expect(l.lines.map(\.time) == [10, 20.5, 30])
    }

    @Test func stripsEnhancedWordTags() throws {
        let l = try #require(LRCParser.parse("[00:01.00]<00:01.00>Hello <00:01.50>world"))
        #expect(l.lines[0].text == "Hello world")
    }

    @Test func appliesOffset() throws {
        let l = try #require(LRCParser.parse("[offset:+500]\n[00:10.00]A\n[00:00.20]B"))
        #expect(l.lines.map(\.time) == [0, 9.5])
    }

    @Test func returnsNilWhenNoTimedLines() {
        #expect(LRCParser.parse("just plain\nlyrics here") == nil)
        #expect(LRCParser.parse("") == nil)
    }

    @Test func mergesEqualTimestampsInFileOrder() throws {
        let l = try #require(LRCParser.parse("[00:05.00]one\n[00:05.00]two\n[00:09.00]three"))
        #expect(l.lines.map(\.text) == ["one\ntwo", "three"])
        #expect(l.window(at: 5) == .init(current: 0, next: 1))
    }

    @Test func toleratesBOMAndSpacesBetweenTags() throws {
        let l = try #require(LRCParser.parse("\u{FEFF}[00:10.00] [00:30.00]Chorus\n[100:00.00]late"))
        #expect(l.lines.map(\.time) == [10, 30, 6000])
        #expect(l.lines.map(\.text) == ["Chorus", "Chorus", "late"])
    }
}

@Suite struct SyncedLyricsTests {
    let lyrics = SyncedLyrics(lines: [
        LyricLine(time: 5, text: "A"), LyricLine(time: 10, text: "B"), LyricLine(time: 15, text: "C"),
    ])

    @Test func beforeFirstLine() {
        #expect(lyrics.window(at: 0) == .init(current: nil, next: 0))
        #expect(lyrics.window(at: 4.999) == .init(current: nil, next: 0))
    }

    @Test func exactBoundaryAndBetween() {
        #expect(lyrics.window(at: 5) == .init(current: 0, next: 1))
        #expect(lyrics.window(at: 7.5) == .init(current: 0, next: 1))
        #expect(lyrics.window(at: 10) == .init(current: 1, next: 2))
        #expect(lyrics.window(at: 14.99) == .init(current: 1, next: 2))
    }

    @Test func afterLastLine() {
        #expect(lyrics.window(at: 15) == .init(current: 2, next: nil))
        #expect(lyrics.window(at: 999) == .init(current: 2, next: nil))
    }

    @Test func emptyLyrics() {
        #expect(SyncedLyrics(lines: []).window(at: 3) == .init(current: nil, next: nil))
    }

    @Test func textLookup() {
        #expect(lyrics.text(at: 1) == "B")
        #expect(lyrics.text(at: nil) == nil)
        #expect(lyrics.text(at: 7) == nil)
    }
}

@Suite struct PlaybackSnapshotTests {
    @Test func extrapolatesWhilePlaying() {
        let t0 = Date()
        let s = PlaybackSnapshot(track: nil, isPlaying: true, position: 30, timestamp: t0)
        #expect(abs(s.position(at: t0.addingTimeInterval(2.5)) - 32.5) < 0.0001)
    }

    @Test func freezesWhilePaused() {
        let t0 = Date()
        let s = PlaybackSnapshot(track: nil, isPlaying: false, position: 30, timestamp: t0)
        #expect(s.position(at: t0.addingTimeInterval(60)) == 30)
    }

    @Test func trackKinds() {
        #expect(SpotifyTrack(id: "spotify:ad:123", name: "Ad", artist: "", album: "", duration: 30).isSong == false)
        #expect(SpotifyTrack(id: "spotify:episode:1", name: "Pod", artist: "", album: "", duration: 30).isSong == false)
        #expect(SpotifyTrack(id: "spotify:track:1", name: "Song", artist: "X", album: "", duration: 30).isSong == true)
    }
}
