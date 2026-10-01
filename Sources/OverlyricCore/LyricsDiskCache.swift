import Foundation

/// Stores fetched lyrics on disk so a song only ever has to be looked up once (survives relaunches and
/// keeps working when lrclib.net is slow or offline). Found lyrics are kept indefinitely; "no lyrics"
/// answers expire after `negativeLifetime` so newly added lyrics are picked up.
public struct LyricsDiskCache: Sendable {
    public enum Entry: Equatable { case found(String), notFound }

    public let directory: URL
    public let negativeLifetime: TimeInterval

    public init(directory: URL, negativeLifetime: TimeInterval = 2 * 24 * 3600) {
        self.directory = directory
        self.negativeLifetime = negativeLifetime
    }

    /// ~/Library/Caches/<bundle id>/lyrics
    public static func standard(bundleID: String) -> LyricsDiskCache {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return LyricsDiskCache(directory: base.appendingPathComponent(bundleID).appendingPathComponent("lyrics"))
    }

    private func file(for key: String) -> URL {
        // Keys are Spotify ids ("spotify:track:…") or "title|artist|duration"; make them filename-safe.
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return directory.appendingPathComponent(String(safe.prefix(180)) + ".lrc")
    }

    public func load(_ key: String, now: Date = Date()) -> Entry? {
        let url = file(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.isEmpty {
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            if now.timeIntervalSince(modified) > negativeLifetime {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return .notFound
        }
        return String(data: data, encoding: .utf8).map(Entry.found)
    }

    public func store(_ entry: Entry, for key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data: Data
        switch entry {
        case .found(let lrc): data = Data(lrc.utf8)
        case .notFound: data = Data()
        }
        try? data.write(to: file(for: key), options: .atomic)
    }
}
