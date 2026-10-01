import AppKit
import OverlyricCore

/// Tracks what Spotify is playing. Two sources:
///  - push: the `com.spotify.client.PlaybackStateChanged` distributed notification (no permission needed;
///    fires on play/pause/track change, NOT on seek, and carries position + track metadata);
///  - poll: ScriptingBridge reads (one-time Automation permission) for the initial state, seek detection
///    and drift correction. Light polls (state + position, ~16 ms) run every 2 s while playing; a full
///    poll (with track) runs at start, when a light poll disagrees with our state, and every 10th light poll.
@MainActor
final class SpotifyMonitor {
    nonisolated static let bundleID = "com.spotify.client"
    private static let notificationName = Notification.Name("com.spotify.client.PlaybackStateChanged")

    enum Automation: Equatable { case unknown, granted, denied, unavailable(String) }

    private(set) var snapshot = PlaybackSnapshot.empty
    private(set) var automation: Automation = .unknown
    var onChange: (() -> Void)?

    private let scripter = SpotifyScripter()
    private var pollTimer: Timer?
    private var active = true
    private var pollInFlight = false
    private var fullPending = false
    private var deniedAt: Date?
    private var lightPollsSinceFull = 0
    private var lastPushAt = Date.distantPast
    private var observersInstalled = false

