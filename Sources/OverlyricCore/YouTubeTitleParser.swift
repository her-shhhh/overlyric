import Foundation

/// Turns what a YouTube tab knows about a video — its free-text title, the channel it's on and, when
/// YouTube shows one, the "Music" card naming the song — into ordered (title, artist) guesses for lrclib.
///
/// Video titles follow loose conventions ("Artist - Song (Official Video)", "Song | Artist | Lyrics",
/// `Artist "Song"`), so the parser strips the usual noise, splits on the usual separators and tries
/// both orders; the channel name (minus " - Topic", "VEVO", "Official") stands in as the artist when the
/// title has no separator. The last guess is the whole cleaned title with no artist, which the lyrics
/// service turns into a free-text search.
public enum YouTubeTitleParser {
    public struct Input: Equatable, Sendable {
        public var title: String
        public var channel: String
        /// The song and artist from YouTube's "Music" card under the video, when it shows one.
        public var cardSong: String?
        public var cardArtist: String?
        /// True for music.youtube.com, whose metadata is already a clean title and artist.
        public var isMusicSite: Bool

        public init(title: String, channel: String, cardSong: String? = nil, cardArtist: String? = nil, isMusicSite: Bool = false) {
            self.title = title; self.channel = channel; self.cardSong = cardSong; self.cardArtist = cardArtist
            self.isMusicSite = isMusicSite
        }
    }

