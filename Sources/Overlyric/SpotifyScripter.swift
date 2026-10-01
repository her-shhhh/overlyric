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

    private func readSync(full: Bool, pid: pid_t) -> Result<Reading, Failure> {
        if app == nil || appPID != pid {
            app = SBApplication(processIdentifier: pid)
            appPID = pid
            app?.delegate = self
            app?.timeout = 60 * 10   // ticks (1/60 s): 10 s
        }
        guard let app else { return .failure(.notRunning) }
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
