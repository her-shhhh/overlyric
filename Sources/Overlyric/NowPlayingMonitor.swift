import AppKit
import OverlyricCore

/// Tracks whatever macOS shows as Now Playing (the Control Centre media tile): YouTube Music in a browser
/// tab or as a Safari / Chrome web app, Apple Music, a podcast app, anything that publishes media
/// metadata. Read through the bundled MediaRemote Adapter (`NowPlayingAdapter`), which streams every
/// change as it happens; works on every macOS version, with no permission prompt.
/// The position is the player's elapsed time at its own timestamp, extrapolated by its playback rate.
@MainActor
final class NowPlayingMonitor: PlaybackSource {
    enum Availability: Equatable { case unknown, ok, unavailable }

    private(set) var snapshot = PlaybackSnapshot.empty
    private(set) var availability: Availability = .unknown
    /// The app playing (for a web app or browser tab: the web app or browser, not its media helper).
    private(set) var playerBundleID: String?
    var onChange: (() -> Void)?

    private let adapter = NowPlayingAdapter()
    private var stream: Process?
    private var streamGeneration = 0
    private var streamStartedAt = Date.distantPast
    /// Streams in a row that ended before saying anything; three means the adapter can't run here.
    private var quickFailures = 0
    /// The current Now Playing state: the last full payload with every diff since applied.
    private var state: [String: Any] = [:]
    private var artworkData: Data?
    private var artworkTrackID: String?

