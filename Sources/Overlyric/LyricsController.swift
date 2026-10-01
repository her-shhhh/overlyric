import AppKit
import QuartzCore
import OverlyricCore

/// Glue: Spotify state → lyrics fetch → playback clock → overlay style.
/// No periodic tick: a one-shot timer is armed for exactly the next line boundary and re-armed on every
/// state change, so nothing runs while paused, hidden or idle. Time-driven styles animate on the GPU.
@MainActor
final class LyricsController {
    let panel = OverlayPanel()
    let monitor = SpotifyMonitor()
    private(set) lazy var sampler = BackgroundSampler(window: panel)
    private(set) lazy var eggs = EasterEggs(view: view)
    private let service = LyricsService()
    private let artwork = ArtworkColorService()
    private var artworkColor: NSColor?
    private var artworkTrackKey: String?
    private let settings = Settings.shared
    private var view: OverlayView { panel.overlayView }

    private enum Phase: Equatable { case none, loading, loaded, notFound, failed }
    private var lyrics: SyncedLyrics?
    private var phase: Phase = .none
    private var currentTrackKey: String?
    private var fetchGeneration = 0
    private var fetchTask: Task<Void, Never>?
    private var failedAt: Date?
    private var retryAttempt = 0
    private var retryTimer: Timer?
    /// Back-off for lookups that failed on the network (seconds after each failure).
    private static let retryDelays: [TimeInterval] = [3, 8, 20, 45, 90]
    private var lineTimer: Timer?
    private var visible = false
    private var lastLineShown: (String, Int?)?
    private var lastPosition: (key: String, position: TimeInterval)?
    /// First launch ever: a short hello is shown until then (or until lyrics take over).
    private var welcomeUntil: Date?

    struct StatusText {
        let title: String
        let detail: String
    }

    func start() {
        view.fontSize = settings.fontSize
        view.style = settings.style
        view.color = settings.color
        view.onResizeEnded = { [weak self] size in self?.settings.fontSize = size }
        view.onClick = { [weak self] in
            guard let self else { return }
            if !self.eggs.consumeClick() { Self.openSpotify() }
        }
        view.onShake = { [weak self] in self?.eggs.shake() }
        eggs.enabled = settings.easterEggs
        eggs.onEncore = { [weak self] in
            guard let self, let id = self.monitor.snapshot.track?.id else { return }
            self.monitor.restart(trackID: id)
        }
        panel.moveTop(to: settings.windowTop)
        panel.ignoresMouseEvents = settings.clickThrough
        sampler.onChoice = { [weak self] choice in
            guard let self, self.settings.colorMode == .autoContrast else { return }
            self.view.setColor(NSColor(srgbRed: choice.color.r, green: choice.color.g, blue: choice.color.b, alpha: 1), animated: true)
        }

        NotificationCenter.default.addObserver(forName: .overlyricSettingsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.moveTop(to: self?.settings.windowTop) }
        }

