import Foundation
import OverlyricCore

/// A player the lyrics follow: Spotify (`SpotifyMonitor`) or whatever macOS shows as Now Playing —
/// YouTube Music, a browser tab, Apple Music… (`NowPlayingMonitor`).
@MainActor
protocol PlaybackSource: AnyObject {
    var snapshot: PlaybackSnapshot { get }
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
    /// Slows polling right down while the overlay is hidden.
    func setActive(_ value: Bool)
    /// The current track's artwork (nil if unavailable or a different track is now playing).
    func fetchArtworkURL(for track: Track, completion: @escaping (URL?) -> Void)
    /// Encore: play the given track again from the top.
    func restart(trackID: String)
    /// Brings the player to the front (clicking the lyrics).
    func open()
}
