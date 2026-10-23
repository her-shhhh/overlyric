import AppKit
import OverlyricCore

/// What's playing, from whichever player is: the Spotify desktop app or a YouTube tab in a browser.
/// When both play at once the one that started most recently wins; when neither plays, the last one
/// heard from keeps the (paused) lyrics up. Spotify is always watched; YouTube only when switched on.
@MainActor
final class NowPlaying {
    enum Source: Equatable { case spotify, youtube }

    let spotify = SpotifyMonitor()
    let youtube = YouTubeMonitor()
    private(set) var source: Source?
    var onChange: (() -> Void)?

    private var playingSince: [Source: Date] = [:]
    private var wasPlaying: [Source: Bool] = [:]

    init() {
        spotify.onChange = { [weak self] in self?.changed(.spotify) }
        youtube.onChange = { [weak self] in self?.changed(.youtube) }
    }

    var snapshot: PlaybackSnapshot {
        switch source {
        case .spotify: return spotify.snapshot
        case .youtube: return youtube.snapshot
        case nil: return .empty
        }
    }

    /// Starts Spotify. YouTube starts only through `setYouTubeEnabled(true)`.
    func start() { spotify.start() }
    func stop() { spotify.stop(); youtube.stop() }
    func setActive(_ value: Bool) { spotify.setActive(value); youtube.setActive(value) }

    /// The user's YouTube switch: on reads the browsers from now on, off takes those lyrics down and reads nothing.
    func setYouTubeEnabled(_ on: Bool) { youtube.setEnabled(on) }

    /// Encore: the current song again from the top, wherever it plays.
    func restart(trackID: String) {
        if trackID.hasPrefix("youtube:") { youtube.restart(trackID: trackID) } else { spotify.restart(trackID: trackID) }
    }

    func fetchArtworkURL(for track: SpotifyTrack, completion: @escaping (URL?) -> Void) {
        if track.isFromYouTube { youtube.fetchArtworkURL(for: track, completion: completion) }
        else { spotify.fetchArtworkURL(for: track, completion: completion) }
    }

    /// Clicking the lyrics: the player they belong to, in front.
    func openPlayer() {
        switch source {
        case .youtube: youtube.openTab()
        case .spotify, nil: LyricsController.openSpotify()
        }
    }

    /// True when a player is running but macOS hasn't let us read it, and nothing has been heard yet.
    /// A browser only counts while the YouTube switch is on.
    var automationBlocked: Bool {
        guard snapshot.track == nil else { return false }
        return (spotify.isSpotifyRunning && spotify.automation == .denied)
            || (youtube.isEnabled && youtube.isBrowserRunning && youtube.automation == .denied)
    }

    private func changed(_ s: Source) {
        let snap = s == .spotify ? spotify.snapshot : youtube.snapshot
        let playing = snap.isPlaying && snap.track != nil
        if playing, wasPlaying[s] != true { playingSince[s] = Date() }
        wasPlaying[s] = playing
        pick()
        onChange?()
    }

    private func pick() {
        let candidates: [(Source, PlaybackSnapshot)] = [(.spotify, spotify.snapshot), (.youtube, youtube.snapshot)]
        let playing = candidates.filter { $0.1.isPlaying && $0.1.track != nil }
        if let winner = playing.max(by: { (playingSince[$0.0] ?? .distantPast) < (playingSince[$1.0] ?? .distantPast) }) {
            source = winner.0
        } else if let source, candidates.first(where: { $0.0 == source })?.1.track != nil {
            return                                          // paused: stay with it
        } else {
            source = candidates.first(where: { $0.1.track != nil })?.0
        }
    }
}
