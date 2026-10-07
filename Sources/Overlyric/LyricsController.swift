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
    private var retryAttempt = 0
    private var retryTimer: Timer?
    /// Back-off for lookups that failed on the network (seconds after each failure; the last one repeats).
    private static let retryDelays: [TimeInterval] = [3, 8, 20, 45, 90]
    private var lineTimer: Timer?
    private var visible = false
    private var lastLineShown: (String, Int?)?
    /// The previous playback state, to tell a song starting over (repeat one) from a seek.
    private var lastPlayback: (key: String, snap: PlaybackSnapshot)?
    /// First launch ever: a short hello is shown until then, in place of the lyrics or, once they start,
    /// above them.
    private var welcomeUntil: Date?
    private var welcomeAboveLyrics = false
    /// First launch ever: the welcome song is due until this time (see `playFirstSongIfDue`).
    private var firstSongDue: Date?
    private var firstSongTries = 0
    private var firstSongNextTry = Date.distantPast
    /// Auto colour before its first look at the screen: plain white, not the manual colour, so turning
    /// Auto on visibly changes something even before (or without) Screen Recording access.
    private static let autoStartColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    struct StatusText {
        let title: String
        let detail: String
    }

    func start() {
        view.fontSize = settings.fontSize
        view.face = settings.font
        view.style = settings.style
        view.onResizeEnded = { [weak self] size in self?.settings.fontSize = size }
        view.onClick = { [weak self] in
            guard let self else { return }
            if !self.eggs.consumeClick() { Self.openSpotify() }
        }
        view.onShake = { [weak self] in self?.eggs.shake() }
        eggs.enabled = settings.easterEggs
        eggs.onEncore = { [weak self] id in self?.monitor.restart(trackID: id) }
        panel.moveTop(to: settings.windowTop)
        view.locked = settings.clickThrough
        sampler.onChoice = { [weak self] choice in
            guard let self, self.settings.colorMode == .autoContrast else { return }
            self.view.setColor(NSColor(srgbRed: choice.color.r, green: choice.color.g, blue: choice.color.b, alpha: 1), animated: true)
        }
        updateColorSource()

        NotificationCenter.default.addObserver(forName: .overlyricSettingsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.moveTop(to: self?.settings.windowTop) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stayOnThisSpace() }
        }

        monitor.onChange = { [weak self] in
            self?.playbackChanged()
            self?.playFirstSongIfDue()
        }
        monitor.setActive(settings.enabled)
        monitor.start()
        if Onboarding.takeWelcome() {
            welcomeUntil = Date().addingTimeInterval(9)
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.1) { [weak self] in
                self?.welcomeUntil = nil
                self?.refresh()
            }
        }
        if Onboarding.takeFirstSong() { startFirstSong() }
        refresh()
    }

    func stop() {
        lineTimer?.invalidate()
        retryTimer?.invalidate()
        fetchTask?.cancel()
        monitor.stop()
    }

    // MARK: Settings

    /// A style or font being tried out from the menu (hovered, not picked yet; never saved). Nil = the saved one.
    private var previewStyle: LyricsStyle?
    private var previewFont: LyricsFont?

    func preview(style: LyricsStyle?) {
        previewStyle = style
        applyLook()
    }

    func preview(font: LyricsFont?) {
        previewFont = font
        applyLook()
    }

    /// The style and font on screen: the one being tried out, else the saved one.
    private func applyLook() {
        let face = previewFont ?? settings.font, style = previewStyle ?? settings.style
        if view.face != face { view.face = face }
        if view.style != style { view.style = style }
    }

    private func applySettings() {
        if view.fontSize != settings.fontSize { view.fontSize = settings.fontSize }
        applyLook()
        eggs.enabled = settings.easterEggs
        view.locked = settings.clickThrough
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
                view.setColor(Self.autoStartColor, animated: false)
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
            guard let self, self.artworkTrackKey == key else { return }
            guard let url else {
                // No artwork (or a different track by now): the default colour, and try again next time.
                self.artworkTrackKey = nil
                if self.settings.colorMode == .artwork { self.view.setColor(self.settings.color, animated: true) }
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let rgb = await self.artwork.textColor(trackKey: key, artworkURL: url)
                guard self.artworkTrackKey == key else { return }
                // Kept even if the mode changed meanwhile, so switching back to Artwork shows it at once.
                let color = rgb.map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1) } ?? self.settings.color
                self.artworkColor = color
                if self.settings.colorMode == .artwork { self.view.setColor(color, animated: true) }
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
            eggs.trackChanged()
            if let t = snap.track, t.isSong, let key {
                phase = .loading
                fetch(t)
                if settings.colorMode == .artwork { refreshArtworkColor() }
                if settings.colorMode == .autoContrast { sampler.reshuffle() }   // a fresh colour per song
                if position < 5 { eggs.trackStarted(id: key) }
            } else {
                phase = .none
            }
        } else if let key, let last = lastPlayback, last.key == key,
                  let duration = snap.track?.duration, duration > 30,
                  last.snap.position(at: Date()) > duration - 15, position < 5 {
            eggs.trackChanged()                          // the same song started again (repeat one)
            eggs.trackStarted(id: key)
        }
        if let key { lastPlayback = (key, snap) }
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
                // lrclib is occasionally slow or busy: keep showing ♪ through the quick retries, then say
                // so and keep trying now and then.
                let quick = self.retryAttempt < Self.retryDelays.count
                self.phase = quick ? .loading : .failed
                let delay = Self.retryDelays[min(self.retryAttempt, Self.retryDelays.count - 1)]
                self.retryAttempt += 1
                self.retryTimer?.invalidate()
                self.retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, generation == self.fetchGeneration, let t = self.monitor.snapshot.track else { return }
                        self.fetch(t)
                    }
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
        let welcoming = welcomeUntil.map { Date() < $0 } ?? false
        if welcoming, !welcomeAboveLyrics, !(shouldShow && phase == .loaded) {
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
            if welcoming, !welcomeAboveLyrics, let until = welcomeUntil {
                welcomeAboveLyrics = true        // the lyrics take over, the hello moves above them
                eggs.showHint(Onboarding.welcomeText, for: until.timeIntervalSinceNow)
            }
            // Only lines actually being sung count (one first shown while paused sparkles once playing).
            if snap.isPlaying, lastLineShown?.0 != key || lastLineShown?.1 != state.index {
                lastLineShown = (key, state.index)
                eggs.lineShown(state)
            }
            if let track = snap.track { eggs.considerEncore(state, trackDuration: track.duration, trackID: track.id) }
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
        stayOnThisSpace()
        view.updateMouseGate()
        if settings.colorMode != .manual { updateColorSource() }
    }

    /// Showing lyrics that macOS has left off the current desktop (see `OverlayPanel.rejoinAllSpaces`).
    private func stayOnThisSpace() {
        guard visible, !panel.isOnActiveSpace else { return }
        Log.ui.notice("lyrics were missing from this Space; putting them back on every Space")
        panel.rejoinAllSpaces()
    }

    private func hide() {
        guard visible else { return }
        visible = false
        panel.orderOut(nil)
        view.update(.empty)
        sampler.setEnabled(false)
    }

    // MARK: First song

    /// The very first launch plays the welcome song once, opening Spotify in the background if needed.
    /// It waits for the Automation permission (which the first read of Spotify asks for) for ten minutes.
    private func startFirstSong() {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyMonitor.bundleID) != nil else { return }
        firstSongDue = Date().addingTimeInterval(600)
        if !monitor.isSpotifyRunning { Self.openSpotify(activate: false) }
        playFirstSongIfDue()
    }

    /// Asks Spotify to play the welcome song, and asks again (a few times, 3 s apart) until it's on: a
    /// Spotify that has only just opened can miss the first request.
    private func playFirstSongIfDue() {
        guard let due = firstSongDue else { return }
        let snap = monitor.snapshot
        if snap.isPlaying, let track = snap.track, Onboarding.isFirstSong(track) {
            Log.spotify.notice("welcome song is playing")
            firstSongDue = nil
            return
        }
        guard Date() < due, firstSongTries < 6 else {
            Log.spotify.notice("welcome song skipped (tries=\(self.firstSongTries, privacy: .public))")
            firstSongDue = nil
            return
        }
        guard monitor.automation == .granted, monitor.isSpotifyRunning, Date() >= firstSongNextTry else { return }
        firstSongTries += 1
        firstSongNextTry = Date().addingTimeInterval(3)
        Log.spotify.notice("playing the welcome song (try \(self.firstSongTries, privacy: .public))")
        monitor.play(uri: Onboarding.firstSongURI)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) { [weak self] in self?.playFirstSongIfDue() }
    }

    // MARK: Spotify

    /// Opens Spotify (launching it if needed), like `open -a Spotify`; in front unless `activate` is false.
    static func openSpotify(activate: Bool = true) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyMonitor.bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
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
