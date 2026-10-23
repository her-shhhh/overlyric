import AppKit
import Foundation
import ScriptingBridge
import OverlyricCore

/// Reads YouTube tabs in a Chromium browser (Chrome, Brave, Edge, Arc, Dia, …) through ScriptingBridge on a
/// dedicated serial queue: one Apple Event per window lists its tabs' URLs, then a small script runs in
/// each YouTube tab to read the `<video>` element and the page's Media Session metadata.
/// Needs the browser's "Allow JavaScript from Apple Events" switch (View › Developer) to be on.
/// All of these browsers list tabs the Chrome way (application › windows › tabs; Dia also hangs them off its
/// profiles, but a window's tabs are the ones that play). They differ in how a tab is brought to the front
/// (`activate`), so a `TabRef` remembers which browser it came from.
final class BrowserScripter: NSObject, SBApplicationDelegate {
    static let diaBundleID = "company.thebrowser.dia"
    static let arcBundleID = "company.thebrowser.Browser"

    /// One YouTube tab with a video in it.
    struct Video: Equatable {
        let tab: TabRef
        let videoID: String
        let title: String
        let channel: String
        let album: String
        let artworkURL: URL?
        let cardSong: String?
        let cardArtist: String?
        let position: TimeInterval
        let duration: TimeInterval
        let paused: Bool
        let ended: Bool
        let isAd: Bool
        let isMusicSite: Bool
        /// When `position` was read from this tab (right after its script answered).
        let sampledAt: Date
    }

    struct TabRef: Equatable {
        let pid: pid_t
        let bundleID: String   // which browser: each brings a tab to the front its own way
        let tabID: String
        let windowIndex: Int   // 0-based, at read time
        let tabIndex: Int      // 0-based, at read time
    }

    struct Reading {
        let videos: [Video]
        /// What the browser showed us, for the log: windows, tabs in them, tabs on YouTube.
        let windows: Int
        let tabs: Int
        let youTubeTabs: Int
    }

    enum Failure: Error {
        case notRunning
        case denied
        case javascriptDisabled
        /// The browser didn't answer in time (typically: the Automation prompt is still on screen).
        case timeout
        case other(String)
    }

    private let queue = DispatchQueue(label: "overlyric.browser.bridge", qos: .utility)
    private var apps: [pid_t: SBApplication] = [:]
    private var lastError: NSError?
    /// Each browser's scripting dictionary (the sdef in its bundle), read once. It decides whether a command
    /// or property may be sent: a scripting object says no to `responds(to:)` for everything it answers by
    /// forwarding, and sending a command the browser doesn't know raises.
    private var dictionaries: [String: String] = [:]

    private static let watchHosts = ["youtube.com", "music.youtube.com", "www.youtube.com", "m.youtube.com"]

    /// The page script: everything about the video in this tab, as one JSON string.
    private static let probe = """
    (function(){try{
    var v=document.querySelector('#movie_player video, video.html5-main-video, video');
    if(!v)return JSON.stringify({none:true});
    var u=new URL(location.href);
    var id=u.searchParams.get('v')||((u.pathname.match(/\\/(shorts|embed|live)\\/([^\\/?]+)/)||[])[2])||'';
    var mp=document.getElementById('movie_player');
    var pd=null;try{pd=(mp&&typeof mp.getVideoData==='function')?mp.getVideoData():null;}catch(e){pd=null;}
    if(pd&&pd.video_id){id=pd.video_id;}
    var ad=!!(mp&&mp.classList.contains('ad-showing'))||!!document.querySelector('.ytp-ad-player-overlay, .ytp-ad-player-overlay-layout');
    var md=(navigator.mediaSession&&navigator.mediaSession.metadata)||null;
    var title=(pd&&pd.title)||(md&&md.title)||'', artist=(pd&&pd.author)||(md&&md.artist)||'', album=(md&&md.album)||'';
    var art='';
    if(md&&md.artwork&&md.artwork.length){art=md.artwork[md.artwork.length-1].src||'';}
    if(!title)title=document.title||'';
    if(!artist){var ch=document.querySelector('#upload-info ytd-channel-name a, ytd-video-owner-renderer #channel-name a, ytd-channel-name a');artist=ch?ch.textContent:'';}
    var song='',cardArtist='';
    var card=document.querySelector('ytd-watch-metadata yt-video-attribute-view-model, ytd-video-description-music-section-renderer yt-video-attribute-view-model, #description yt-video-attribute-view-model');
    if(card){var t=card.querySelector('.yt-video-attribute-view-model__title');var s=card.querySelector('.yt-video-attribute-view-model__subtitle');song=t?t.textContent:'';cardArtist=s?s.textContent:'';}
    return JSON.stringify({id:id,title:title,artist:artist,album:album,art:art,song:song,cardArtist:cardArtist,pos:v.currentTime||0,dur:isFinite(v.duration)?v.duration:0,paused:!!v.paused||v.readyState<2||!!v.seeking,ended:!!v.ended,ad:ad,music:location.hostname.indexOf('music.')===0});
    }catch(e){return JSON.stringify({error:String(e)});}})()
    """

