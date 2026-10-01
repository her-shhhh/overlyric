import Foundation

/// One timed lyric line. `text` may be empty (an instrumental gap).
public struct LyricLine: Equatable, Sendable {
    public let time: TimeInterval
    public let text: String
    public init(time: TimeInterval, text: String) {
        self.time = time
        self.text = text
    }
}

/// A sorted list of timed lines with O(log n) lookup of the active line.
public struct SyncedLyrics: Equatable, Sendable {
    public let lines: [LyricLine]

    public init(lines: [LyricLine]) {
        // Stable sort by time (index as tie-breaker) so equal timestamps keep file order, then merge
        // lines that share a timestamp (duets / stacked lines) so none of them is skipped.
        let sorted = lines.enumerated()
            .sorted { a, b in a.element.time == b.element.time ? a.offset < b.offset : a.element.time < b.element.time }
            .map { $0.element }
        var merged: [LyricLine] = []
        for line in sorted {
            if let last = merged.last, last.time == line.time {
                let text = [last.text, line.text].filter { !$0.isEmpty }.joined(separator: "\n")
                merged[merged.count - 1] = LyricLine(time: last.time, text: text)
            } else {
                merged.append(line)
            }
        }
        self.lines = merged
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// Index of the line active at `t` (the last line whose time <= t), nil before the first line.
    public func currentIndex(at t: TimeInterval) -> Int? {
        var lo = 0
        var hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    public struct Window: Equatable, Sendable {
        public let current: Int?
        public let next: Int?
        public init(current: Int?, next: Int?) {
            self.current = current
            self.next = next
        }
    }

    /// The (current, next) pair to display at `t`.
    public func window(at t: TimeInterval) -> Window {
        guard !lines.isEmpty else { return Window(current: nil, next: nil) }
        let c = currentIndex(at: t)
        let n: Int?
        if let c {
            n = c + 1 < lines.count ? c + 1 : nil
        } else {
            n = 0
        }
        return Window(current: c, next: n)
    }

    public func text(at index: Int?) -> String? {
        guard let index, lines.indices.contains(index) else { return nil }
        return lines[index].text
    }
}
