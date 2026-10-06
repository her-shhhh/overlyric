import AppKit
import OverlyricCore

/// Tracks whatever macOS shows as Now Playing (the Control Centre media tile): YouTube Music in a browser
/// tab or as a Safari / Chrome web app, Apple Music, a podcast app, anything that publishes media
/// metadata. Read through the private MediaRemote framework, loaded at runtime:
///  - push: MediaRemote's now-playing notifications (track, play/pause, player changes);
///  - poll: a cheap read every 2 s while playing, for seeks and drift (browsers don't always notify).
/// The position is the player's elapsed time at its own timestamp, extrapolated by its playback rate.
/// No permission prompt. MediaRemote is not public API, so every symbol is optional: if one is missing
/// the monitor reports `.unavailable` instead of crashing.
@MainActor
final class NowPlayingMonitor: PlaybackSource {
    enum Availability: Equatable { case unknown, ok, unavailable }

    private(set) var snapshot = PlaybackSnapshot.empty
    private(set) var availability: Availability = .unknown
    /// The app playing (for a web app or browser tab: the web app or browser, not its media helper).
    private(set) var playerBundleID: String?
    var onChange: (() -> Void)?

    private let mr = MediaRemote.shared
    private var pollTimer: Timer?
    private var active = true
    private var observers: [NSObjectProtocol] = []
    private var readGeneration = 0
    private var artworkData: Data?
    private var artworkTrackID: String?

