import AppKit
import OverlyricCore

/// Tracks what YouTube (or YouTube Music) is playing in a Chromium browser tab. There's no push from a
/// browser, so it polls: every second while a video plays (seeks and pauses show up within that), every
/// few seconds otherwise, hardly at all while the overlay is off. A paused tab only counts if it's the
/// one that was playing — idle YouTube tabs in the background never bring the lyrics up.
@MainActor
final class YouTubeMonitor {
    struct Browser { let bundleID: String; let name: String }
    static let browsers: [Browser] = [
        Browser(bundleID: "com.google.Chrome", name: "Chrome"),
        Browser(bundleID: "com.google.Chrome.beta", name: "Chrome Beta"),
        Browser(bundleID: "com.google.Chrome.canary", name: "Chrome Canary"),
        Browser(bundleID: "com.brave.Browser", name: "Brave"),
        Browser(bundleID: "com.microsoft.edgemac", name: "Edge"),
        Browser(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi"),
        Browser(bundleID: "company.thebrowser.Browser", name: "Arc"),
        Browser(bundleID: "org.chromium.Chromium", name: "Chromium"),
    ]

    enum Automation: Equatable { case unknown, granted, denied, javascriptDisabled, unavailable(String) }

    private(set) var snapshot = PlaybackSnapshot.empty
    private(set) var automation: Automation = .unknown
    /// The browser the current (or last) video came from, for the menu.
    private(set) var browserName: String?
    var onChange: (() -> Void)?

    private let scripter = BrowserScripter()
    private var pollTimer: Timer?
    private var active = true
    private var pollInFlight = false
    private var pollPending = false
    private var deniedAt: Date?
    private var currentTab: BrowserScripter.TabRef?
    /// A track seen once that differs from the current one: it counts when the next poll agrees. YouTube
    /// switches songs in pieces (the URL, the player, the Media Session each at their own moment), so a
    /// poll that lands mid-switch can pair the new video's id with the old song's title and position.
    private var unconfirmed: SpotifyTrack?
    private var artwork: [String: URL] = [:]
    private var observersInstalled = false

    private var runningBrowsers: [(Browser, NSRunningApplication)] {
        Self.browsers.compactMap { b in
            NSRunningApplication.runningApplications(withBundleIdentifier: b.bundleID).first.map { (b, $0) }
        }
    }
    var isBrowserRunning: Bool { !runningBrowsers.isEmpty }

    func start() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        wc.addObserver(self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        pollNow()
        reschedule()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        observersInstalled = false
    }

    /// Slows polling right down while the overlay is hidden.
    func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        reschedule()
        if active { pollNow() }
    }

    /// The video's thumbnail, as YouTube reports it to the system's Now Playing.
    func fetchArtworkURL(for track: SpotifyTrack, completion: @escaping (URL?) -> Void) {
        completion(artwork[track.id])
    }

