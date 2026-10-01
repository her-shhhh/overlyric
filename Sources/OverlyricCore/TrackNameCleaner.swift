import Foundation

/// Produces progressively looser spellings of a Spotify title / artist for lyric lookup.
public enum TrackNameCleaner {
    private static let feat = try! NSRegularExpression(
        pattern: #"\s*[\(\[]\s*(feat\.?|ft\.?|featuring|with)\s+[^\)\]]*[\)\]]"#, options: .caseInsensitive)
    private static let dashFeat = try! NSRegularExpression(
        pattern: #"\s+(feat\.?|ft\.?|featuring)\s+.*$"#, options: .caseInsensitive)
    private static let dashSuffix = try! NSRegularExpression(pattern: #"\s+-\s+.*$"#)
    private static let bracketSuffix = try! NSRegularExpression(
        pattern: #"\s*[\(\[][^\)\]]*(remaster|deluxe|live|version|edit|mix|mono|stereo|bonus|demo|acoustic|anniversary|edition|soundtrack|from |explicit|single|instrumental|sped up|slowed)[^\)\]]*[\)\]]"#,
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

    /// Ordered artist variants: full string, then progressively shorter leading artists.
    public static func artistVariants(_ artist: String) -> [String] {
        let a = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = [a]
        for sep in [", ", " & ", " feat. ", " ft. ", " x ", " X ", " / ", " and "] {
            if let r = a.range(of: sep) {
                let first = String(a[a.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !first.isEmpty { out.append(first) }
            }
        }
        return dedupe(out)
    }

    private static func dedupe(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { seen.insert($0.lowercased()).inserted }
    }
}