    var playerName: String? {
        guard let id = playerBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func start() {
        guard observers.isEmpty else { return }
        guard mr.isAvailable else {
            availability = .unavailable
            Log.player.error("MediaRemote unavailable; Now Playing can't be read")
            onChange?()
            return
        }
        mr.register()
        let names = ["kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                     "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                     "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                     "kMRMediaRemoteNowPlayingPlaybackQueueChangedNotification"]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.read() }
            })
        }
        read()
        reschedule()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if mr.isAvailable { mr.unregister() }
        snapshot = .empty
    }

    func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        reschedule()
        if active { read() }
    }

    /// The cover MediaRemote handed over with the track, as a temporary file (the colour service reads URLs).
    func fetchArtworkURL(for track: Track, completion: @escaping (URL?) -> Void) {
        guard artworkTrackID == track.id, let data = artworkData else { completion(nil); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("overlyric-artwork-\(abs(track.id.hashValue)).img")
        do { try data.write(to: url, options: .atomic); completion(url) } catch { completion(nil) }
    }

    /// Encore: back to the top of the current song, and play.
    func restart(trackID: String) {
        guard snapshot.track?.id == trackID else { return }
        mr.setElapsedTime(0)
        mr.send(.play)
        readSoon()
    }

    /// Brings the player forward (the web app, browser or music app).
    func open() {
        guard let id = playerBundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
        app.activate()
    }

    // MARK: Reading

    private func reschedule() {
        pollTimer?.invalidate()
        let interval: TimeInterval = active ? (snapshot.isPlaying ? 2 : 5) : 20
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func readSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.read() }
        }
    }

    /// Three asynchronous reads (info, is-playing, client), applied together once all have answered.
    private func read() {
        readGeneration += 1
        let generation = readGeneration
        var info: [String: Any]??
        var playing: Bool?
        var client: (bundle: String?, parent: String?)?
        let finish = { [weak self] in
            guard let self, generation == self.readGeneration,
                  let info, let playing, let client else { return }
            self.handle(info: info, playing: playing, bundle: client.parent ?? client.bundle)
        }
        mr.nowPlayingInfo { info = .some($0); MainActor.assumeIsolated(finish) }
        mr.isPlaying { playing = $0; MainActor.assumeIsolated(finish) }
        mr.client { client = $0; MainActor.assumeIsolated(finish) }
    }

    private func handle(info: [String: Any]?, playing: Bool, bundle: String?) {
        if availability != .ok { availability = .ok; onChange?() }
        let now = Date()
        guard let info, let title = info[MediaRemote.Key.title] as? String, !title.isEmpty else {
            if snapshot != .empty { apply(track: nil, playing: false, position: 0, at: now) }
            playerBundleID = bundle
            return
        }
        let artist = info[MediaRemote.Key.artist] as? String ?? ""
        let album = info[MediaRemote.Key.album] as? String ?? ""
        let duration = Self.number(info[MediaRemote.Key.duration]) ?? 0
        // Web players give a new item id now and then for the same song, so the id is the song itself.
        let id = "nowplaying:\(title)|\(artist)"
        var track = Track(id: id, name: title, artist: artist, album: album, duration: duration)
        // Browsers often report the duration a moment after the title; keep the known one meanwhile.
        if let current = snapshot.track, current.id == id, duration <= 0 { track = current }

        let elapsed = Self.number(info[MediaRemote.Key.elapsed]) ?? 0
        let rate = Self.number(info[MediaRemote.Key.rate]) ?? (playing ? 1 : 0)
        let stamp = info[MediaRemote.Key.timestamp] as? Date ?? now
        var position = elapsed
        if playing, rate > 0 { position += now.timeIntervalSince(stamp) * rate }
        if track.duration > 0 { position = min(position, track.duration) }

        playerBundleID = bundle
        if track.id != artworkTrackID || artworkData == nil, let art = info[MediaRemote.Key.artwork] as? Data {
            artworkData = art
            artworkTrackID = track.id
        } else if track.id != artworkTrackID {
            artworkData = nil
            artworkTrackID = nil
        }
        apply(track: track, playing: playing, position: max(0, position), at: now)
    }

    private func apply(track: Track?, playing: Bool, position: TimeInterval, at sampledAt: Date) {
        var s = snapshot
        let trackChanged = s.track != track
        let playChanged = s.isPlaying != playing
        let drift = abs(s.position(at: sampledAt) - position)
        // A read that agrees with our extrapolation is noise; keep the smooth clock.
        if !trackChanged, !playChanged, drift < 0.4 { return }
        s.track = track
        s.isPlaying = playing
        s.position = position
        s.timestamp = sampledAt
        snapshot = s
        if trackChanged || playChanged {
            Log.player.notice("now playing: \(playing ? "playing" : "paused", privacy: .public) \(track?.name ?? "-", privacy: .public) / \(track?.artist ?? "-", privacy: .public) @\(position, privacy: .public) via \(self.playerBundleID ?? "?", privacy: .public)")
            reschedule()
        } else {
            Log.player.notice("resync: Δ=\(String(format: "%.2f", drift), privacy: .public)s → @\(String(format: "%.2f", position), privacy: .public)")
        }
        onChange?()
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

/// The handful of MediaRemote.framework calls we use, looked up with dlsym.
/// Note: macOS 15.4 and later only answer these for Apple-entitled processes; there it reads nothing.
final class MediaRemote: @unchecked Sendable {
    static let shared = MediaRemote()

    enum Key {
        static let title = "kMRMediaRemoteNowPlayingInfoTitle"
        static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
        static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
        static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
        static let elapsed = "kMRMediaRemoteNowPlayingInfoElapsedTime"
        static let rate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
        static let timestamp = "kMRMediaRemoteNowPlayingInfoTimestamp"
        static let artwork = "kMRMediaRemoteNowPlayingInfoArtworkData"
    }

    enum Command: Int32 { case play = 0, pause = 1, toggle = 2 }

    private typealias InfoFn = @convention(c) (DispatchQueue, @escaping (NSDictionary?) -> Void) -> Void
    private typealias PlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias ClientFn = @convention(c) (DispatchQueue, @escaping (AnyObject?) -> Void) -> Void
    private typealias ClientStringFn = @convention(c) (AnyObject?) -> Unmanaged<CFString>?
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias UnregisterFn = @convention(c) () -> Void
    private typealias SetElapsedFn = @convention(c) (Double) -> Void
    private typealias SendFn = @convention(c) (Int32, NSDictionary?) -> Bool

    private let getInfo: InfoFn?
    private let getPlaying: PlayingFn?
    private let getClient: ClientFn?
    private let clientBundle: ClientStringFn?
    private let clientParent: ClientStringFn?
    private let registerFn: RegisterFn?
    private let unregisterFn: UnregisterFn?
    private let setElapsedFn: SetElapsedFn?
    private let sendFn: SendFn?

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        func load<T>(_ name: String, _: T.Type) -> T? {
            guard let handle, let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        getInfo = load("MRMediaRemoteGetNowPlayingInfo", InfoFn.self)
        getPlaying = load("MRMediaRemoteGetNowPlayingApplicationIsPlaying", PlayingFn.self)
        getClient = load("MRMediaRemoteGetNowPlayingClient", ClientFn.self)
        clientBundle = load("MRNowPlayingClientGetBundleIdentifier", ClientStringFn.self)
        clientParent = load("MRNowPlayingClientGetParentAppBundleIdentifier", ClientStringFn.self)
        registerFn = load("MRMediaRemoteRegisterForNowPlayingNotifications", RegisterFn.self)
        unregisterFn = load("MRMediaRemoteUnregisterForNowPlayingNotifications", UnregisterFn.self)
        setElapsedFn = load("MRMediaRemoteSetElapsedTime", SetElapsedFn.self)
        sendFn = load("MRMediaRemoteSendCommand", SendFn.self)
    }

    var isAvailable: Bool { getInfo != nil && getPlaying != nil }

    func register() { registerFn?(.main) }
    func unregister() { unregisterFn?() }

    /// Callbacks arrive on the main queue.
    func nowPlayingInfo(_ completion: @escaping ([String: Any]?) -> Void) {
        guard let getInfo else { completion(nil); return }
        getInfo(.main) { completion($0 as? [String: Any]) }
    }

    func isPlaying(_ completion: @escaping (Bool) -> Void) {
        guard let getPlaying else { completion(false); return }
        getPlaying(.main, completion)
    }

    func client(_ completion: @escaping ((bundle: String?, parent: String?)) -> Void) {
        guard let getClient else { completion((nil, nil)); return }
        getClient(.main) { [clientBundle, clientParent] c in
            completion((clientBundle?(c)?.takeUnretainedValue() as String?,
                        clientParent?(c)?.takeUnretainedValue() as String?))
        }
    }

    func setElapsedTime(_ seconds: Double) { setElapsedFn?(seconds) }
    @discardableResult func send(_ command: Command) -> Bool { sendFn?(command.rawValue, nil) ?? false }
}
