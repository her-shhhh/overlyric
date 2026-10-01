import AppKit
import QuartzCore

// Offscreen QA of every lyric style. The layer tree is attached to a CARenderer BEFORE each line change,
// exactly like a layer in a window, so animations run as they would on screen.
let OUT = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/allstyles"
try? FileManager.default.createDirectory(atPath: OUT, withIntermediateDirectories: true)
let scale: CGFloat = 2
let canvas = CGSize(width: 760, height: 340)

let lyrics = SyncedLyrics(lines: [
    LyricLine(time: 0, text: "I don't wanna be alone tonight"),
    LyricLine(time: 4, text: "Hold me closer, tiny dancer"),
    LyricLine(time: 8, text: "मेरी अनकही सी तेरी अनसुनी सी बात है वही"),
    LyricLine(time: 12, text: "तेरी बातों से मेरी बातों की हसी"),
    LyricLine(time: 16, text: ""),
    LyricLine(time: 22, text: "Under city lights we dance"),
    LyricLine(time: 26, text: "Yeah"),
])

@MainActor func ctx(_ size: CGFloat = 34) -> RenderContext {
    RenderContext(fontSize: size, color: NSColor(srgbRed: 1, green: 0.89, blue: 0.4, alpha: 1),
                  wrapWidth: 2 * floor(min(max(size * 16, 320), 1200) / 2), scale: scale)
}

@MainActor func content(_ index: Int?, _ position: TimeInterval, playing: Bool = true, host: CFTimeInterval = CACurrentMediaTime()) -> StyleContent {
    .lyrics(LyricsState(id: "t", lyrics: lyrics, index: index, clock: PlaybackClock(position: position, hostTime: host, playing: playing)))
}

/// Static `from`, then (attached) advance to `to` and render frames at `times` after the change.
@MainActor func advance(_ style: LyricsStyle, _ name: String, from: (Int?, TimeInterval), to: (Int?, TimeInterval), times: [Double]) {
    let h = Host(style.makeRenderer())
    let before = h.show(content(from.0, from.1), advancing: false, ctx())
    let off = Offscreen(h.root, width: Int(canvas.width * scale), height: Int(canvas.height * scale), scale: scale)
    _ = h.show(content(to.0, to.1), advancing: true, ctx(), minSize: before)
    CATransaction.flush()
    let t0 = CACurrentMediaTime()
    sheet(times.map { off.frame(at: t0 + $0, path: nil) }, path: "\(OUT)/\(style.rawValue)_\(name).png")
}

@MainActor func run() {
    for style in LyricsStyle.allCases {
        let s = style.rawValue
        advance(style, "S1_latin_advance", from: (0, 3.9), to: (1, 4.0), times: [0, 0.03, 0.06, 0.1, 0.15, 0.2, 0.3, 0.45, 0.8])
        advance(style, "S2_hindi_advance", from: (2, 11.9), to: (3, 12.0), times: [0, 0.05, 0.1, 0.2, 0.3, 0.5, 1.0, 2.0, 3.5])
        advance(style, "S3a_into_gap", from: (3, 15.9), to: (4, 16.0), times: [0, 0.05, 0.1, 0.2, 0.35, 0.8])
        advance(style, "S3b_out_of_gap", from: (4, 21.9), to: (5, 22.0), times: [0, 0.05, 0.1, 0.2, 0.35, 0.8, 2.0])
        // Progress through a line while playing, then pause mid-line (must freeze).
        do {
            let h = Host(style.makeRenderer())
            let off = Offscreen(h.root, width: Int(canvas.width * scale), height: Int(canvas.height * scale), scale: scale)
            let host0 = CACurrentMediaTime() + 0.05
            _ = h.show(content(1, 4.0, host: host0), advancing: false, ctx())
            CATransaction.flush()
            sheet([0.1, 0.5, 1.0, 1.5, 2.2, 3.0, 3.8].map { off.frame(at: host0 + $0, path: nil) }, path: "\(OUT)/\(s)_S4_progress.png")
            h.r.retime(LyricsState(id: "t", lyrics: lyrics, index: 1, clock: PlaybackClock(position: 5.5, hostTime: CACurrentMediaTime(), playing: false)), context: ctx())
            CATransaction.flush()
            let now = CACurrentMediaTime()
            let a = off.frame(at: now + 0.1, path: "\(OUT)/\(s)_S4_paused.png")
            let b = off.frame(at: now + 3.1, path: nil)
            print("\(s): paused frames identical: \(diff(a, b).over32 == 0)")
        }
        print("rendered \(s)")
    }
}
MainActor.assumeIsolated { run() }