    /// Encore: play the video again from the top.
    func restart(trackID: String) {
        guard let tab = currentTab, snapshot.track?.id == trackID, automation == .granted else { return }
        scripter.restart(tab)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.pollNow() }
        }
    }

    /// Brings the tab the lyrics belong to in front.
    func openTab() {
        guard let tab = currentTab else { return }
        scripter.activate(tab)
    }

    // MARK: Launch / quit

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let pid = currentTab?.pid, app.processIdentifier == pid else { return }
        clear()
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let id = app.bundleIdentifier, Self.browsers.contains(where: { $0.bundleID == id }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.pollNow() }
        }
    }

    // MARK: Poll

    private func reschedule() {
        pollTimer?.invalidate()
        let interval: TimeInterval
        if !active { interval = 20 }
        else if snapshot.isPlaying { interval = 1 }
        else { interval = 2 }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollNow() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func pollNow() {
        let browsers = runningBrowsers
        guard !browsers.isEmpty else {
            if snapshot != .empty { clear() }
            return
        }
        if automation == .denied, let deniedAt, Date().timeIntervalSince(deniedAt) < 60 { return }
        if automation == .javascriptDisabled, let deniedAt, Date().timeIntervalSince(deniedAt) < 15 { return }
        guard !pollInFlight else { pollPending = true; return }
        pollInFlight = true
        readAll(browsers[...], videos: [], names: [:]) { [weak self] videos, names, failure in
            guard let self else { return }
            self.pollInFlight = false
            if let failure {
                switch failure {
                case .denied:
                    Log.browser.error("automation DENIED (-1743) for the browser")
                    self.automation = .denied
                    self.deniedAt = Date()
                case .javascriptDisabled:
                    if self.automation != .javascriptDisabled {
                        Log.browser.error("the browser's 'Allow JavaScript from Apple Events' is off")
                    }
                    self.automation = .javascriptDisabled
                    self.deniedAt = Date()
                case .notRunning:
                    break
                case .timeout:
                    Log.browser.notice("poll timed out (permission prompt?); trying again")
                case .other(let msg):
                    Log.browser.error("poll failed: \(msg, privacy: .public)")
                    self.automation = .unavailable(msg)
                }
                self.clear()
                self.onChange?()
            } else {
                let wasGranted = self.automation == .granted
                self.automation = .granted
                if !wasGranted { Log.browser.notice("automation granted; first read ok") }
                self.handle(videos, names: names)
                if !wasGranted { self.onChange?() }
            }
            if self.pollPending { self.pollPending = false; self.pollNow() }
        }
    }

    /// Reads the browsers one after another (usually there's one). A failure in one is the failure of the
    /// poll, unless another browser read fine.
    private func readAll(_ rest: ArraySlice<(Browser, NSRunningApplication)>, videos: [BrowserScripter.Video],
                         names: [pid_t: String], completion: @escaping ([BrowserScripter.Video], [pid_t: String], BrowserScripter.Failure?) -> Void) {
        guard let (browser, app) = rest.first else { completion(videos, names, nil); return }
        let pid = app.processIdentifier
        scripter.read(pid: pid) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let reading):
                var names = names
                names[pid] = browser.name
                self.readAll(rest.dropFirst(), videos: videos + reading.videos, names: names, completion: completion)
            case .failure(let failure):
                if rest.count > 1 {
                    self.readAll(rest.dropFirst(), videos: videos, names: names) { v, n, f in completion(v, n, f ?? (v.isEmpty ? failure : nil)) }
                } else {
                    completion(videos, names, videos.isEmpty ? failure : nil)
                }
            }
        }
    }

    private func handle(_ videos: [BrowserScripter.Video], names: [pid_t: String]) {
        let sampledAt = Date()
        let playing = videos.filter { !$0.paused && !$0.ended }
        let chosen: BrowserScripter.Video?
        if let current = currentTab, let same = playing.first(where: { $0.tab.tabID == current.tabID && $0.tab.pid == current.pid }) {
            chosen = same
        } else if let first = playing.first {
            chosen = first
        } else if let current = currentTab, let same = videos.first(where: { $0.tab.tabID == current.tabID && $0.tab.pid == current.pid }) {
            chosen = same                                   // paused: still ours
        } else {
            chosen = nil
        }
        guard let v = chosen, !v.videoID.isEmpty || !v.title.isEmpty else {
            if snapshot != .empty { clear() }
            return
        }
        let track = Self.track(for: v)
        if let current = snapshot.track, current.id != track.id || current.name != track.name {
            if let seen = unconfirmed, seen.id == track.id, seen.name == track.name {
                unconfirmed = nil                           // the same new song twice in a row: real
            } else {
                unconfirmed = track
                Log.browser.notice("new song seen once (\(track.name, privacy: .public)); confirming on the next poll")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    MainActor.assumeIsolated { self?.pollNow() }
                }
                return
            }
        } else {
            unconfirmed = nil
        }
        currentTab = v.tab
        browserName = names[v.tab.pid]
        if let url = v.artworkURL { artwork[track.id] = url }
        apply(track: track, playing: !v.paused && !v.ended, position: v.position, at: sampledAt)
    }

    private static func track(for v: BrowserScripter.Video) -> SpotifyTrack {
        let id = v.isAd ? "youtube:ad:\(v.videoID)" : "youtube:\(v.videoID.isEmpty ? v.title : v.videoID)"
        let guesses = YouTubeTitleParser.guesses(.init(
            title: v.title, channel: v.channel, cardSong: v.cardSong, cardArtist: v.cardArtist, isMusicSite: v.isMusicSite))
        let first = guesses.first ?? TrackGuess(name: YouTubeTitleParser.cleanTitle(v.title), artist: YouTubeTitleParser.cleanChannel(v.channel))
        return SpotifyTrack(
            id: id, name: first.name, artist: first.artist, album: v.isMusicSite ? v.album : "",
            duration: v.duration, alternates: Array(guesses.dropFirst()))
    }

    private func apply(track: SpotifyTrack, playing: Bool, position: TimeInterval, at sampledAt: Date) {
        var s = snapshot
        let trackChanged = s.track != track
        let playChanged = s.isPlaying != playing
        let drift = abs(s.position(at: sampledAt) - position)
        // A poll that agrees with our extrapolation is noise; keep the smooth clock.
        if !trackChanged, !playChanged, drift < 0.4 { return }
        s.track = track
        s.isPlaying = playing
        s.position = position
        s.timestamp = sampledAt
        snapshot = s
        if trackChanged || playChanged {
            Log.browser.notice("state: \(playing ? "playing" : "paused", privacy: .public) \(track.name, privacy: .public) / \(track.artist, privacy: .public) @\(position, privacy: .public) guesses=\(track.guesses.count, privacy: .public)")
            reschedule()
        } else {
            Log.browser.notice("resync: Δ=\(String(format: "%.2f", drift), privacy: .public)s → @\(String(format: "%.2f", position), privacy: .public)")
        }
        onChange?()
    }

    private func clear() {
        let had = snapshot != .empty
        snapshot = .empty
        currentTab = nil
        unconfirmed = nil
        reschedule()
        if had { onChange?() }
    }
}
