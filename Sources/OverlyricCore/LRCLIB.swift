import Foundation

/// One record from lrclib.net (`/api/get`, `/api/search`).
public struct LRCLIBRecord: Decodable, Equatable, Sendable {
    public let id: Int?
    public let trackName: String?
    public let artistName: String?
    public let albumName: String?
    public let duration: Double?
    public let instrumental: Bool?
    public let plainLyrics: String?
    public let syncedLyrics: String?

    public init(id: Int? = nil, trackName: String? = nil, artistName: String? = nil, albumName: String? = nil,
                duration: Double? = nil, instrumental: Bool? = nil, plainLyrics: String? = nil, syncedLyrics: String? = nil) {
        self.id = id; self.trackName = trackName; self.artistName = artistName; self.albumName = albumName
        self.duration = duration; self.instrumental = instrumental; self.plainLyrics = plainLyrics; self.syncedLyrics = syncedLyrics
    }

    public var hasSyncedLyrics: Bool { !(syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Written in Latin letters (romanized), as opposed to Devanagari, Arabic, Hangul…
    public var isLatinScript: Bool { LyricsMatcher.isLatinScript(syncedLyrics ?? "") }
}

public enum LyricsMatcher {
    /// Normalises a title the way lrclib does: fold diacritics/case, drop apostrophes, punctuation → space.
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
        let mapped = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }

    /// True when the text's letters are (almost all) Latin: romanized Hindi, English, Spanish… rather
    /// than Devanagari, Arabic, Hangul and so on. Digits, punctuation and timestamps don't count.
    public static func isLatinScript(_ text: String) -> Bool {
        var latin = 0, other = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            if scalar.value < 0x0250 || (0x1E00...0x1EFF).contains(scalar.value) { latin += 1 } else { other += 1 }
        }
        return latin + other == 0 || Double(latin) / Double(latin + other) >= 0.9
    }

    /// Picks the synced record closest in duration to ours, in three tiers:
    /// ≤2 s (lrclib's own tolerance) → ≤5 s (CD vs streaming masters) → ≤15 s but only with an exact
    /// normalised title match. Anything further off is a different edit and would drift out of sync.
    /// Ties resolve to the lowest id, mirroring `/api/get`. With `preferLatin`, a romanized record within
    /// the first two tiers (or the third) wins over a non-Latin one there.
    public static func best(from candidates: [LRCLIBRecord], duration: TimeInterval?, title: String? = nil,
                            preferLatin: Bool = false) -> LRCLIBRecord? {
        let synced = candidates.filter(\.hasSyncedLyrics)
        guard let duration, duration > 0 else {
            return (preferLatin ? synced.first(where: \.isLatinScript) : nil) ?? synced.first
        }
        let wanted = title.map(normalize)
        func pick(within tol: TimeInterval, strictTitle: Bool, latinOnly: Bool = false) -> LRCLIBRecord? {
            synced
                .filter { abs(($0.duration ?? -1_000) - duration) <= tol }
                .filter { !strictTitle || (wanted != nil && normalize($0.trackName ?? "") == wanted!) }
                .filter { !latinOnly || $0.isLatinScript }
                .min { a, b in
                    let da = abs((a.duration ?? 0) - duration), db = abs((b.duration ?? 0) - duration)
                    return da == db ? (a.id ?? .max) < (b.id ?? .max) : da < db
                }
        }
        if preferLatin, let latin = pick(within: 5, strictTitle: false, latinOnly: true) { return latin }
        if let close = pick(within: 2, strictTitle: false) ?? pick(within: 5, strictTitle: false) { return close }
        if preferLatin, let latin = pick(within: 15, strictTitle: true, latinOnly: true) { return latin }
        return pick(within: 15, strictTitle: true)
    }
}