    // Bracketed noise: (Official Video), [Official Music Video], (Lyrics), (Audio), (Visualizer), (4K), (HD),
    // (Prod. X), [M/V], (Full Song), (Clip officiel), (Color Coded Lyrics), (Official Audio) ...
    private static let bracketNoise = try! NSRegularExpression(
        pattern: #"\s*[\(\[\{]\s*[^\)\]\}]*?(official|lyric|audio|video|visuali[sz]er|\bhd\b|\b4k\b|\bhq\b|\bm/v\b|\bmv\b|prod\.?|explicit|clean|color coded|colour coded|full song|clip|out now|high quality|with lyrics|subtitles|sub\b|cc\b|original|new song|new \d{4}|\b\d{4}\b)[^\)\]\}]*[\)\]\}]"#,
        options: .caseInsensitive)
    // The same noise unbracketed at the end of a segment: "- Official Video", "Lyrics", "HD".
    private static let trailingNoise = try! NSRegularExpression(
        pattern: #"(\s*[-–—|:]\s*|\s+)(official\s+(music\s+)?(video|audio|lyric\s+video|visuali[sz]er)|(full\s+)?(lyrics?|lyric\s+video|lyrical\s+video|lyrics?\s+video|music\s+video|audio|visuali[sz]er|video\s+song|full\s+song|full\s+video)|hd|4k|hq|out\s+now|new\s+song(\s+\d{4})?)\s*$"#,
        options: .caseInsensitive)
    private static let leadingNoise = try! NSRegularExpression(
        pattern: #"^\s*(new\s+song|new\s+video|lyrics?|official\s+video|full\s+song|full\s+video|video\s+song)\s*[-–—|:]\s*"#,
        options: .caseInsensitive)
    private static let hashtags = try! NSRegularExpression(pattern: #"(^|\s)#\S+"#)
    private static let quoted = try! NSRegularExpression(pattern: #"^(.*?)\s*[\"“”']([^\"“”']{2,})[\"“”']\s*(.*)$"#)
    private static let spaces = try! NSRegularExpression(pattern: #"\s{2,}"#)
    private static let channelNoise = try! NSRegularExpression(
        pattern: #"(\s*-\s*topic|vevo|\s+official(\s+channel)?|\s+music(\s+channel)?|\s+tv|\s+records|\s+official\s+music)\s*$"#,
        options: .caseInsensitive)
    private static let artistSplit = try! NSRegularExpression(
        pattern: #"\s+(feat\.?|ft\.?|featuring|x|vs\.?|with)\s+|,\s+|\s+&\s+|\s+and\s+"#, options: [])
    private static let separators = [" - ", " – ", " — ", " | ", " // ", " : ", ": ", " ~ ", " ‒ "]
    private static let separatorRegex = try! NSRegularExpression(pattern: #"\s+[-–—‒|~]\s+|\s*//\s*|\s*:\s+"#)
    // Record labels and aggregators whose channel name is never the artist.
    private static let labelChannels = try! NSRegularExpression(
        pattern: #"^(t-?series|zee music( company)?|sony music( india| entertainment)?|saregama( music)?|tips( official| music)?|yrf|yash raj films|eros now( music)?|speed records|times music|aditya music|lahari music|think music( india)?|coke studio( pakistan| india| bangla)?|mtv.*|vevo|universal music.*|warner (music|records).*|atlantic records|republic records|columbia records|def jam.*|island records|interscope.*|capitol records|rca records|epic records|hungama.*|gaana|jiosaavn|spotify|apple music|netflix.*|amazon.*|zee5|hotstar.*|sonyliv|voot|alt balaji|shemaroo.*|venus.*|ultra.*|wave music|desi music factory|white hill music|geet mp3|humble music|sky digital|yellow music|rhythm boyz|bollywood.*|punjabi.*|hindi.*|songs?|music|lyrics?|lyrical.*)$"#,
        options: .caseInsensitive)
    private static let junkSegment = try! NSRegularExpression(
        pattern: #"^\s*(official.*|.*\blyrics?\b.*|.*\bvideo\b.*|.*\baudio\b.*|.*\bvisuali[sz]er\b.*|hd|4k|hq|season\s*\d+|episode\s*\d+|coke studio.*|netflix|amazon.*|t-series|zee music.*|sony music.*|saregama.*|tips.*|\d{4}|new song.*|out now.*|.*\bremix\b.*)\s*$"#,
        options: .caseInsensitive)

    private static func strip(_ re: NSRegularExpression, _ s: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
    }

    private static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        t = strip(spaces, t).trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "-–—|:~/ \t"))
        return t
    }

    /// The video title without its bracketed and trailing noise, hashtags, or a leading "(3) " unread count.
    public static func cleanTitle(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+-\s+YouTube(\s+Music)?$"#, with: "", options: .regularExpression)
        t = strip(hashtags, t)
        t = strip(bracketNoise, t)
        var previous = ""
        while previous != t {           // "Song - Official Video - Lyrics" sheds one layer per pass
            previous = t
            t = strip(trailingNoise, t)
            t = strip(leadingNoise, t)
        }
        return tidy(t)
    }

    /// "ArtistVEVO", "Artist - Topic", "Artist Official" → "Artist".
    public static func cleanChannel(_ raw: String) -> String {
        var c = raw
        var previous = ""
        while previous != c {
            previous = c
            c = strip(channelNoise, c)
        }
        let cleaned = tidy(c)
        if labelChannels.firstMatch(in: cleaned, range: NSRange(location: 0, length: (cleaned as NSString).length)) != nil { return "" }
        return cleaned
    }

    /// The first name of a collaboration: "A x B", "A ft. B", "A, B", "A & B" → "A".
    /// ("and"/"&" are kept when they'd leave a lone word, e.g. "Simon & Garfunkel".)
    public static func primaryArtist(_ artist: String) -> String {
        let a = tidy(artist)
        guard let m = artistSplit.firstMatch(in: a, range: NSRange(location: 0, length: (a as NSString).length)) else { return a }
        let head = tidy((a as NSString).substring(to: m.range.location))
        let sep = (a as NSString).substring(with: m.range).trimmingCharacters(in: .whitespaces)
        if (sep == "&" || sep == "and"), !head.contains(" ") { return a }   // "Simon & Garfunkel"
        return head.isEmpty ? a : head
    }

    /// The title cut at every separator: "Song (Official Video): Artist | Feat | Label" → 4 pieces.
    private static func split(_ title: String) -> [String] {
        let ns = title as NSString
        var pieces: [String] = []
        var start = 0
        for m in separatorRegex.matches(in: title, range: NSRange(location: 0, length: ns.length)) {
            pieces.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = m.range.location + m.range.length
        }
        pieces.append(ns.substring(from: start))
        return pieces.map(tidy).filter { !$0.isEmpty }
    }

    private static func looksLikeArtist(_ segment: String, channel: String) -> Bool {
        if !channel.isEmpty, segment.compare(channel, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return true }
        return artistSplit.firstMatch(in: segment, range: NSRange(location: 0, length: (segment as NSString).length)) != nil
    }

    private static func looksLikeJunk(_ segment: String) -> Bool {
        junkSegment.firstMatch(in: segment, range: NSRange(location: 0, length: (segment as NSString).length)) != nil
    }

    /// Ordered guesses, most likely first.
    public static func guesses(_ input: Input) -> [TrackGuess] {
        var out: [TrackGuess] = []
        func add(_ name: String, _ artist: String) {
            let n = tidy(name), a = tidy(artist)
            guard !n.isEmpty else { return }
            out.append(TrackGuess(name: n, artist: a))
        }

        let channel = cleanChannel(input.channel)
        if let song = input.cardSong.map(tidy), !song.isEmpty {
            add(song, input.cardArtist.map(cleanChannel) ?? channel)
        }
        let title = cleanTitle(input.title)
        if input.isMusicSite {
            add(title, channel)
        }

        // Artist "Song" (Official Video)
        if let m = quoted.firstMatch(in: title, range: NSRange(location: 0, length: (title as NSString).length)) {
            let before = tidy((title as NSString).substring(with: m.range(at: 1)))
            let song = tidy((title as NSString).substring(with: m.range(at: 2)))
            let after = tidy((title as NSString).substring(with: m.range(at: 3)))
            let artist = !before.isEmpty ? before : after
            add(song, artist.isEmpty ? channel : artist)
        }

        // "A - B" / "A | B" / "A: B" …
        let parts = split(title)
        let meaningful = parts.count > 1 ? parts.filter { !looksLikeJunk($0) } : parts
        let pieces = meaningful.isEmpty ? parts : meaningful
        if pieces.count >= 2 {
            let first = pieces[0], second = pieces[1], last = pieces[pieces.count - 1]
            // Which half is the artist? One that names a collaboration ("A x B", "A ft. B") or is the
            // channel itself. Otherwise "Artist - Song" is the custom with a dash, "Song | Artist" with a pipe.
            let firstArtist = looksLikeArtist(first, channel: channel), secondArtist = looksLikeArtist(second, channel: channel)
            let artistFirst = firstArtist == secondArtist ? !title.contains(" | ") : firstArtist
            if artistFirst {
                add(second, first)                           // Artist - Song
                add(first, second)                           // Song - Artist
            } else {
                add(first, second)
                add(second, first)
            }
            if pieces.count > 2 {
                add(first, last)                             // Song | Album | Artist
                add(last, first)
            }
            if !channel.isEmpty {
                add(second, channel)
                add(first, channel)
            }
        } else if !channel.isEmpty {
            add(title, channel)
        }
        if !title.isEmpty {
            // Free-text fallback: everything that's left, separators collapsed.
            var flat = title
            for sep in separators { flat = flat.replacingOccurrences(of: sep, with: " ") }
            add(flat, "")
        }

        var seen = Set<String>()
        return out.filter { seen.insert("\($0.name)|\($0.artist)".lowercased()).inserted }
    }
}