        monitor.onChange = { [weak self] in self?.playbackChanged() }
        monitor.setActive(settings.enabled)
        monitor.start()
        if Onboarding.takeWelcome() {
            welcomeUntil = Date().addingTimeInterval(9)
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.1) { [weak self] in
                self?.welcomeUntil = nil
                self?.refresh()
            }
        }
        refresh()
    }

    func stop() {
        lineTimer?.invalidate()
        retryTimer?.invalidate()
        fetchTask?.cancel()
        monitor.stop()
    }

    // MARK: Settings

    private func applySettings() {
        if view.fontSize != settings.fontSize { view.fontSize = settings.fontSize }
        if view.style != settings.style { view.style = settings.style }
        eggs.enabled = settings.easterEggs
        panel.ignoresMouseEvents = settings.clickThrough
        monitor.setActive(settings.enabled)
        refresh()
        updateColorSource()
    }

    /// Manual colour, the sampler's pick (auto-contrast), or the artwork theme colour.
    private func updateColorSource() {
        let mode = settings.colorMode
        sampler.setEnabled(mode == .autoContrast && visible)
        sampler.setPeriodic(monitor.snapshot.isPlaying)
        switch mode {
        case .autoContrast:
            if let c = sampler.choice {
                view.setColor(NSColor(srgbRed: c.color.r, green: c.color.g, blue: c.color.b, alpha: 1), animated: false)
            } else {
                view.setColor(settings.color, animated: false)   // until the first sample lands
            }
        case .artwork:
            if let artworkColor, artworkTrackKey == currentTrackKey {
                view.setColor(artworkColor, animated: false)
            } else {
                view.setColor(settings.color, animated: false)
                refreshArtworkColor()
            }
        case .manual:
            view.setColor(settings.color, animated: false)
        }
    }

    private func refreshArtworkColor() {
        guard settings.colorMode == .artwork, let track = monitor.snapshot.track, track.isSong,
              let key = currentTrackKey, artworkTrackKey != key else { return }
        artworkTrackKey = key
        artworkColor = nil
        monitor.fetchArtworkURL(for: track) { [weak self] url in
            guard let self, let url, self.artworkTrackKey == key else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let rgb = await self.artwork.textColor(trackKey: key, artworkURL: url)
                guard self.artworkTrackKey == key, self.settings.colorMode == .artwork else { return }
                let color = rgb.map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1) } ?? self.settings.color
                self.artworkColor = color
                self.view.setColor(color, animated: true)
            }
        }
    }

    // MARK: Playback → lyrics

    private func playbackChanged() {
        let snap = monitor.snapshot
        sampler.setPeriodic(snap.isPlaying)
        let key = snap.track.map(LyricsService.cacheKey(for:))
        let position = snap.position(at: Date())
        if key != currentTrackKey {
            currentTrackKey = key
            lyrics = nil
            lastLineShown = nil
            fetchGeneration += 1
            fetchTask?.cancel()
            retryTimer?.invalidate()
            retryAttempt = 0
            if let t = snap.track, t.isSong, let key {
                phase = .loading
                fetch(t)
                if settings.colorMode == .artwork { refreshArtworkColor() }
                if settings.colorMode == .autoContrast { sampler.reshuffle() }   // a fresh colour per song
                if position < 5 { eggs.trackStarted(id: key) }
            } else {
                phase = .none
            }
        } else if let key, let last = lastPosition, last.key == key,
                  let duration = snap.track?.duration, duration > 30,
                  last.position > duration - 15, position < 5 {
            eggs.trackStarted(id: key)                   // the same song started again (repeat one)
        }
        if let key { lastPosition = (key, position) }
        refresh()
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
                self.phase = found == nil ? .notFound : .loaded
                Log.lyrics.notice("result: \(found.map { "\($0.lines.count) lines" } ?? "not found", privacy: .public) in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)ms")
            case .failure(.cancelled):
                return
            case .failure(let error):
                self.lyrics = nil
                Log.lyrics.error("lookup failed: \(String(describing: error), privacy: .public)")
                if self.retryAttempt < Self.retryDelays.count {
                    // Keep showing ♪ and try again shortly — lrclib is occasionally slow or busy.
                    let delay = Self.retryDelays[self.retryAttempt]
                    self.retryAttempt += 1
                    self.phase = .loading
                    self.retryTimer?.invalidate()
                    self.retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self, generation == self.fetchGeneration, let t = self.monitor.snapshot.track else { return }
                            self.fetch(t)
                        }
                    }
                } else {
                    self.phase = .failed
                    self.failedAt = Date()
                }
            }
            self.refresh()
        }
    }

    // MARK: Timing

    /// Arms one timer for the next moment something changes: the next line, or the encore window.
    private func armTimer() {
        lineTimer?.invalidate()
        lineTimer = nil
        let snap = monitor.snapshot
        guard visible, snap.isPlaying, phase == .loaded, let lyrics, !lyrics.isEmpty else { return }
        let now = Date()
        let position = snap.position(at: now)
        var wake: TimeInterval?
        if let next = lyrics.window(at: position).next { wake = lyrics.lines[next].time - position }
        if let duration = snap.track?.duration, duration > 20 {
            let encore = duration - 7.5 - position
            if encore > 0 { wake = min(wake ?? encore, encore) }
        }
        guard let wake else { return }
        let timer = Timer(fire: now.addingTimeInterval(max(0.005, wake)), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        lineTimer = timer
    }

    private func refresh() {
        defer { armTimer() }
        let snap = monitor.snapshot
        let shouldShow = settings.enabled && (snap.track?.isSong ?? false) && phase != .none
        if !(shouldShow && phase == .loaded), let until = welcomeUntil, Date() < until {
            show()
            view.update(.note(Onboarding.welcomeText))
            return
        }
        guard shouldShow, let key = currentTrackKey else { hide(); return }

        switch phase {
        case .loading:
            view.update(.empty)
        case .notFound:
            view.update(.note("No synced lyrics for this song"))
        case .failed:
            view.update(.note("Lyrics aren't loading right now (no connection to lrclib.net)"))
        case .loaded:
            guard let lyrics else { return }
            let now = Date()
            let position = snap.position(at: now)
            let clock = PlaybackClock(position: position, hostTime: CACurrentMediaTime(), playing: snap.isPlaying)
            let state = LyricsState(id: key, lyrics: lyrics, index: lyrics.currentIndex(at: position), clock: clock)
            show()
            view.update(.lyrics(state))
            if lastLineShown?.0 != key || lastLineShown?.1 != state.index {
                lastLineShown = (key, state.index)
                eggs.lineShown(state)
            }
            if let duration = snap.track?.duration { eggs.considerEncore(state, trackDuration: duration) }
            return
        case .none:
            break
        }
        show()
    }

    private func show() {
        guard !visible else { return }
        visible = true
        panel.orderFrontRegardless()
        if settings.colorMode != .manual { updateColorSource() }
    }

    private func hide() {
        guard visible else { return }
        visible = false
        panel.orderOut(nil)
        view.update(.empty)
        sampler.setEnabled(false)
    }

    // MARK: Spotify

    /// Brings Spotify to the front (launching it if needed), like `open -a Spotify`.
    static func openSpotify() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyMonitor.bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { Log.ui.error("open Spotify failed: \(error.localizedDescription, privacy: .public)") }
        }
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
            switch phase {
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
