import AppKit
import QuartzCore

// Offscreen QA of every lyric style. The layer tree is attached to a CARenderer BEFORE each line change,
// exactly like a layer in a window, so animations run as they would on screen. Every style is rendered in
// every font, one folder per font (FACES=serif,script limits the fonts).
let ROOT = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/allstyles"
nonisolated(unsafe) var OUT = ROOT
nonisolated(unsafe) var face = LyricsFont.defaultFont
nonisolated(unsafe) var tint = NSColor(srgbRed: 1, green: 0.89, blue: 0.4, alpha: 1)
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
    RenderContext(fontSize: size, color: tint,
                  wrapWidth: 2 * floor(min(max(size * 16, 320), 1200) / 2), scale: scale, face: face)
}

/// Lines that start and end on the glyphs that reach furthest past their box (Snell Roundhand's f and j
/// hooks, K and I tails), short enough for Dynamic to draw them at its largest.
let reachLyrics = SyncedLyrics(lines: [
    LyricLine(time: 0, text: "just fly"),
    LyricLine(time: 4, text: "fearless jazz I"),
    LyricLine(time: 8, text: "jif"),
    LyricLine(time: 12, text: "fall for it, K"),
    LyricLine(time: 16, text: "OK I"),
])

/// A right-to-left song: Karaoke's sweep and Glide's tape must come in from the right.
let urduLyrics = SyncedLyrics(lines: [
    LyricLine(time: 0, text: "دل کی بات زبان پر آئی"),
    LyricLine(time: 4, text: "رات بھر چاند ہمارے ساتھ رہا"),
    LyricLine(time: 8, text: "تم جو آئے تو شہر جاگ اٹھا"),
    LyricLine(time: 12, text: "خواب میں بھی تمہارا نام لیا"),
])

