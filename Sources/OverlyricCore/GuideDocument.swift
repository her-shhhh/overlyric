import Foundation

/// One block of the friends' guide, ready to be typeset.
public enum GuideBlock: Equatable, Sendable {
    case title(String)
    case heading(String, aside: String?)
    case paragraph(String)
    case bullet(String, level: Int)
    case numbered(Int, String)
}

/// Turns the friends' guide (Resources/friends-readme.txt: plain ASCII, wrapped at 72 columns) into blocks
/// for the in-app guide window. Headings are single UPPERCASE lines, optionally followed by "(an aside)";
/// list items start with "- " or "1. "; "   - " is a nested item; any other indented line continues the
/// item above; everything else is a paragraph whose lines are joined.
public enum GuideDocument {
    public static func parse(_ text: String) -> [GuideBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var groups: [[String]] = []
        var current: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { groups.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { groups.append(current) }

        var blocks: [GuideBlock] = []
        for (g, lines) in groups.enumerated() {
            if g == 0, lines.count == 1 {
                blocks.append(.title(lines[0].trimmingCharacters(in: .whitespaces)))
                continue
            }
            if lines.count == 1, let heading = heading(lines[0]) {
                blocks.append(heading)
                continue
            }
            blocks.append(contentsOf: listOrParagraph(lines))
        }
        return blocks
    }

    private static func heading(_ line: String) -> GuideBlock? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var main = trimmed
        var aside: String?
        if let open = trimmed.range(of: " ("), trimmed.hasSuffix(")") {
            main = String(trimmed[..<open.lowerBound])
            aside = String(trimmed[open.upperBound..<trimmed.index(before: trimmed.endIndex)])
        }
        let letters = main.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 3, letters.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }) else { return nil }
        let lower = main.lowercased()
        return .heading(lower.prefix(1).uppercased() + lower.dropFirst(), aside: aside)
    }

    private enum Item { case bullet(Int), numbered(Int) }

    private static func listOrParagraph(_ lines: [String]) -> [GuideBlock] {
        var out: [GuideBlock] = []
        var item: Item?
        var text = ""
        func flush() {
            guard !text.isEmpty else { return }
            switch item {
            case .bullet(let level)?: out.append(.bullet(text, level: level))
            case .numbered(let n)?: out.append(.numbered(n, text))
            case nil: out.append(.paragraph(text))
            }
            text = ""
        }
        for raw in lines {
            let indent = raw.prefix { $0 == " " }.count
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") {
                flush()
                item = .bullet(indent > 0 ? 1 : 0)
                text = String(line.dropFirst(2))
            } else if indent == 0, let dot = line.firstIndex(of: "."), let n = Int(line[..<dot]),
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                item = .numbered(n)
                text = String(line[line.index(dot, offsetBy: 2)...])
            } else if text.isEmpty {
                item = nil
                text = line
            } else {
                text += " " + line
            }
        }
        flush()
        return out
    }
}

/// Small typographic polish for text written in plain ASCII.
public enum Typography {
    public static func prettify(_ s: String) -> String {
        var t = s.replacingOccurrences(of: " - ", with: " \u{2014} ")
            .replacingOccurrences(of: " > ", with: " \u{203A} ")
            .replacingOccurrences(of: "'", with: "\u{2019}")
        t = t.replacingOccurrences(of: #"\bCmd\b"#, with: "\u{2318}", options: .regularExpression)
        var open = true
        var result = ""
        for ch in t {
            if ch == "\"" {
                result.append(open ? "\u{201C}" : "\u{201D}")
                open.toggle()
            } else {
                result.append(ch)
            }
        }
        return result
    }
}
