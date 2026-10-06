import Foundation

/// A song (or ad / episode) from whichever player is being followed.
public struct Track: Equatable, Sendable {
    public let id: String
    public let name: String
    public let artist: String
    public let album: String
    /// Seconds.
    public let duration: TimeInterval

    public init(id: String, name: String, artist: String, album: String, duration: TimeInterval) {
        self.id = id; self.name = name; self.artist = artist; self.album = album; self.duration = duration
    }

    public var isAd: Bool { id.hasPrefix("spotify:ad") }
    public var isEpisode: Bool { id.hasPrefix("spotify:episode") }
    /// Anything we can show lyrics for.
    public var isSong: Bool { !isAd && !isEpisode && !name.isEmpty }
}

public struct PlaybackSnapshot: Equatable, Sendable {
    public var track: Track?
    public var isPlaying: Bool
    /// Position reported by the player at `timestamp`, seconds.
    public var position: TimeInterval
    public var timestamp: Date

    public init(track: Track?, isPlaying: Bool, position: TimeInterval, timestamp: Date) {
        self.track = track; self.isPlaying = isPlaying; self.position = position; self.timestamp = timestamp
    }

    public static let empty = PlaybackSnapshot(track: nil, isPlaying: false, position: 0, timestamp: .distantPast)

    /// Extrapolated playback position at `now` (frozen while paused).
    public func position(at now: Date) -> TimeInterval {
        guard isPlaying else { return position }
        return max(0, position + now.timeIntervalSince(timestamp))
    }
}
