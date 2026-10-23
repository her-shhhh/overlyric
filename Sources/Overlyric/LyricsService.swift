import Foundation
import OverlyricCore

/// Fetches synced lyrics from lrclib.net for a track (from Spotify, or a YouTube tab with its guesses).
/// Requests are strictly sequential with a short spacing and honour 429/503 Retry-After, as lrclib asks.
/// Only definitive answers (found / 404 chain exhausted) are cached; transport or decode failures
/// are reported so the controller can retry later.
@MainActor
final class LyricsService {
    enum LookupError: Error {
        case transport(Error)
        case http(Int)
        case decode(Error)
        case cancelled
    }

    private let session: URLSession
    private var cache: [String: SyncedLyrics?] = [:]
    private let disk = LyricsDiskCache.standard(bundleID: Bundle.main.bundleIdentifier ?? "com.harsh.overlyric")
    private var nextSlot = Date.distantPast
    private static let base = "https://lrclib.net/api"
    private static let spacing: TimeInterval = 0.25

    init() {
        let c = URLSessionConfiguration.ephemeral
        // lrclib answers in ~0.5 s from its cache but a cold lookup can take 5–10 s.
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.waitsForConnectivity = false
        c.httpAdditionalHeaders = ["User-Agent": "Overlyric/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1") (macOS; https://github.com/her-shhhh/overlyric)"]
        session = URLSession(configuration: c)
    }

    static func cacheKey(for track: SpotifyTrack) -> String {
        track.id.isEmpty ? "\(track.name)|\(track.artist)|\(Int(track.duration))" : track.id
    }

    func lyrics(for track: SpotifyTrack) async -> Result<SyncedLyrics?, LookupError> {
        let key = Self.cacheKey(for: track)
        if let cached = cache[key] { return .success(cached) }
        switch disk.load(key) {
        case .found(let lrc)?:
            if let parsed = LRCParser.parse(lrc) {
                cache[key] = .some(parsed)
                Log.lyrics.notice("disk cache hit for \(track.name, privacy: .public)")
                return .success(parsed)
            }
        case .notFound?:
            cache[key] = .some(nil)
            return .success(nil)
        case nil:
            break
        }
        do {
            let (parsed, raw) = try await resolve(track)
            cache[key] = .some(parsed)
            disk.store(raw.map { .found($0) } ?? .notFound, for: key)
            return .success(parsed)
        } catch let error as LookupError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.transport(error))
        }
    }

    // MARK: Lookup chain (see docs/ARCHITECTURE.md § LyricsService)

    /// How many (title, artist) readings of a YouTube video are tried. The first is tried thoroughly, the
    /// rest with a short chain, so a reading that's plain wrong costs a few requests, not dozens.
    private static let maxGuesses = 3

    /// The parsed lyrics and the raw LRC text they came from (for the disk cache).
    /// A Spotify track is one (title, artist); a YouTube video brings a few guesses, tried in order.
    private func resolve(_ t: SpotifyTrack) async throws -> (SyncedLyrics?, String?) {
        let duration: TimeInterval? = t.duration > 0 ? t.duration : nil
        let album: String? = t.album.isEmpty ? nil : t.album
        var seen = Set<String>()
        for (i, guess) in t.guesses.prefix(t.isFromYouTube ? Self.maxGuesses : 1).enumerated() {
            if let hit = try await resolve(guess, album: i == 0 ? album : nil, duration: duration,
                                           thorough: i == 0, fromYouTube: t.isFromYouTube, seen: &seen) {
                return hit
            }
        }
        return (nil, nil)
    }

    /// One guess through the chain. For a video, a search hit must also carry the guessed title: on a
    /// video's duration alone the matcher would hand back any song of that length.
    private func resolve(_ g: TrackGuess, album: String?, duration: TimeInterval?, thorough: Bool, fromYouTube: Bool,
                         seen: inout Set<String>) async throws -> (SyncedLyrics, String)? {
        let romanized = Settings.shared.preferRomanized
        // YouTube artists come as "A x B", "A ft. B"; Spotify's are comma-joined.
        let primary = fromYouTube ? YouTubeTitleParser.primaryArtist(g.artist) : TrackNameCleaner.primaryArtist(g.artist)
        let titles = TrackNameCleaner.titleVariants(g.name)
        let cleaned = titles.last ?? g.name

        // Stage A — exact lookups, cheapest first. lrclib already folds case/punctuation/diacritics.
        var attempts: [(track: String, artist: String, album: String?)] = []
        if !g.artist.isEmpty {
            if thorough {
                attempts = [(g.name, g.artist, album), (g.name, g.artist, nil), (g.name, primary, nil),
                            (cleaned, primary, nil), (cleaned, g.artist, nil)]
                for title in titles.dropFirst().dropLast() { attempts.append((title, primary, nil)) }
            } else {
                attempts = [(g.name, g.artist, nil), (cleaned, primary, nil)]
            }
        }
        for a in attempts {
            let key = "get|\(a.track)|\(a.artist)|\(a.album ?? "")".lowercased()
            guard seen.insert(key).inserted else { continue }
            if var rec = try await get(track: a.track, artist: a.artist, album: a.album, duration: duration), rec.hasSyncedLyrics {
                // `/get` hands back one record. If it isn't romanized, see whether a Latin one exists too.
                if romanized, !rec.isLatinScript,
                   let latin = LyricsMatcher.best(from: try await search(track: a.track, artist: a.artist),
                                                  duration: duration, title: a.track, preferLatin: true), latin.isLatinScript {
                    Log.lyrics.notice("romanized version found for \(a.track, privacy: .public)")
                    rec = latin
                }
                if let raw = rec.syncedLyrics, let parsed = LRCParser.parse(raw) { return (parsed, raw) }
            }
        }

        // Stage B — search (primary artist only: lrclib phrase-matches the artist column).
        var candidates: [LRCLIBRecord] = []
        var searches: [(track: String?, artist: String?, q: String?)] = []
        if !primary.isEmpty { searches.append((cleaned, primary, nil)) }
        if thorough || primary.isEmpty { searches.append((cleaned, nil, nil)) }
        if thorough { searches.append((nil, nil, primary.isEmpty ? cleaned : "\(cleaned) \(primary)")) }
        for s in searches where candidates.isEmpty {
            let key = "search|\(s.track ?? "")|\(s.artist ?? "")|\(s.q ?? "")".lowercased()
            guard seen.insert(key).inserted else { continue }
            candidates = try await search(track: s.track, artist: s.artist, q: s.q)
        }
        if let best = LyricsMatcher.best(from: candidates, duration: duration, title: cleaned,
                                         preferLatin: romanized, requireTitle: fromYouTube),
           let raw = best.syncedLyrics, let parsed = LRCParser.parse(raw) {
            return (parsed, raw)
        }
        return nil
    }

    // MARK: HTTP

    private func get(track: String, artist: String, album: String?, duration: TimeInterval?) async throws -> LRCLIBRecord? {
        var q: [(String, String)] = [("track_name", track), ("artist_name", artist)]
        if let album { q.append(("album_name", album)) }
        if let duration { q.append(("duration", String(format: "%.1f", duration))) }
        guard let data = try await request(path: "/get", query: q) else { return nil }
        do { return try JSONDecoder().decode(LRCLIBRecord.self, from: data) } catch {
            Log.lyrics.error("decode /get failed: \(error.localizedDescription, privacy: .public)")
            throw LookupError.decode(error)
        }
    }

    private func search(track: String? = nil, artist: String? = nil, q: String? = nil) async throws -> [LRCLIBRecord] {
        var query: [(String, String)] = []
        if let q { query.append(("q", q)) }
        if let track { query.append(("track_name", track)) }
        if let artist { query.append(("artist_name", artist)) }
        guard let data = try await request(path: "/search", query: query) else { return [] }
        do { return try JSONDecoder().decode([LRCLIBRecord].self, from: data) } catch {
            Log.lyrics.error("decode /search failed: \(error.localizedDescription, privacy: .public)")
            throw LookupError.decode(error)
        }
    }

    /// Sequential GET with spacing. 404 → nil. 429/503 are retried (max 3 tries, honouring Retry-After);
    /// other HTTP errors, transport errors and cancellation are thrown.
    private func request(path: String, query: [(String, String)]) async throws -> Data? {
        guard let url = Self.url(path: path, query: query) else { return nil }
        try Task.checkCancellation()
        await pace()
        var lastStatus = 0
        var lastError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let started = Date()
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else { throw LookupError.http(-1) }
                Log.lyrics.notice("GET \(url.absoluteString, privacy: .public) → \(http.statusCode, privacy: .public) in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)ms")
                switch http.statusCode {
                case 200: return data
                case 404: return nil
                case 429, 503:
                    lastStatus = http.statusCode
                    let retry = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1
                    try await Task.sleep(nanoseconds: UInt64(min(max(retry, 0.5), 5) * 1_000_000_000))
                default: throw LookupError.http(http.statusCode)
                }
            } catch let error as LookupError {
                throw error
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                Log.lyrics.error("GET \(url.absoluteString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                lastError = error
                if attempt < 2 { try await Task.sleep(nanoseconds: 400_000_000) }
            }
        }
        if let lastError { throw LookupError.transport(lastError) }
        throw LookupError.http(lastStatus)
    }

    /// Reserves the next send slot before suspending, so concurrent callers stay spaced out.
    private func pace() async {
        let slot = max(Date(), nextSlot)
        nextSlot = slot.addingTimeInterval(Self.spacing)
        let wait = slot.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    /// Strict RFC 3986 encoding — URLComponents leaves '&' and '+' unescaped in query values.
    private static func url(path: String, query: [(String, String)]) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let parts = query.compactMap { k, v -> String? in
            guard let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            return "\(k)=\(ev)"
        }
        return URL(string: base + path + "?" + parts.joined(separator: "&"))
    }
}
