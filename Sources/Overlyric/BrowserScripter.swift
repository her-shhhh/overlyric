import AppKit
import Foundation
import ScriptingBridge
import OverlyricCore

/// Reads YouTube tabs in a Chromium browser (Chrome, Brave, Edge, Arc, …) through ScriptingBridge on a
/// dedicated serial queue: one Apple Event per window lists its tabs' URLs, then a small script runs in
/// each YouTube tab to read the `<video>` element and the page's Media Session metadata.
/// Needs the browser's "Allow JavaScript from Apple Events" switch (View › Developer) to be on.
final class BrowserScripter: NSObject, SBApplicationDelegate {
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
    }

    struct TabRef: Equatable {
        let pid: pid_t
        let tabID: String
        let windowIndex: Int   // 0-based, at read time
        let tabIndex: Int      // 0-based, at read time
    }

    struct Reading {
        let videos: [Video]
        let sampledAt: Date
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

    private static let watchHosts = ["youtube.com", "music.youtube.com", "www.youtube.com", "m.youtube.com"]

    /// The page script: everything about the video in this tab, as one JSON string.
    private static let probe = """
    (function(){try{
    var v=document.querySelector('#movie_player video, video.html5-main-video, video');
    if(!v)return JSON.stringify({none:true});
    var u=new URL(location.href);
    var id=u.searchParams.get('v')||((u.pathname.match(/\\/(shorts|embed|live)\\/([^\\/?]+)/)||[])[2])||'';
    var mp=document.getElementById('movie_player');
    var ad=!!(mp&&mp.classList.contains('ad-showing'))||!!document.querySelector('.ytp-ad-player-overlay, .ytp-ad-player-overlay-layout');
    var md=(navigator.mediaSession&&navigator.mediaSession.metadata)||null;
    var title=(md&&md.title)||'', artist=(md&&md.artist)||'', album=(md&&md.album)||'';
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

    /// Every YouTube tab of the browser with the given pid.
    func read(pid: pid_t, completion: @escaping (Result<Reading, Failure>) -> Void) {
        queue.async {
            let result = self.readSync(pid: pid)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Starts the video in the given tab again from the top.
    func restart(_ tab: TabRef) {
        queue.async {
            guard let t = self.tabObject(tab) else { return }
            _ = self.execute("(function(){var v=document.querySelector('#movie_player video, video');if(v){v.currentTime=0;v.play();}return 'ok';})()", in: t)
        }
    }

    /// Brings the browser and the given tab to the front.
    func activate(_ tab: TabRef) {
        queue.async {
            guard let app = self.bridge(pid: tab.pid), let windows = app.value(forKey: "windows") as? SBElementArray,
                  tab.windowIndex < windows.count, let window = windows.object(at: tab.windowIndex) as? SBObject else { return }
            if let tabs = window.value(forKey: "tabs") as? SBElementArray,
               case let ids = tabs.array(byApplying: NSSelectorFromString("id")),
               let index = ids.firstIndex(where: { Self.string($0) == tab.tabID }) {
                window.setValue(index + 1, forKey: "activeTabIndex")
            }
            window.setValue(1, forKey: "index")
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

    private func tabObject(_ tab: TabRef) -> SBObject? {
        guard let app = bridge(pid: tab.pid), let windows = app.value(forKey: "windows") as? SBElementArray else { return nil }
        for w in 0..<windows.count {
            guard let window = windows.object(at: w) as? SBObject, let tabs = window.value(forKey: "tabs") as? SBElementArray else { continue }
            let ids = tabs.array(byApplying: NSSelectorFromString("id"))
            if let i = ids.firstIndex(where: { Self.string($0) == tab.tabID }), let t = tabs.object(at: i) as? SBObject { return t }
        }
        return nil
    }

    private func execute(_ js: String, in tab: SBObject) -> String? {
        lastError = nil
        let result = tab.perform(NSSelectorFromString("executeJavascript:"), with: js)
        return Self.string(result?.takeUnretainedValue())
    }

    private func readSync(pid: pid_t) -> Result<Reading, Failure> {
        guard let app = bridge(pid: pid) else { return .failure(.notRunning) }
        lastError = nil
        guard let windows = app.value(forKey: "windows") as? SBElementArray else { return .failure(classify(lastError)) }
        let windowCount = windows.count
        if let err = lastError { return .failure(classify(err)) }
        var videos: [Video] = []
        for w in 0..<windowCount {
            guard let window = windows.object(at: w) as? SBObject, let tabs = window.value(forKey: "tabs") as? SBElementArray else { continue }
            lastError = nil
            let urls = tabs.array(byApplying: NSSelectorFromString("URL"))
            if let err = lastError { return .failure(classify(err)) }
            var ids: [Any]?
            for (i, raw) in urls.enumerated() {
                guard let url = Self.string(raw), Self.isYouTubeWatch(url) else { continue }
                if ids == nil { ids = tabs.array(byApplying: NSSelectorFromString("id")) }
                guard let tab = tabs.object(at: i) as? SBObject else { continue }
                let tabID = ids.flatMap { i < $0.count ? Self.string($0[i]) : nil } ?? url
                guard let json = execute(Self.probe, in: tab) else {
                    if let err = lastError { return .failure(classify(err)) }
                    continue
                }
                if let video = Self.parse(json, tab: TabRef(pid: pid, tabID: tabID, windowIndex: w, tabIndex: i)) {
                    videos.append(video)
                }
            }
        }
        return .success(Reading(videos: videos, sampledAt: Date()))
    }

    private static func isYouTubeWatch(_ url: String) -> Bool {
        guard let u = URL(string: url), let host = u.host?.lowercased(), watchHosts.contains(host) else { return false }
        let path = u.path
        return path == "/watch" || path.hasPrefix("/shorts/") || path.hasPrefix("/live/") || host == "music.youtube.com"
    }

    private static func parse(_ json: String, tab: TabRef) -> Video? {
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
            position: d("pos"), duration: d("dur"), paused: b("paused"), ended: b("ended"), isAd: b("ad"), isMusicSite: b("music"))
    }

    private static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let s = v as? NSString { return s as String }
        return nil
    }

    private func classify(_ error: NSError?) -> Failure {
        guard let error else { return .other("no reply from the browser") }
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("javascript") || text.localizedCaseInsensitiveContains("apple events") {
            return .javascriptDisabled
        }
        switch error.code {
        case -1743: return .denied
        case -1712: return .timeout
        case -600, -609: return .notRunning
        default: return .other("\(error.code): \(text)")
        }
    }

    // MARK: SBApplicationDelegate

    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
        lastError = error as NSError
        return nil
    }
}