    /// Every YouTube tab of the browser with the given pid. `bundleID` says which browser it is, for `activate`.
    func read(pid: pid_t, bundleID: String, completion: @escaping (Result<Reading, Failure>) -> Void) {
        queue.async {
            let result = self.readSync(pid: pid, bundleID: bundleID)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Lets go of a browser that quit, so its bridge object doesn't linger (a relaunch gets a new pid anyway).
    func forget(pid: pid_t) {
        queue.async { self.apps[pid] = nil }
    }

    /// Lets go of every browser (the YouTube feature was switched off).
    func forgetAll() {
        queue.async { self.apps.removeAll() }
    }

    /// Starts the video in the given tab again from the top.
    func restart(_ tab: TabRef) {
        queue.async {
            guard let found = self.locate(tab) else { return }
            _ = self.execute("(function(){var v=document.querySelector('#movie_player video, video');if(v){v.currentTime=0;v.play();}return 'ok';})()", in: found.tab)
        }
    }

    /// Brings the browser and the given tab to the front. Each browser has its own way: Dia's `focus` command
    /// on the tab (its window `index` is read-only), Arc's `select` on the tab, and Chrome's family sets the
    /// window's `activeTabIndex`. Nothing is sent unless the browser says it understands it, and the app
    /// comes forward either way.
    func activate(_ tab: TabRef) {
        queue.async {
            if let found = self.locate(tab) {
                switch tab.bundleID {
                case Self.diaBundleID:
                    self.send("focus", to: found.tab, in: tab.bundleID)
                case Self.arcBundleID:
                    self.send("select", to: found.tab, in: tab.bundleID)
                    self.set(1, forKey: "index", named: "index", on: found.window, in: tab.bundleID)
                default:
                    self.set(found.tabIndex + 1, forKey: "activeTabIndex", named: "active tab index", on: found.window, in: tab.bundleID)
                    self.set(1, forKey: "index", named: "index", on: found.window, in: tab.bundleID)
                }
            }
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: tab.pid)?.activate()
            }
        }
    }

    // MARK: Bridge

    private func bridge(pid: pid_t) -> SBApplication? {
        if let app = apps[pid] { return app }
        guard let app = SBApplication(processIdentifier: pid) else { return nil }
        app.delegate = self
        app.timeout = 60 * 5   // ticks (1/60 s): 5 s
        apps[pid] = app
        return app
    }

    /// Finds the tab by id in the browser's windows, with the window it's in now (nil once it's closed).
    private func locate(_ tab: TabRef) -> (window: SBObject, tab: SBObject, tabIndex: Int)? {
        guard let app = bridge(pid: tab.pid), let windows = app.value(forKey: "windows") as? SBElementArray else { return nil }
        for w in 0..<windows.count {
            guard let window = windows.object(at: w) as? SBObject, let tabs = window.value(forKey: "tabs") as? SBElementArray else { continue }
            let ids = tabs.array(byApplying: NSSelectorFromString("id"))
            if let i = ids.firstIndex(where: { Self.string($0) == tab.tabID }), let t = tabs.object(at: i) as? SBObject {
                return (window, t, i)
            }
        }
        return nil
    }

    private func execute(_ js: String, in tab: SBObject) -> String? {
        lastError = nil
        let result = tab.perform(NSSelectorFromString("executeJavascript:"), with: js)
        return Self.string(result?.takeUnretainedValue())
    }

