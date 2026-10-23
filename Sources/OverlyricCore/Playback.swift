import Foundation

/// One (title, artist) spelling of a track to try at lrclib. Browser sources (a YouTube video title is
/// free text) can't be sure which part is the song and which the artist, so a track carries a few.
public struct TrackGuess: Equatable, Sendable {
    public let name: String
    public let artist: String

    public init(name: String, artist: String) {
        self.name = name; self.artist = artist
    }
}

public struct SpotifyTrack: Equatable, Sendable {
    public let id: String
    public let name: String
    public let artist: String
    public let album: String
    /// Seconds.
    public let duration: TimeInterval
    /// Other (title, artist) spellings to try after `name` / `artist` (see `YouTubeTitleParser`).
    public let alternates: [TrackGuess]

    public init(id: String, name: String, artist: String, album: String, duration: TimeInterval, alternates: [TrackGuess] = []) {
        self.id = id; self.name = name; self.artist = artist; self.album = album; self.duration = duration
        self.alternates = alternates
    }

    public var isAd: Bool { id.hasPrefix("spotify:ad") || id.hasPrefix("youtube:ad") }
    public var isEpisode: Bool { id.hasPrefix("spotify:episode") }
    /// Playing in a browser tab (YouTube / YouTube Music) rather than in Spotify.
    public var isFromYouTube: Bool { id.hasPrefix("youtube:") }
    /// Anything we can show lyrics for. A YouTube video longer than 20 minutes is a mix, an album or a
    /// podcast, not a song: it isn't looked up.
    public var isSong: Bool { !isAd && !isEpisode && !name.isEmpty && !(isFromYouTube && duration > 20 * 60) }

    /// `name`/`artist` first, then the alternates, without repeats.
    public var guesses: [TrackGuess] {
        var seen = Set<String>()
        return ([TrackGuess(name: name, artist: artist)] + alternates).filter {
            !$0.name.isEmpty && seen.insert("\($0.name)|\($0.artist)".lowercased()).inserted
        }
    }
}

public struct PlaybackSnapshot: Equatable, Sendable {
    public var track: SpotifyTrack?
    public var isPlaying: Bool
    /// Position reported by the player at `timestamp`, seconds.
    public var position: TimeInterval
    public var timestamp: Date

    public init(track: SpotifyTrack?, isPlaying: Bool, position: TimeInterval, timestamp: Date) {
        self.track = track; self.isPlaying = isPlaying; self.position = position; self.timestamp = timestamp
    }

    public static let empty = PlaybackSnapshot(track: nil, isPlaying: false, position: 0, timestamp: .distantPast)

    /// Extrapolated playback position at `now` (frozen while paused).
    public func position(at now: Date) -> TimeInterval {
        guard isPlaying else { return position }
        return max(0, position + now.timeIntervalSince(timestamp))
    }
}