    var playerName: String? {
        guard let id = playerBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func start() {
        guard stream == nil else { return }
        quickFailures = 0
        launch()
    }

    func stop() {
        streamGeneration += 1                // its exit is expected: don't relaunch
        stream?.terminate()
        stream = nil
        state = [:]
        snapshot = .empty
    }

    /// The stream only speaks when something changes, so it keeps running while the overlay is hidden.
    func setActive(_ value: Bool) {}

    /// The cover that came with the track, as a temporary file (the colour service reads URLs).
    func fetchArtworkURL(for track: Track, completion: @escaping (URL?) -> Void) {
        guard artworkTrackID == track.id, let data = artworkData else { completion(nil); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("overlyric-artwork-\(abs(track.id.hashValue)).img")
        do { try data.write(to: url, options: .atomic); completion(url) } catch { completion(nil) }
    }

    /// Encore: back to the top of the current song, and play.
    func restart(trackID: String) {
        guard snapshot.track?.id == trackID else { return }
        adapter.run(["seek", "0"]) { [adapter] in adapter.run(["send", "0"]) }
    }

    /// Brings the player forward (the web app, browser or music app).
    func open() {
        guard let id = playerBundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
        app.activate()
    }

    // MARK: Reading

    private func launch() {
        streamGeneration += 1
        let generation = streamGeneration
        streamStartedAt = Date()
        let process = adapter.stream(onPayload: { [weak self] payload, diff in
            guard let self, generation == self.streamGeneration else { return }
            self.quickFailures = 0
            if diff {
                for (key, value) in payload {
                    if value is NSNull { self.state.removeValue(forKey: key) } else { self.state[key] = value }
                }
            } else {
                self.state = payload
            }
            self.handle(self.state)
        }, onExit: { [weak self] status in
            guard let self, generation == self.streamGeneration else { return }
            self.stream = nil
            let quick = Date().timeIntervalSince(self.streamStartedAt) < 3 && self.availability != .ok
            self.quickFailures = quick ? self.quickFailures + 1 : 0
            Log.player.error("now playing stream ended (status \(status, privacy: .public), quick failures \(self.quickFailures, privacy: .public))")
            if self.quickFailures >= 3 {
                self.availability = .unavailable
                self.onChange?()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, generation == self.streamGeneration else { return }
                self.launch()
            }
        })
        guard let process else {
            availability = .unavailable
            Log.player.error("MediaRemote Adapter missing; Now Playing can't be read")
            onChange?()
            return
        }
        stream = process
    }

    private func handle(_ info: [String: Any]) {
        if availability != .ok { availability = .ok; onChange?() }
        let now = Date()
        let bundle = info["parentApplicationBundleIdentifier"] as? String ?? info["bundleIdentifier"] as? String
        guard let title = info["title"] as? String, !title.isEmpty else {
            if snapshot != .empty { apply(track: nil, playing: false, position: 0, at: now) }
            playerBundleID = bundle
            return
        }
        let artist = info["artist"] as? String ?? ""
        let album = info["album"] as? String ?? ""
        let duration = Self.seconds(info["durationMicros"]) ?? 0
        // Web players give a new item id now and then for the same song, so the id is the song itself.
        let id = "nowplaying:\(title)|\(artist)"
        var track = Track(id: id, name: title, artist: artist, album: album, duration: duration)
        // Browsers often report the duration a moment after the title; keep the known one meanwhile.
        if let current = snapshot.track, current.id == id, duration <= 0 { track = current }

        let elapsed = Self.seconds(info["elapsedTimeMicros"]) ?? 0
        let reportsPlaying = (info["playing"] as? Bool) ?? false
        let rate = Self.number(info["playbackRate"]) ?? (reportsPlaying ? 1 : 0)
        // Browsers flip the rate to 0 a moment before (or instead of) saying they paused.
        let playing = reportsPlaying && rate > 0
        let stamp = Self.seconds(info["timestampEpochMicros"]).map { Date(timeIntervalSince1970: $0) } ?? now
        var position = elapsed
        if playing { position += now.timeIntervalSince(stamp) * rate }
        if track.duration > 0 { position = min(position, track.duration) }

        playerBundleID = bundle
        if track.id != artworkTrackID || artworkData == nil,
           let art = (info["artworkData"] as? String).flatMap({ Data(base64Encoded: $0) }) {
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

    private static func seconds(_ micros: Any?) -> Double? { number(micros).map { $0 / 1_000_000 } }
}

/// The bundled MediaRemote Adapter (Vendor/MediaRemoteAdapter). Since macOS 15.4 only Apple's own
/// processes may read Now Playing through the private MediaRemote framework; the adapter runs Apple's
/// /usr/bin/perl, which still may, loads a small helper framework into it and prints what is playing as
/// JSON lines. The helper is copied out of the app first: a downloaded copy of the app carries the
/// quarantine flag, and macOS would refuse to load a flagged library into perl.
final class NowPlayingAdapter: @unchecked Sendable {
    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")
    private let queue = DispatchQueue(label: "overlyric.nowplaying")

    /// Starts `stream`: every update arrives on the main actor, as (payload, isDiff). Nil if it can't start.
    func stream(onPayload: @escaping @MainActor ([String: Any], Bool) -> Void,
                onExit: @escaping @MainActor (Int32) -> Void) -> Process? {
        guard let p = process(["stream", "--micros", "--debounce=100"]) else { return nil }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        var buffer = Data()
        out.fileHandleForReading.readabilityHandler = { [queue] handle in
            let chunk = handle.availableData
            queue.async {
                guard !chunk.isEmpty else { return }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let payload = object["payload"] as? [String: Any] else { continue }
                    let diff = object["diff"] as? Bool ?? false
                    DispatchQueue.main.async { MainActor.assumeIsolated { onPayload(payload, diff) } }
                }
            }
        }
        p.terminationHandler = { p in
            out.fileHandleForReading.readabilityHandler = nil
            let status = p.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { onExit(status) } }
        }
        do { try p.run() } catch {
            Log.player.error("now playing stream failed to start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return p
    }

    /// A one-off command (seek, send); `then` runs once it has finished.
    func run(_ arguments: [String], then: (@Sendable () -> Void)? = nil) {
        guard let p = process(arguments) else { return }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in then?() }
        try? p.run()
    }

    private func process(_ arguments: [String]) -> Process? {
        guard let helper = installedHelper() else { return nil }
        let p = Process()
        p.executableURL = Self.perl
        p.arguments = [helper.script.path, helper.framework.path] + arguments
        return p
    }

    /// The script and framework, copied byte for byte (no quarantine flag) to Application Support, only
    /// when they differ from what's already there.
    private func installedHelper() -> (script: URL, framework: URL)? {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: Self.perl.path),
              let source = Bundle.main.resourceURL?.appendingPathComponent("MediaRemoteAdapter"),
              let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dest = support.appendingPathComponent("Overlyric/MediaRemoteAdapter")
        let files = ["mediaremote-adapter.pl", "MediaRemoteAdapter.framework/MediaRemoteAdapter"]
        do {
            for file in files {
                let from = source.appendingPathComponent(file), to = dest.appendingPathComponent(file)
                let data = try Data(contentsOf: from)
                if (try? Data(contentsOf: to)) == data { continue }
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: to, options: .atomic)
            }
        } catch {
            Log.player.error("MediaRemote Adapter couldn't be installed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return (dest.appendingPathComponent(files[0]), dest.appendingPathComponent("MediaRemoteAdapter.framework"))
    }
}
