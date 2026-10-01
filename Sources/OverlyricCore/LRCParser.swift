import Foundation

/// Parses LRC-formatted synced lyrics: `[mm:ss.xx]text`, `[mm:ss.xxx]text`, `[mm:ss:xx]text`,
/// multiple timestamps per line, enhanced-LRC word tags `<mm:ss.xx>` (stripped), metadata tags
/// like `[ar:…]` (ignored), CRLF line endings and `[offset:±ms]`.
public enum LRCParser {
    private static let tagPattern = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    private static let wordTagPattern = try! NSRegularExpression(pattern: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#)
    private static let offsetPattern = try! NSRegularExpression(pattern: #"^\[offset:\s*([+-]?\d+)\s*\]"#, options: .caseInsensitive)

    public static func parse(_ raw: String) -> SyncedLyrics? {
        var out: [LyricLine] = []
        var offset: TimeInterval = 0

        let cleaned = raw.replacingOccurrences(of: "\u{FEFF}", with: "")
        for rawLine in cleaned.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[") else { continue }
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)

            if let m = offsetPattern.firstMatch(in: line, range: full) {
                // LRC convention: positive offset shifts timestamps earlier.
                offset = -(Double(ns.substring(with: m.range(at: 1))) ?? 0) / 1000
                continue
            }

            let matches = tagPattern.matches(in: line, range: full)
            guard !matches.isEmpty else { continue }

            // Timestamps must be contiguous from the start of the line (whitespace between tags allowed).
            var cursor = 0
            var times: [TimeInterval] = []
            for m in matches {
                let gap = ns.substring(with: NSRange(location: cursor, length: max(0, m.range.location - cursor)))
                guard gap.trimmingCharacters(in: .whitespaces).isEmpty else { break }
                cursor = m.range.location + m.range.length
                guard let mm = Double(ns.substring(with: m.range(at: 1))),
                      let ss = Double(ns.substring(with: m.range(at: 2))) else { continue }
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let fs = ns.substring(with: m.range(at: 3))
                    frac = (Double(fs) ?? 0) / pow(10, Double(fs.count))
                }
                times.append(mm * 60 + ss + frac)
            }
            guard !times.isEmpty else { continue }

            var text = ns.substring(from: cursor)
            text = wordTagPattern.stringByReplacingMatches(
                in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            for t in times { out.append(LyricLine(time: t, text: text)) }
        }

        guard !out.isEmpty else { return nil }
        if offset != 0 { out = out.map { LyricLine(time: max(0, $0.time + offset), text: $0.text) } }
        return SyncedLyrics(lines: out)
    }
}