@MainActor func content(_ index: Int?, _ position: TimeInterval, playing: Bool = true, host: CFTimeInterval = CACurrentMediaTime(),
                        in song: SyncedLyrics = lyrics) -> StyleContent {
    .lyrics(LyricsState(id: "t", lyrics: song, index: index, clock: PlaybackClock(position: position, hostTime: host, playing: playing)))
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

/// Lyric ink outside the window would be cut off on screen. Renders the change with room around the window
/// and counts lyric-coloured pixels outside it, per frame; returns the worst frame's count.
@MainActor func inkOutsideWindow(_ style: LyricsStyle, from: (Int?, TimeInterval), to: (Int?, TimeInterval), times: [Double],
                                 in song: SyncedLyrics = lyrics) -> Int {
    let h = Host(style.makeRenderer())
    let before = h.show(content(from.0, from.1, in: song), advancing: false, ctx())
    let margin: CGFloat = 200
    let wrap = QuietLayer()
    wrap.bounds = CGRect(x: 0, y: 0, width: 1500, height: 1000)
    h.root.anchorPoint = .zero
    h.root.position = CGPoint(x: margin, y: margin)
    wrap.addSublayer(h.root)
    let off = Offscreen(wrap, width: Int(1500 * scale), height: Int(1000 * scale), scale: scale)
    var windows = [h.root.bounds]
    _ = h.show(content(to.0, to.1, in: song), advancing: true, ctx(), minSize: before)
    windows.append(h.root.bounds)
    CATransaction.flush()
    let t0 = CACurrentMediaTime()
    var worst = 0
    for t in times {
        let f = off.frame(at: t0 + t, path: nil)
        // The window during the change is at least as large as before (the app holds it), so the larger.
        let win = windows.reduce(CGRect.null) { $0.union($1) }
        let x0 = Int(margin * scale), y0 = Int(margin * scale)
        let x1 = x0 + Int(ceil(win.width * scale)), y1 = y0 + Int(ceil(win.height * scale))
        var outside = 0
        for y in 0..<f.h { for x in 0..<f.w where x < x0 || x >= x1 || y < y0 || y >= y1 {
            let i = (y * f.w + x) * 4
            if Int(f.px[i + 2]) - Int(f.px[i]) > 40 {      // BGRA: yellow-ish, not grey or shadow
                outside += 1
                if ProcessInfo.processInfo.environment["INK_DEBUG"] != nil, outside <= 3 {
                    print("  ink outside: t=\(t) px(\(x),\(y)) window px x\(x0)..<\(x1) y\(y0)..<\(y1) to=\(String(describing: to.0))")
                }
            }
        } }
        worst = max(worst, outside)
    }
    return worst
}

/// Hover previews switch style and font at any moment, mid-transition included. After a switch, the frame
/// must be exactly what a fresh renderer draws: nothing left behind, nothing stale.
@MainActor func switchesLeaveNothingBehind() {
    let w = Int(canvas.width * scale), h = Int(canvas.height * scale)
    let paused = { content(1, 5.0, playing: false) }
    func fresh(_ style: LyricsStyle, _ f: LyricsFont) -> Bitmap {
        face = f
        let host = Host(style.makeRenderer())
        let off = Offscreen(host.root, width: w, height: h, scale: scale)
        _ = host.show(paused(), advancing: false, ctx())
        return off.frame(at: CACurrentMediaTime() + 0.5, path: nil)
    }
    var bad: [String] = []
    for a in LyricsStyle.allCases {
        for b in LyricsStyle.allCases where b != a {
            face = .defaultFont
            let host = Host(a.makeRenderer())
            let off = Offscreen(host.root, width: w, height: h, scale: scale)
            _ = host.show(content(0, 3.9), advancing: false, ctx())
            _ = host.show(content(1, 4.0), advancing: true, ctx())      // A mid-transition…
            CATransaction.flush()
            _ = off.frame(at: CACurrentMediaTime() + 0.1, path: nil)
            host.swap(to: b.makeRenderer())                               // …hovered to B
            _ = host.show(paused(), advancing: false, ctx())
            let got = off.frame(at: CACurrentMediaTime() + 0.5, path: nil)
            if diff(got, fresh(b, .defaultFont)).over32 > 0 { bad.append("\(a.rawValue)→\(b.rawValue)") }
        }
        for f1 in LyricsFont.allCases {
            for f2 in LyricsFont.allCases where f2 != f1 {
                face = f1
                let host = Host(a.makeRenderer())
                let off = Offscreen(host.root, width: w, height: h, scale: scale)
                _ = host.show(content(0, 3.9), advancing: false, ctx())
                _ = host.show(content(1, 4.0), advancing: true, ctx())
                CATransaction.flush()
                _ = off.frame(at: CACurrentMediaTime() + 0.1, path: nil)
                face = f2                                                 // same style, font hovered
                _ = host.show(paused(), advancing: false, ctx())
                let got = off.frame(at: CACurrentMediaTime() + 0.5, path: nil)
                if diff(got, fresh(a, f2)).over32 > 0 { bad.append("\(a.rawValue):\(f1.rawValue)→\(f2.rawValue)") }
            }
        }
    }
    // Colour previews recolour whatever is on screen in place: it must match a fresh render in that colour.
    let mint = NSColor(srgbRed: 0.56, green: 0.94, blue: 0.78, alpha: 1), lemon = tint
    for s in LyricsStyle.allCases {
        face = .defaultFont
        tint = lemon
        let host = Host(s.makeRenderer())
        let off = Offscreen(host.root, width: w, height: h, scale: scale)
        _ = host.show(paused(), advancing: false, ctx())
        _ = off.frame(at: CACurrentMediaTime() + 0.1, path: nil)
        tint = mint
        host.r.recolor(context: ctx())
        let got = off.frame(at: CACurrentMediaTime() + 0.5, path: nil)
        if diff(got, fresh(s, .defaultFont)).over32 > 0 { bad.append("\(s.rawValue):recolour") }
        tint = lemon
    }
    face = .defaultFont
    check(bad.isEmpty, "style, font and colour switches match a fresh render (\(bad.count) mismatches: \(bad.prefix(8).joined(separator: ", ")))")
}

/// x centroid (points from the frame's left) of the fully lit lyric pixels: the sung part of a Karaoke line,
/// the current line in Glide. Dimmed text and the grey background are far darker in red.
func litCentroidX(_ f: Bitmap) -> Double? {
    var sum = 0.0, n = 0
    for y in 0..<f.h { for x in 0..<f.w {
        let i = (y * f.w + x) * 4                       // BGRA
        if f.px[i + 2] >= 235, f.px[i] <= 150 { sum += Double(x); n += 1 }
    } }
    return n == 0 ? nil : sum / Double(n) / Double(scale)
}

/// A right-to-left line (Urdu here) is read from the right, so Karaoke's sweep comes in from the right and
/// Glide's tape runs left to right; left-to-right lines keep their directions. (Jump and the other word
/// styles place words where the line's own layout put them, so they need nothing.)
@MainActor func readingDirection() {
    let w = Int(canvas.width * scale), h = Int(canvas.height * scale)
    let f = face.rawValue
    check(ctx().layout(urduLyrics.lines[1].text).isRightToLeft, "\(f): an Urdu line reads right to left")
    check(!ctx().layout(lyrics.lines[1].text).isRightToLeft, "\(f): a Latin line reads left to right")
    check(!ctx().layout(lyrics.lines[2].text).isRightToLeft, "\(f): a Devanagari line reads left to right")
    check(!ctx().layout("♪").isRightToLeft, "\(f): a lone ♪ counts as left to right")
    for (song, rtl, name) in [(urduLyrics, true, "urdu"), (lyrics, false, "latin")] {
        // Karaoke through line 1: early on, the lit part sits at the line's start; at the end all of it is lit.
        do {
            let host = Host(LyricsStyle.karaoke.makeRenderer())
            let off = Offscreen(host.root, width: w, height: h, scale: scale)
            let host0 = CACurrentMediaTime() + 0.05
            _ = host.show(content(1, 4.0, host: host0, in: song), advancing: false, ctx())
            CATransaction.flush()
            let frames = [0.1, 0.6, 1.4, 2.2, 3.0, 3.9].map { off.frame(at: host0 + $0, path: nil) }
            sheet(frames, path: "\(OUT)/karaoke_S5_\(name)_progress.png")
            let early = litCentroidX(frames[1]) ?? .nan, whole = litCentroidX(frames[5]) ?? .nan
            let d = (early - whole) * (rtl ? 1 : -1)
            check(d > 20, "\(f)/karaoke: \(name) sweep comes in from the \(rtl ? "right" : "left") (lit centroid \(Int(early)) early, \(Int(whole)) at the end)")
        }
        // Glide through line 1: the lit line moves left (tape right to left) or right (right-to-left song).
        do {
            let host = Host(LyricsStyle.glide.makeRenderer())
            let off = Offscreen(host.root, width: w, height: h, scale: scale)
            let host0 = CACurrentMediaTime() + 0.05
            _ = host.show(content(1, 4.3, host: host0, in: song), advancing: false, ctx())
            CATransaction.flush()
            let frames = [0.1, 0.9, 1.7, 2.5, 3.3].map { off.frame(at: host0 + $0, path: nil) }
            sheet(frames, path: "\(OUT)/glide_S5_\(name)_progress.png")
            let a = litCentroidX(frames[0]) ?? .nan, b = litCentroidX(frames[3]) ?? .nan
            let d = (b - a) * (rtl ? 1 : -1)
            check(d > 20, "\(f)/glide: \(name) tape glides \(rtl ? "left to right" : "right to left") (lit centroid \(Int(a)) → \(Int(b)))")
        }
    }
}

@MainActor func run() {
    let wanted = ProcessInfo.processInfo.environment["FACES"]?.split(separator: ",").map(String.init)
    for f in LyricsFont.allCases where wanted?.contains(f.rawValue) ?? true {
        face = f
        OUT = "\(ROOT)/\(f.rawValue)"
        try? FileManager.default.createDirectory(atPath: OUT, withIntermediateDirectories: true)
        // The real face, not the rounded fallback (rounded itself is the fallback, so it always passes).
        for w in [NSFont.Weight.heavy, .bold, .semibold, .medium] {
            let name = f.font(34, w).fontName
            let expected = ["rounded": "Rounded", "serif": "NewYork", "poster": "Futura-Condensed", "script": "SnellRoundhand",
                            "chic": "Optima", "retro": "Rockwell", "notebook": "Noteworthy"][f.rawValue]!
            check(name.contains(expected), "\(f.rawValue) weight \(w.rawValue) -> \(name)")
        }
        runStyles()
        readingDirection()
        for style in LyricsStyle.allCases {
            let counts = [
                inkOutsideWindow(style, from: (0, 3.9), to: (1, 4.0), times: [0, 0.03, 0.06, 0.1, 0.15, 0.2, 0.3, 0.45, 0.8, 2.0, 3.5]),
                inkOutsideWindow(style, from: (2, 11.9), to: (3, 12.0), times: [0, 0.05, 0.1, 0.2, 0.3, 0.5, 1.0, 2.0, 3.5]),
                inkOutsideWindow(style, from: (3, 15.9), to: (4, 16.0), times: [0, 0.05, 0.1, 0.2, 0.35, 0.8]),
                inkOutsideWindow(style, from: (4, 21.9), to: (5, 22.0), times: [0, 0.05, 0.1, 0.2, 0.35, 0.8, 2.0, 3.5]),
            ] + (0..<4).map { k in
                inkOutsideWindow(style, from: (k, Double(4 * k) + 3.9), to: (k + 1, Double(4 * k) + 4.0),
                                 times: [0, 0.05, 0.1, 0.2, 0.35, 0.8, 2.0, 3.5], in: reachLyrics)
            }
            let n = counts.max()!
            check(n == 0, "\(f.rawValue)/\(style.rawValue): no lyric ink outside the window (worst frame: \(n) px)")
        }
    }
    if ProcessInfo.processInfo.environment["FACES"] == nil { switchesLeaveNothingBehind() }
    print(failures == 0 ? "all checks passed" : "\(failures) check(s) FAILED")
}

@MainActor func runStyles() {
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
        print("rendered \(face.rawValue)/\(s)")
    }
}
MainActor.assumeIsolated { run() }