    /// The browser's scripting dictionary, from the sdef named in its Info.plist (empty if there is none).
    private func dictionary(for bundleID: String) -> String {
        if let text = dictionaries[bundleID] { return text }
        var text = ""
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID), let bundle = Bundle(url: url),
           let name = bundle.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            if let sdef = bundle.url(forResource: base, withExtension: ext.isEmpty ? "sdef" : ext),
               let contents = try? String(contentsOf: sdef, encoding: .utf8) {
                text = contents
            }
        }
        dictionaries[bundleID] = text
        return text
    }

    /// Whether the browser's dictionary defines a command (or a property) of that name.
    private func knows(_ kind: String, _ name: String, in bundleID: String) -> Bool {
        dictionary(for: bundleID).contains("<\(kind) name=\"\(name)\"")
    }

    /// Sends a command that takes no parameters (Dia's `focus`, Arc's `select`) if the browser's dictionary has it.
    private func send(_ command: String, to object: SBObject, in bundleID: String) {
        guard knows("command", command, in: bundleID) else {
            Log.browser.notice("the browser has no '\(command, privacy: .public)' command; only bringing it forward")
            return
        }
        lastError = nil
        _ = object.perform(NSSelectorFromString(command))
        if let err = lastError {
            Log.browser.notice("'\(command, privacy: .public)' failed: \(err.code, privacy: .public) \(err.localizedDescription, privacy: .public)")
        }
    }

    /// Sets a scripting property (`key` is its Cocoa key, `named` its name in the dictionary) if the browser's
    /// dictionary has it. Setting a key the browser doesn't know would raise (and take the app down).
    private func set(_ value: Int, forKey key: String, named name: String, on object: SBObject, in bundleID: String) {
        guard knows("property", name, in: bundleID) else {
            Log.browser.notice("the browser has no '\(name, privacy: .public)' property; only bringing it forward")
            return
        }
        lastError = nil
        object.setValue(value, forKey: key)
        if let err = lastError {
            Log.browser.notice("setting '\(key, privacy: .public)' failed: \(err.code, privacy: .public) \(err.localizedDescription, privacy: .public)")
        }
    }

    private func readSync(pid: pid_t, bundleID: String) -> Result<Reading, Failure> {
        guard let app = bridge(pid: pid) else { return .failure(.notRunning) }
        lastError = nil
        guard let windows = app.value(forKey: "windows") as? SBElementArray else { return .failure(classify(lastError)) }
        let windowCount = windows.count
        if let err = lastError { return .failure(classify(err)) }
        var videos: [Video] = []
        var tabCount = 0, youTubeCount = 0
        for w in 0..<windowCount {
            guard let window = windows.object(at: w) as? SBObject, let tabs = window.value(forKey: "tabs") as? SBElementArray else { continue }
            lastError = nil
            let urls = tabs.array(byApplying: NSSelectorFromString("URL"))
            if let err = lastError { return .failure(classify(err)) }
            tabCount += urls.count
            var ids: [Any]?
            for (i, raw) in urls.enumerated() {
                guard let url = Self.string(raw), Self.isYouTubeWatch(url) else { continue }
                youTubeCount += 1
                if ids == nil { ids = tabs.array(byApplying: NSSelectorFromString("id")) }
                guard let tab = tabs.object(at: i) as? SBObject else { continue }
                let tabID = ids.flatMap { i < $0.count ? Self.string($0[i]) : nil } ?? url
                let json = execute(Self.probe, in: tab)
                let sampledAt = Date()
                guard let json else {
                    // One tab that won't answer (still loading, crashed, slow) mustn't hide the others. Only
                    // the two failures that mean no tab will ever answer are the whole read's failure.
                    guard let err = lastError else { continue }
                    let failure = classify(err)
                    switch failure {
                    case .denied, .javascriptDisabled:
                        return .failure(failure)
                    default:
                        Log.browser.notice("tab \(i, privacy: .public) of window \(w, privacy: .public) didn't answer (\(err.code, privacy: .public)); skipping it")
                        continue
                    }
                }
                let ref = TabRef(pid: pid, bundleID: bundleID, tabID: tabID, windowIndex: w, tabIndex: i)
                if let video = Self.parse(json, tab: ref, sampledAt: sampledAt) {
                    videos.append(video)
                }
            }
        }
        return .success(Reading(videos: videos, windows: windowCount, tabs: tabCount, youTubeTabs: youTubeCount))
    }

    private static func isYouTubeWatch(_ url: String) -> Bool {
        guard let u = URL(string: url), let host = u.host?.lowercased(), watchHosts.contains(host) else { return false }
        let path = u.path
        return path == "/watch" || path.hasPrefix("/shorts/") || path.hasPrefix("/live/") || host == "music.youtube.com"
    }

    private static func parse(_ json: String, tab: TabRef, sampledAt: Date) -> Video? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Log.browser.error("probe returned non-JSON: \(json.prefix(120), privacy: .public)")
            return nil
        }
        if let error = obj["error"] as? String {
            Log.browser.error("probe failed: \(error, privacy: .public)")
            return nil
        }
        guard obj["none"] == nil else { return nil }
        func s(_ k: String) -> String { (obj[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func d(_ k: String) -> Double { (obj[k] as? NSNumber)?.doubleValue ?? 0 }
        func b(_ k: String) -> Bool { (obj[k] as? NSNumber)?.boolValue ?? false }
        let song = s("song"), cardArtist = s("cardArtist")
        return Video(
            tab: tab, videoID: s("id"), title: s("title"), channel: s("artist"), album: s("album"),
            artworkURL: URL(string: s("art")), cardSong: song.isEmpty ? nil : song, cardArtist: cardArtist.isEmpty ? nil : cardArtist,
            position: d("pos"), duration: d("dur"), paused: b("paused"), ended: b("ended"), isAd: b("ad"), isMusicSite: b("music"),
            sampledAt: sampledAt)
    }

    private static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let s = v as? NSString { return s as String }
        return nil
    }

    /// The error code decides first: -1743 is macOS refusing us Apple Events (its message mentions "Apple
    /// events", which must not be mistaken for a JavaScript problem). Any other error that talks about
    /// JavaScript, in its message or its details, is the browser's "Allow JavaScript from Apple Events"
    /// switch being off.
    private func classify(_ error: NSError?) -> Failure {
        guard let error else { return .other("no reply from the browser") }
        switch error.code {
        case -1743: return .denied
        case -1712: return .timeout
        case -600, -609: return .notRunning
        default: break
        }
        let text = error.localizedDescription
        let details = error.userInfo.values.compactMap { $0 as? String }
        if ([text] + details).contains(where: { $0.localizedCaseInsensitiveContains("javascript") }) {
            return .javascriptDisabled
        }
        return .other("\(error.code): \(text)")
    }

    // MARK: SBApplicationDelegate

    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
        lastError = error as NSError
        return nil
    }
}