    private var runningSpotify: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
    }
    var isSpotifyRunning: Bool { runningSpotify != nil }

    func start() {
        guard !observersInstalled else { return }
        observersInstalled = true
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playbackChanged(_:)), name: Self.notificationName, object: nil,
            suspensionBehavior: .deliverImmediately)
        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        wc.addObserver(self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        pollNow(full: true)
        reschedule()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        observersInstalled = false
    }

    /// Slows polling right down while the overlay is hidden.
    func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        reschedule()
        if active { pollNow(full: true) }
    }

    /// Asks Spotify for the current track's artwork URL (nil if unavailable or a different track is now playing).
    func fetchArtworkURL(for track: SpotifyTrack, completion: @escaping (URL?) -> Void) {
        guard let spotify = runningSpotify, automation != .denied else { completion(nil); return }
        scripter.readArtwork(pid: spotify.processIdentifier) { result in
            guard let result, result.id == track.id || track.id.isEmpty else { completion(nil); return }
            completion(result.url)
        }
    }

    /// Encore: play the given track again from the top.
    func restart(trackID: String) {
        guard let spotify = runningSpotify, automation == .granted else { return }
        scripter.restart(trackID: trackID, pid: spotify.processIdentifier)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.pollNow(full: true) }
        }
    }

    // MARK: Push

    @objc private func playbackChanged(_ note: Notification) {
        guard let info = note.userInfo else { return }
        let state = (info["Player State"] as? String ?? "").lowercased()
        let position = Self.number(info["Playback Position"]) ?? 0
        let id = info["Track ID"] as? String ?? ""
        let name = info["Name"] as? String ?? ""
        var track: SpotifyTrack?
        if state != "stopped", !(id.isEmpty && name.isEmpty) {
            track = SpotifyTrack(
                id: id, name: name,
                artist: info["Artist"] as? String ?? "",
                album: info["Album"] as? String ?? "",
                duration: (Self.number(info["Duration"]) ?? 0) / 1000)
        }
        let now = Date()
        lastPushAt = now
        Log.spotify.notice("notification: \(state, privacy: .public) pos=\(position, privacy: .public) track=\(track?.name ?? "-", privacy: .public) / \(track?.artist ?? "-", privacy: .public)")
        apply(track: track, playing: state == "playing", position: position, at: now, fromPoll: false)
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Self.bundleID else { return }
        clear()
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Self.bundleID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.pollNow(full: true) }
        }
    }

    // MARK: Poll

    private func reschedule() {
        pollTimer?.invalidate()
        let interval: TimeInterval = active ? (snapshot.isPlaying ? 2 : 5) : 20
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollNow(full: false) }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func pollNow(full requestedFull: Bool) {
        guard let spotify = runningSpotify else {
            if snapshot != .empty { clear() }
            return
        }
        if automation == .denied, let deniedAt, Date().timeIntervalSince(deniedAt) < 60 { return }
        guard !pollInFlight else {
            fullPending = fullPending || requestedFull     // honoured right after the in-flight read
            return
        }
        let full = requestedFull || fullPending || snapshot.track == nil || lightPollsSinceFull >= 10 || automation != .granted
        fullPending = false
        lightPollsSinceFull = full ? 0 : lightPollsSinceFull + 1
        pollInFlight = true

        scripter.read(full: full, pid: spotify.processIdentifier) { [weak self] result in
            guard let self else { return }
            self.pollInFlight = false
            switch result {
            case .success(let reading):
                self.handle(reading, full: full)
            case .failure(.denied):
                Log.spotify.error("automation DENIED (-1743); notification-only mode")
                self.automation = .denied
                self.deniedAt = Date()
                self.onChange?()
            case .failure(.notRunning):
                Log.spotify.notice("poll: Spotify not running")
                self.clear()
            case .failure(.other(let msg)):
                Log.spotify.error("poll failed: \(msg, privacy: .public)")
                self.automation = .unavailable(msg)
                self.onChange?()
            }
            if self.fullPending { self.pollNow(full: true) }   // one deferred full read, never a loop
        }
    }

    private func handle(_ r: SpotifyScripter.Reading, full: Bool) {
        let wasGranted = automation == .granted
        automation = .granted
        if !wasGranted {
            Log.spotify.notice("automation granted; first read ok")
            onChange?()
        }
        // A notification that arrived while this read was in flight is newer than the read.
        guard r.sampledAt >= lastPushAt else { return }
        let playing = r.state == .playing
        if r.state == .stopped {
            apply(track: nil, playing: false, position: 0, at: r.sampledAt, fromPoll: true)
        } else if let track = r.track {
            apply(track: track, playing: playing, position: r.position, at: r.sampledAt, fromPoll: true)
        } else if full {
            Log.spotify.notice("full poll returned no track; waiting for next tick")
        } else if let current = snapshot.track {
            // Light poll: escalate ONCE to a full read if anything suggests we missed a track change.
            let expected = snapshot.position(at: r.sampledAt)
            let jumpedBack = r.position + 2 < expected
            let pastEnd = current.duration > 0 && r.position > current.duration + 1
            if playing != snapshot.isPlaying || jumpedBack || pastEnd {
                pollNow(full: true)
            } else {
                apply(track: current, playing: playing, position: r.position, at: r.sampledAt, fromPoll: true)
            }
        }
    }

    private func apply(track: SpotifyTrack?, playing: Bool, position: TimeInterval, at sampledAt: Date, fromPoll: Bool) {
        var s = snapshot
        let trackChanged = s.track != track
        let playChanged = s.isPlaying != playing
        let drift = abs(s.position(at: sampledAt) - position)
        // A poll that agrees with our extrapolation is noise; keep the smooth clock.
        if fromPoll, !trackChanged, !playChanged, drift < 0.4 { return }
        s.track = track
        s.isPlaying = playing
        s.position = position
        s.timestamp = sampledAt
        snapshot = s
        if trackChanged || playChanged {
            Log.spotify.notice("state: \(playing ? "playing" : "paused", privacy: .public) \(track?.name ?? "-", privacy: .public) @\(position, privacy: .public) (poll=\(fromPoll, privacy: .public))")
            reschedule()
        } else {
            Log.spotify.notice("resync: Δ=\(String(format: "%.2f", drift), privacy: .public)s → @\(String(format: "%.2f", position), privacy: .public) (poll=\(fromPoll, privacy: .public))")
        }
        onChange?()
    }

    private func clear() {
        let had = snapshot != .empty
        snapshot = .empty
        lightPollsSinceFull = 0
        reschedule()
        if had { onChange?() }
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}
