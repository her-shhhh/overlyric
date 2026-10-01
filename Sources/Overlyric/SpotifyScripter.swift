import AppKit
import Foundation
import ScriptingBridge
import OverlyricCore

/// Reads Spotify's player state through ScriptingBridge (Apple Events) on a dedicated serial queue.
/// NSAppleScript is NOT used: on macOS 26 it deadlocks when executed off the main thread, whereas
/// SBApplication KVC reads work from a background queue (~8 ms per property).
final class SpotifyScripter: NSObject, SBApplicationDelegate {
    enum PlayerState: Equatable { case playing, paused, stopped }

    struct Reading {
        let state: PlayerState
        let position: TimeInterval   // seconds
        let sampledAt: Date          // when `position` was read
        let track: SpotifyTrack?     // only on a full read
    }

    enum Failure: Error {
        case notRunning
        case denied
        case other(String)
    }

    private let queue = DispatchQueue(label: "overlyric.spotify.bridge", qos: .utility)
    private var app: SBApplication?
    private var appPID: pid_t = 0
    private var lastError: NSError?

    // Four-char enum codes Spotify returns for `player state`.
    private static let codePlaying: UInt32 = 0x6B50_5350 // 'kPSP'
    private static let codePaused: UInt32 = 0x6B50_5370  // 'kPSp'

    /// `full` also reads the current track (5 extra round trips); otherwise only state + position.
    /// `pid` is the running Spotify process: targeting it (not the bundle id) can never launch Spotify.
    func read(full: Bool, pid: pid_t, completion: @escaping (Result<Reading, Failure>) -> Void) {
        queue.async {
            let result = self.readSync(full: full, pid: pid)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Reads the current track's id and artwork URL (two round trips).
    func readArtwork(pid: pid_t, completion: @escaping ((id: String, url: URL)?) -> Void) {
        queue.async {
            var result: (id: String, url: URL)?
            if let app = self.bridge(pid: pid), let t = app.value(forKey: "currentTrack") as? SBObject,
               let id = t.value(forKey: "id") as? String,
               let raw = t.value(forKey: "artworkUrl") as? String, let url = URL(string: raw) {
                result = (id, url)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Starts the given track again: rewinds it if it's still playing, otherwise goes back to it.
    func restart(trackID: String, pid: pid_t) {
        queue.async {
            guard let app = self.bridge(pid: pid) else { return }
            let current = (app.value(forKey: "currentTrack") as? SBObject)?.value(forKey: "id") as? String
            app.setValue(0, forKey: "playerPosition")
            // From position 0, "previous" goes back a track (later in a track it would only rewind it).
            if current != trackID { app.perform(NSSelectorFromString("previousTrack")) }
        }
    }

    /// Plays the given track ("spotify:track:…") from the top.
    func play(uri: String, pid: pid_t) {
        queue.async {
            let play = NSSelectorFromString("playTrack:inContext:")
            guard let app = self.bridge(pid: pid), app.responds(to: play) else { return }
            app.perform(play, with: uri, with: nil)
        }
    }

    private func bridge(pid: pid_t) -> SBApplication? {
        if app == nil || appPID != pid {
            app = SBApplication(processIdentifier: pid)
            appPID = pid
            app?.delegate = self
            app?.timeout = 60 * 10   // ticks (1/60 s): 10 s
        }
        return app
    }

    private func readSync(full: Bool, pid: pid_t) -> Result<Reading, Failure> {
        guard let app = bridge(pid: pid) else { return .failure(.notRunning) }
        lastError = nil

        guard let stateNumber = app.value(forKey: "playerState") as? NSNumber else {
            return .failure(classify(lastError))
        }
        let state: PlayerState
        switch stateNumber.uint32Value {
        case Self.codePlaying: state = .playing
        case Self.codePaused: state = .paused
        default: state = .stopped
        }
        let position = (app.value(forKey: "playerPosition") as? NSNumber)?.doubleValue ?? 0
        let sampledAt = Date()
        guard full, state != .stopped else {
            return .success(Reading(state: state, position: position, sampledAt: sampledAt, track: nil))
        }

        var track: SpotifyTrack?
        if let t = app.value(forKey: "currentTrack") as? SBObject {
            let id = t.value(forKey: "id") as? String ?? ""
            let name = t.value(forKey: "name") as? String ?? ""
            if !(id.isEmpty && name.isEmpty) {
                track = SpotifyTrack(
                    id: id, name: name,
                    artist: t.value(forKey: "artist") as? String ?? "",
                    album: t.value(forKey: "album") as? String ?? "",
                    duration: ((t.value(forKey: "duration") as? NSNumber)?.doubleValue ?? 0) / 1000)
            }
        }
        if track == nil, let err = lastError { return .failure(classify(err)) }
        return .success(Reading(state: state, position: position, sampledAt: sampledAt, track: track))
    }

    private func classify(_ error: NSError?) -> Failure {
        guard let error else { return .other("no reply from Spotify") }
        switch error.code {
        case -1743: return .denied
        case -600, -609: return .notRunning
        default: return .other("\(error.code): \(error.localizedDescription)")
        }
    }

    // MARK: SBApplicationDelegate

    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
        lastError = error as NSError
        return nil
    }
}
