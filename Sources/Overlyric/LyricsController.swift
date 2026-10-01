import AppKit
import OverlyricCore

/// Glue: Spotify state → lyrics fetch → (current, next) line → overlay.
/// No periodic tick: a one-shot timer is armed for exactly the next line boundary and re-armed on every
/// state change, so nothing runs while paused, hidden or idle.
@MainActor
final class LyricsController {
    let panel = OverlayPanel()
    let monitor = SpotifyMonitor()
    private let service = LyricsService()
    private let settings = Settings.shared
    private var view: OverlayView { panel.overlayView }

    private enum LyricsState: Equatable { case none, loading, loaded, notFound, failed }
    private var lyrics: SyncedLyrics?
    private var lyricsState: LyricsState = .none
    private var currentTrackKey: String?
    private var fetchGeneration = 0
    private var fetchTask: Task<Void, Never>?
    private var failedAt: Date?
    private var lineTimer: Timer?
    private var shownWindow: SyncedLyrics.Window?
    private var visible = false

    struct StatusText {
        let title: String
        let detail: String
    }

    func start() {
        view.fontSize = settings.fontSize
        view.color = settings.color
        view.onZoomEnded = { [weak self] size in self?.settings.fontSize = size }
        panel.moveCenter(to: settings.windowCenter)
        panel.ignoresMouseEvents = settings.clickThrough

        NotificationCenter.default.addObserver(forName: .overlyricSettingsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.moveCenter(to: self?.settings.windowCenter) }
        }

        monitor.onChange = { [weak self] in self?.playbackChanged() }
        monitor.setActive(settings.enabled)
        monitor.start()
        refresh(force: true)
    }

    func stop() {
        lineTimer?.invalidate()
        fetchTask?.cancel()
        monitor.stop()
    }

    // MARK: Settings

    private func applySettings() {
        if view.fontSize != settings.fontSize { view.fontSize = settings.fontSize }
        view.color = settings.color
        panel.ignoresMouseEvents = settings.clickThrough
        monitor.setActive(settings.enabled)
        refresh(force: true)
    }

    // MARK: Playback → lyrics

    private func playbackChanged() {
        let snap = monitor.snapshot
        let key = snap.track.map(LyricsService.cacheKey(for:))
        if key != currentTrackKey {
            currentTrackKey = key
            lyrics = nil
            shownWindow = nil
            fetchGeneration += 1
            fetchTask?.cancel()
            if let t = snap.track, t.isSong {
                lyricsState = .loading
                fetch(t)
            } else {
                lyricsState = .none
            }
        } else if lyricsState == .failed, let t = snap.track, t.isSong,
                  Date().timeIntervalSince(failedAt ?? .distantPast) > 15 {
            lyricsState = .loading        // network came back? retry on the next state change
            fetch(t)
        }
        refresh(force: false)
    }

    private func fetch(_ track: SpotifyTrack) {
        let generation = fetchGeneration
        Log.lyrics.notice("fetch: \(track.name, privacy: .public) / \(track.artist, privacy: .public) (\(Int(track.duration), privacy: .public)s)")
        fetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let started = Date()
            let result = await self.service.lyrics(for: track)
            guard !Task.isCancelled, generation == self.fetchGeneration else { return }   // superseded
            switch result {
            case .success(let found):
                self.lyrics = found
                self.lyricsState = found == nil ? .notFound : .loaded
                Log.lyrics.notice("result: \(found.map { "\($0.lines.count) lines" } ?? "not found", privacy: .public) in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)ms")
            case .failure(.cancelled):
                return
            case .failure(let error):
                self.lyrics = nil
                self.lyricsState = .failed
                self.failedAt = Date()
                Log.lyrics.error("lookup failed: \(String(describing: error), privacy: .public)")
            }
            self.shownWindow = nil
            self.refresh(force: true)
        }
    }

    // MARK: Line timing

    /// Arms a one-shot timer for the next line boundary (nothing while paused / no lyrics / hidden).
    private func armLineTimer() {
        lineTimer?.invalidate()
        lineTimer = nil
        let snap = monitor.snapshot
        guard visible, snap.isPlaying, lyricsState == .loaded, let lyrics, !lyrics.isEmpty else { return }
        let now = Date()
        let position = snap.position(at: now)
        guard let nextIndex = lyrics.window(at: position).next else { return }   // past the last line
        let delay = max(0.005, lyrics.lines[nextIndex].time - position)
        let timer = Timer(fire: now.addingTimeInterval(delay), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: false) }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        lineTimer = timer
    }

    private func refresh(force: Bool) {
        defer { armLineTimer() }
        let snap = monitor.snapshot
        let shouldShow = settings.enabled && (snap.track?.isSong ?? false) && lyricsState != .none
        guard shouldShow else { hide(); return }

        switch lyricsState {
        case .loading:
            view.update(.lines(current: nil, next: nil), animated: false)
        case .notFound:
            view.update(.note("No synced lyrics for this song"), animated: false)
        case .failed:
            view.update(.note("Lyrics unavailable — can't reach lrclib.net"), animated: false)
        case .loaded:
            guard let lyrics else { return }
            let window = lyrics.window(at: snap.position(at: Date()))
            if force || window != shownWindow {
                shownWindow = window
                view.update(.lines(current: lyrics.text(at: window.current), next: lyrics.text(at: window.next)),
                            animated: visible)
            }
        case .none:
            break
        }
        show()
    }

    private func show() {
        guard !visible else { return }
        visible = true
        panel.orderFrontRegardless()
    }

    private func hide() {
        guard visible else { return }
        visible = false
        panel.orderOut(nil)
        view.update(.empty, animated: false)
    }

    // MARK: Menu status

    var statusText: StatusText {
        guard monitor.isSpotifyRunning else { return StatusText(title: "Spotify isn't running", detail: "") }
        let snap = monitor.snapshot
        guard let track = snap.track else {
            switch monitor.automation {
            case .denied:
                return StatusText(title: "Nothing playing", detail: "Allow Automation for Spotify, or press play to sync")
            case .unavailable(let msg):
                return StatusText(title: "Nothing playing", detail: "Can't read Spotify (\(msg))")
            default:
                return StatusText(title: "Nothing playing", detail: "")
            }
        }
        let icon = snap.isPlaying ? "▶" : "⏸"
        let title = "\(icon)  \(track.name) — \(track.artist)"
        let detail: String
        if !track.isSong {
            detail = track.isAd ? "Advertisement" : "Podcast episode — no lyrics"
        } else {
            switch lyricsState {
            case .loading: detail = "Finding lyrics…"
            case .loaded: detail = "Synced lyrics ✓"
            case .notFound: detail = "No synced lyrics found"
            case .failed: detail = "Couldn't reach lrclib.net — will retry"
            case .none: detail = ""
            }
        }
        return StatusText(title: title, detail: detail)
    }
}
