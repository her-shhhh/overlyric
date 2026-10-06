import Foundation

/// Produces progressively looser spellings of a title / artist (Spotify or YouTube) for lyric lookup.
public enum TrackNameCleaner {
    private static let feat = try! NSRegularExpression(
        pattern: #"\s*[\(\[]\s*(feat\.?|ft\.?|featuring|with)\s+[^\)\]]*[\)\]]"#, options: .caseInsensitive)
    private static let dashFeat = try! NSRegularExpression(
        pattern: #"\s+(feat\.?|ft\.?|featuring)\s+.*$"#, options: .caseInsensitive)
    private static let dashSuffix = try! NSRegularExpression(pattern: #"\s+-\s+.*$"#)
    private static let bracketSuffix = try! NSRegularExpression(
        pattern: #"\s*[\(\[][^\)\]]*(remaster|deluxe|live|version|edit|mix|mono|stereo|bonus|demo|acoustic|anniversary|edition|soundtrack|from |explicit|single|instrumental|sped up|slowed|official|video|audio|lyric|visuali[sz]er|full song)[^\)\]]*[\)\]]"#,
        options: .caseInsensitive)

    private static func apply(_ re: NSRegularExpression, _ s: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ordered, de-duplicated title variants: original first, then cleaned forms.
    public static func titleVariants(_ title: String) -> [String] {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let noFeat = apply(dashFeat, apply(feat, t))
        let noDash = apply(dashSuffix, noFeat)
        let noBracket = apply(bracketSuffix, noDash)
        return dedupe([t, noFeat, noDash, noBracket].filter { !$0.isEmpty })
    }

    /// The first artist of a Spotify artist string (Spotify joins multiple artists with ", " only, so
    /// "Simon & Garfunkel" and "Florence and the Machine" stay intact).
    public static func primaryArtist(_ artist: String) -> String {
        let a = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = a.range(of: ", ") else { return a }
        let first = a[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
        return first.isEmpty ? a : first
    }

    private static let videoWords = try! NSRegularExpression(
        pattern: #"\s+(full|official|lyric(al)?|hd|4k)?\s*(video|audio|song|lyrics?)(\s+song)?\s*$"#, options: .caseInsensitive)

    /// Guesses (title, artist) from a YouTube-style video title and channel, best first:
    /// "Song | Full Song | Movie | Cast" → "Song"; "Artist - Song (Official Video)" → ("Song", "Artist")
    /// and the other way round; the channel ("ArtistVEVO", "Artist - Topic") as the artist otherwise.
    /// A nil artist means "search by title alone".
    public static func videoGuesses(title: String, channel: String) -> [(title: String, artist: String?)] {
        var artist = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - Topic", "VEVO", " Official", " Music"] where artist.hasSuffix(suffix) {
            artist = String(artist.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        // Usually the song comes first ("Song | Movie | Cast"); some channels lead with the singer.
        let segments = title.components(separatedBy: " | ").prefix(2)
        var guesses: [(String, String?)] = []
        for (i, segment) in segments.enumerated() {
            let base = apply(videoWords, apply(bracketSuffix, apply(dashFeat, apply(feat, segment))))
            var dashed = false
            for dash in [" - ", " – ", " — "] {
                let parts = base.components(separatedBy: dash)
                guard parts.count == 2 else { continue }
                let left = parts[0].trimmingCharacters(in: .whitespaces), right = parts[1].trimmingCharacters(in: .whitespaces)
                guard !left.isEmpty, !right.isEmpty else { continue }
                guesses += [(right, primaryArtist(left)), (left, primaryArtist(right)), (right, nil), (left, nil)]
                dashed = true
                break
            }
            guard !dashed else { continue }
            if i == 1, segments.count == 2 {
                // "Singer | Song": the first segment is the artist.
                let singer = apply(videoWords, segments[segments.startIndex]).trimmingCharacters(in: .whitespaces)
                if !singer.isEmpty { guesses.append((base, primaryArtist(singer))) }
            }
            if !artist.isEmpty { guesses.append((base, artist)) }
            guesses.append((base, nil))
        }
        var seen = Set<String>()
        return guesses.filter { !$0.0.isEmpty && seen.insert("\($0.0)|\($0.1 ?? "")".lowercased()).inserted }
    }

    /// Whether a title looks like a video's ("Song | Movie | Cast", "Artist - Song (Official Video)").
    public static func looksLikeVideoTitle(_ title: String) -> Bool {
        title.contains(" | ") || apply(bracketSuffix, title) != title.trimmingCharacters(in: .whitespacesAndNewlines)
            || title.contains(" - ") || title.contains(" – ")
    }

    private static func dedupe(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { seen.insert($0.lowercased()).inserted }
    }
}
