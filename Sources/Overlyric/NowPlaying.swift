import AppKit
import OverlyricCore

/// What's playing, from whichever player is: the Spotify desktop app, a YouTube tab read directly, or
/// whatever macOS shows as Now Playing (any browser, YouTube Music, Apple Music…). When several play at
/// once the one that started most recently wins; when none plays, the last one heard from keeps the
/// (paused) lyrics up. Spotify is always watched; the other two only while their switches are on.
/// Spotify also shows up in Now Playing, and so does a browser whose tab is being read directly: those
/// Now Playing entries are skipped, so one song never arrives twice.
@MainActor
final class NowPlaying {
    enum Source: Equatable { case spotify, youtube, system }

    let spotify = SpotifyMonitor()
    let youtube = YouTubeMonitor()
    let system = NowPlayingMonitor()
    private(set) var source: Source?
    var onChange: (() -> Void)?

    private var playingSince: [Source: Date] = [:]
    private var wasPlaying: [Source: Bool] = [:]

    init() {
        spotify.onChange = { [weak self] in self?.changed(.spotify) }
        youtube.onChange = { [weak self] in self?.changed(.youtube) }
        system.onChange = { [weak self] in self?.changed(.system) }
    }

    var snapshot: PlaybackSnapshot {
        switch source {
        case .spotify: return spotify.snapshot
        case .youtube: return youtube.snapshot
        case .system: return systemSnapshot
        case nil: return .empty
        }
    }

    /// Now Playing, minus what another source already covers (Spotify itself; the browser whose YouTube
    /// tab is being read directly).
    private var systemSnapshot: PlaybackSnapshot {
        guard let player = system.playerBundleID else { return system.snapshot }
        if player == SpotifyMonitor.bundleID { return .empty }
        if youtube.snapshot.track != nil, player == youtube.browserBundleID { return .empty }
        return system.snapshot
    }

    /// Starts Spotify. The others start only through their switches.
    func start() { spotify.start() }
    func stop() { spotify.stop(); youtube.stop(); system.stop() }
    func setActive(_ value: Bool) { spotify.setActive(value); youtube.setActive(value); system.setActive(value) }

    /// The user's YouTube switch: on reads the browsers from now on, off takes those lyrics down and reads nothing.
    func setYouTubeEnabled(_ on: Bool) { youtube.setEnabled(on) }

    /// The user's Other Players switch: on follows macOS Now Playing, off takes those lyrics down.
    func setOtherPlayersEnabled(_ on: Bool) {
        if on { system.start() } else { system.stop() }
        pick()
    }

    /// Encore: the current song again from the top, wherever it plays.
    func restart(trackID: String) {
        if trackID.hasPrefix("youtube:") { youtube.restart(trackID: trackID) }
        else if trackID.hasPrefix("web:") || trackID.hasPrefix("nowplaying:") { system.restart(trackID: trackID) }
        else { spotify.restart(trackID: trackID) }
    }

    func fetchArtworkURL(for track: SpotifyTrack, completion: @escaping (URL?) -> Void) {
        if track.isFromYouTube { youtube.fetchArtworkURL(for: track, completion: completion) }
        else if track.id.hasPrefix("web:") || track.id.hasPrefix("nowplaying:") { system.fetchArtworkURL(for: track, completion: completion) }
        else { spotify.fetchArtworkURL(for: track, completion: completion) }
    }

    /// Clicking the lyrics: the player they belong to, in front.
    func openPlayer() {
        switch source {
        case .youtube: youtube.openTab()
        case .system: system.open()
        case .spotify, nil: LyricsController.openSpotify()
        }
    }

    /// The player behind the current lyrics, for the menu ("via Dia").
    var playerName: String? {
        switch source {
        case .system: return system.playerName
        case .youtube: return youtube.browserName
        case .spotify, nil: return nil
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
        let snap: PlaybackSnapshot
        switch s {
        case .spotify: snap = spotify.snapshot
        case .youtube: snap = youtube.snapshot
        case .system: snap = systemSnapshot
        }
        let playing = snap.isPlaying && snap.track != nil
        if playing, wasPlaying[s] != true { playingSince[s] = Date() }
        wasPlaying[s] = playing
        pick()
        onChange?()
    }

    private func pick() {
        let candidates: [(Source, PlaybackSnapshot)] = [(.spotify, spotify.snapshot), (.youtube, youtube.snapshot), (.system, systemSnapshot)]
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
