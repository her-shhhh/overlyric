import AppKit
import OverlyricCore

/// Downloads a track's cover art and extracts its theme colour (cached per track).
@MainActor
final class ArtworkColorService {
    private let session: URLSession
    private var cache: [String: RGB?] = [:]

    init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: c)
    }

    /// The lyric colour derived from the artwork, nil if the art is greyscale or unavailable.
    func textColor(trackKey: String, artworkURL: URL) async -> RGB? {
        if let cached = cache[trackKey] { return cached }
        var result: RGB?
        do {
            let (data, response) = try await session.data(from: artworkURL)
            if (response as? HTTPURLResponse)?.statusCode ?? 200 == 200, let image = NSImage(data: data),
               let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                if let theme = ArtworkColor.vibrant(Self.samplePixels(cg)) {
                    let text = ArtworkColor.textColor(from: theme)
                    result = text
                    Log.ui.notice("artwork colour for \(trackKey, privacy: .public): theme=(\(String(format: "%.2f %.2f %.2f", theme.r, theme.g, theme.b), privacy: .public)) → text=(\(String(format: "%.2f %.2f %.2f", text.r, text.g, text.b), privacy: .public))")
                } else {
                    Log.ui.notice("artwork colour for \(trackKey, privacy: .public): greyscale art, using default")
                }
            }
        } catch {
            Log.ui.error("artwork download failed: \(error.localizedDescription, privacy: .public)")
            return nil      // not cached: retry next time
        }
        cache[trackKey] = .some(result)
        return result
    }

    nonisolated private static func samplePixels(_ image: CGImage) -> [RGB] {
        let w = 40, h = 40
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return [] }
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var out: [RGB] = []
        out.reserveCapacity(w * h)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let a = Double(p[i + 3]) / 255
            guard a > 0.5 else { continue }
            out.append(RGB(r: min(1, Double(p[i]) / 255 / a), g: min(1, Double(p[i + 1]) / 255 / a), b: min(1, Double(p[i + 2]) / 255 / a)))
        }
        return out
    }
}
