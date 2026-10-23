import Foundation

/// Turns what a YouTube tab knows about a video — its free-text title, the channel it's on and, when
/// YouTube shows one, the "Music" card naming the song — into ordered (title, artist) guesses for lrclib.
///
/// Video titles follow loose conventions ("Artist - Song (Official Video)", "Song | Artist | Lyrics",
/// `Artist "Song"`), so the parser strips the usual noise, splits on the usual separators and tries
/// both orders; the channel name (minus " - Topic", "VEVO", "Official") stands in as the artist when the
/// title has no separator. At most four guesses come back, most likely first. The whole cleaned title
/// with no artist, which the lyrics service turns into a free-text search, is the last of them when
/// there is room.
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
    // Artist "Song": straight or curly double quotes anywhere in the title.
    private static let doubleQuoted = try! NSRegularExpression(pattern: #"^(.*?)\s*["“”]([^"“”]{2,})["“”]\s*(.*)$"#)
    // Adele 'Hello': single quotes count only when they stand alone — opened after a space (or the start) and closed
    // before a space (or the end) — so the apostrophes in "Don't Stop Believin'" and "Guns N' Roses" are not a pair.
    private static let singleQuoted = try! NSRegularExpression(pattern: #"^(.*?)(?:^|\s)[‘']([^‘’']{2,})[’'](?:\s+|$)(.*)$"#)
    private static let spaces = try! NSRegularExpression(pattern: #"\s{2,}"#)
    private static let channelNoise = try! NSRegularExpression(
        pattern: #"(\s*-\s*topic|vevo|\s+official(\s+channel)?|\s+music(\s+channel)?|\s+tv|\s+records|\s+official\s+music)\s*$"#,
        options: .caseInsensitive)
    private static let artistSplit = try! NSRegularExpression(
        pattern: #"\s+(feat\.?|ft\.?|featuring|x|vs\.?|with)\s+|,\s+|\s+&\s+|\s+and\s+"#, options: [])
    // The commas and "&"/"and" of a list-shaped band name: "Earth, Wind & Fire", "Peter, Paul and Mary".
    private static let bandListSplit = try! NSRegularExpression(pattern: #",\s*|\s+&\s+|\s+and\s+"#, options: .caseInsensitive)
    private static let separators = [" - ", " – ", " — ", " | ", " // ", " : ", ": ", " ~ ", " ‒ "]
    private static let separatorRegex = try! NSRegularExpression(pattern: #"\s+[-–—‒|~]\s+|\s*//\s*|\s*:\s+"#)
    // Record labels, studios and streaming services whose channel name is never the artist. Each brand takes only
    // its known suffixes (a bounded number of extra words), so "Ultra Naté" is not swallowed by "Ultra Music".
    private static let labelNames = #"t-?series(\s+\w+){0,2}|zee music( company)?|zee5|sony music( india| entertainment)?|saregama( music)?|tips( official| music| industries)?|yrf|yash raj films|eros now( music)?|speed records|times music|aditya music|lahari music|think music( india)?|coke studio( pakistan| india| bangla| bharat)?|mtv(\s+\w+)?|vevo|universal music(\s+\w+){0,2}|warner (music|records)(\s+\w+){0,2}|atlantic records|republic records|columbia records|def jam(\s+\w+)?|island records|interscope( records)?|capitol records|rca records|epic records|hungama(\s+\w+)?|gaana|jiosaavn|spotify|apple music|netflix(\s+\w+){0,2}|amazon(\s+\w+){0,3}|(disney\+?\s*)?hotstar(\s+\w+)?|sonyliv|voot|alt balaji|shemaroo(\s+\w+){0,2}|venus(\s+(worldwide|entertainment|records|music|movies|regional))+|ultra\s+(music|records|bollywood|regional)(\s+\w+)?|wave music|desi music factory|white hill music|geet mp3|humble music|sky digital|yellow music|rhythm boyz"#
    // Generic channels — "Music", "Songs", "Hindi Songs", "Bollywood Music", "Punjabi Hits", "Lyrics", "Hindi" — are
    // never the artist either. The generic words only count on their own or beside a generic noun (songs, music,
    // hits, lyrics, videos, tv, channel), so "Hindi Zahra" and "Punjabi MC" stay artists.
    private static let genericChannel = #"((hindi|punjabi|bollywood|tamil|telugu|desi|indian|latest|new|old|top|best|all|hit|trending)\s+)*(songs?|music|hits|lyrics?|lyrical|videos?|tv|channel|gaane)(\s+(songs?|music|hits|lyrics?|lyrical|videos?|tv|channel|company|india|official))*(\s+\d{4})?|hindi|punjabi|bollywood"#
    private static let labelChannels = try! NSRegularExpression(pattern: "^(\(labelNames)|\(genericChannel))$", options: .caseInsensitive)
    // A title segment that is nothing but noise: "Official Video", "Lyric Video", "Lyrics", "Audio", "Visualizer", "HD",
    // "Season 14", "Episode 3", a bare year, "Out Now", "New Song 2024". The whole segment has to be noise — "Video Games"
    // is a song and "Audio Bullys" a band. Labels and generic channels are junk too; `looksLikeJunk` adds those.
    private static let junkSegment = try! NSRegularExpression(
        pattern: #"^\s*(official(\s+(music|lyric(al)?|full|hd|4k))?(\s+(video|audio|visuali[sz]er|song|trailer|teaser|promo))?|((full|hd|4k|new|latest)\s+)?((music|lyric(al)?|video|audio)\s+)?(video|audio|song|lyrics?|visuali[sz]er|trailer|teaser|promo)|hd|4k|hq|season\s*\d+|episode\s*\d+|ep\.?\s*\d+|\d{4}|out\s+now|new\s+(song|video)(\s+\d{4})?)\s*$"#,
        options: .caseInsensitive)

    private static func strip(_ re: NSRegularExpression, _ s: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
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

    /// "ArtistVEVO", "Artist - Topic", "Artist Official" → "Artist"; a label or a generic "Hindi Songs" channel → "".
    public static func cleanChannel(_ raw: String) -> String {
        var c = raw
        var previous = ""
        while previous != c {
            previous = c
            c = strip(channelNoise, c)
        }
        let cleaned = tidy(c)
        // Labels are checked as written and as stripped: "Speed Records" loses its " Records" above, and a bare
        // "Speed" could be a band.
        if matches(labelChannels, tidy(raw)) || matches(labelChannels, cleaned) { return "" }
        return cleaned
    }

    /// The first name of a collaboration: "A x B", "A ft. B", "A, B", "A & B" → "A".
    /// A band whose name is a list stays whole: "Simon & Garfunkel" ("&"/"and" after a lone word) and
    /// "Earth, Wind & Fire" / "Peter, Paul and Mary" (commas, then "&"/"and", every item a single word).
    /// Collaborations read differently — "Dua Lipa, Elton John & PNAU" has a two-word name — and still split.
    public static func primaryArtist(_ artist: String) -> String {
        let a = tidy(artist)
        let ns = a as NSString
        guard let m = artistSplit.firstMatch(in: a, range: NSRange(location: 0, length: ns.length)) else { return a }
        let head = tidy(ns.substring(to: m.range.location))
        let sep = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
        let rest = ns.substring(from: m.range.location + m.range.length)
        if (sep == "&" || sep == "and"), !head.contains(" ") { return a }   // Simon & Garfunkel
        if sep == ",", rest.range(of: #"\s(&|and)\s"#, options: [.regularExpression, .caseInsensitive]) != nil,
           split(a, on: bandListSplit).allSatisfy({ !$0.contains(" ") }) { return a }   // Earth, Wind & Fire
        return head.isEmpty ? a : head
    }

    /// The title cut at every separator: "Song (Official Video): Artist | Feat | Label" → 4 pieces.
    private static func split(_ title: String) -> [String] { split(title, on: separatorRegex) }

    private static func split(_ s: String, on re: NSRegularExpression) -> [String] {
        let ns = s as NSString
        var pieces: [String] = []
        var start = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            pieces.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = m.range.location + m.range.length
        }
        pieces.append(ns.substring(from: start))
        return pieces.map(tidy).filter { !$0.isEmpty }
    }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private static func looksLikeArtist(_ segment: String, channel: String) -> Bool {
        if !channel.isEmpty, sameName(segment, channel) { return true }
        return matches(artistSplit, segment)
    }

    /// Noise ("Official Video", "HD", "Season 14") or a label / generic channel name ("Coke Studio", "T-Series", "Lyrics").
    private static func looksLikeJunk(_ segment: String) -> Bool {
        matches(junkSegment, segment) || cleanChannel(segment).isEmpty
    }

    /// Ordered guesses, most likely first; at most four.
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

        // Artist "Song" (Official Video) / Adele 'Hello'
        let ns = title as NSString
        let whole = NSRange(location: 0, length: ns.length)
        if let m = doubleQuoted.firstMatch(in: title, range: whole) ?? singleQuoted.firstMatch(in: title, range: whole) {
            let before = tidy(ns.substring(with: m.range(at: 1)))
            let song = tidy(ns.substring(with: m.range(at: 2)))
            let after = tidy(ns.substring(with: m.range(at: 3)))
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
                // The channel as the artist — unless the piece is the channel itself, which makes it the artist, not the song.
                for piece in [second, first] where !sameName(piece, channel) { add(piece, channel) }
            }
        } else if !channel.isEmpty {
            add(title, channel)
        }
        if !title.isEmpty {
            // Free-text fallback: everything that's left, separators collapsed. Only kept when it fits in the four.
            var flat = title
            for sep in separators { flat = flat.replacingOccurrences(of: sep, with: " ") }
            add(flat, "")
        }

        var seen = Set<String>()
        return Array(out.filter { seen.insert("\($0.name)|\($0.artist)".lowercased()).inserted }.prefix(4))
    }
}
