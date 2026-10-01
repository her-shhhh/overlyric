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

    /// Picks the synced record closest in duration to ours, in three tiers:
    /// ≤2 s (lrclib's own tolerance) → ≤5 s (CD vs streaming masters) → ≤15 s but only with an exact
    /// normalised title match. Anything further off is a different edit and would drift out of sync.
    /// Ties resolve to the lowest id, mirroring `/api/get`.
    public static func best(from candidates: [LRCLIBRecord], duration: TimeInterval?, title: String? = nil) -> LRCLIBRecord? {
        let synced = candidates.filter(\.hasSyncedLyrics)
        guard let duration, duration > 0 else { return synced.first }
        let wanted = title.map(normalize)
        func pick(within tol: TimeInterval, strictTitle: Bool) -> LRCLIBRecord? {
            synced
                .filter { abs(($0.duration ?? -1_000) - duration) <= tol }
                .filter { !strictTitle || (wanted != nil && normalize($0.trackName ?? "") == wanted!) }
                .min { a, b in
                    let da = abs((a.duration ?? 0) - duration), db = abs((b.duration ?? 0) - duration)
                    return da == db ? (a.id ?? .max) < (b.id ?? .max) : da < db
                }
        }
        return pick(within: 2, strictTitle: false) ?? pick(within: 5, strictTitle: false) ?? pick(within: 15, strictTitle: true)
    }
}
