import AppKit
import QuartzCore
import OverlyricCore

// MARK: - Glide

/// Instagram's "Dynamic Lyrics: Glide": the song as one row of text — line • line • line — gliding right
/// to left through a fixed-width, one-line ticker whose edges fade out.
///
/// Every line owns a stretch of that tape: its text plus half a separator on either side. While the line
/// is sung its stretch passes the ticker's centre at constant speed, so the line's centre crosses the
/// centre at the midpoint of its time, and the separator before the next line reaches the centre exactly
/// when that line starts. The strip's position is a pure function of playback time (`tapeX`), so a line
/// change, a pause or a seek re-derives it from the clock with nothing to reconcile, and in between one
/// linear animation per line runs on the compositor. The line being sung is bright, the rest dimmed.
/// Text layers exist only for the lines near the centre; the song's tape is measured once.
@MainActor final class GlideRenderer: BaseRenderer, StyleRenderer {
    /// One stretch of the tape: a lyric line, or the ♪ before the first line / after the last one.
    private struct Item {
        let text: String
        let start: TimeInterval      // its left separator is at the ticker centre at `start` …
        let end: TimeInterval        // … and its right one at `end`
        let left: CGFloat            // tape x of the separator centre before it
        let right: CGFloat           // tape x of the separator centre after it
        let metrics: Metrics         // the whole unwrapped line
    }

    private let viewport = QuietLayer()          // the ticker, in block coordinates, masked by `fade`
    private let fade = QuietGradientLayer()
    private let strip = QuietLayer()             // tape coordinates; position.x = −tapeX(now)
    private var note: TextLayer?                 // `.empty` / `.note` / no lines: one still, centred line

    private var items: [Item] = []
    private var lastLine = 0                     // item of the song's last line (the outro after it is never sung)
    private var tapeKey = ""
    private var separator = Metrics()            // "•"
    private var spacing: CGFloat = 0             // width of " • " (one separator cell)
    private var ascent: CGFloat = 0              // shared baseline, measured down from the row top
    private var rowHeight: CGFloat = 0
    private var tickerWidth: CGFloat = 0
    private var pixel: CGFloat = 0.5             // one device pixel, in points

    private var texts: [Int: [TextLayer]] = [:]  // item → its text layer(s) (very long lines are split)
    private var bullets: [Int: TextLayer] = [:]  // item → the separator before it
    private var current: Int?                    // the item being sung
    private var state: LyricsState?

    let transitionDuration: TimeInterval = 0.3
    private static let unwrapped: CGFloat = 100_000
    private static let edge: Double = 0.12
    private static let bulletAlpha: Float = 0.45

    override init() {
        super.init()
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, NSNumber(value: Self.edge), NSNumber(value: 1 - Self.edge), 1]
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        viewport.mask = fade
        viewport.anchorPoint = .zero
        viewport.addSublayer(strip)
        root.addSublayer(viewport)
    }

    // MARK: Showing

    func show(_ content: StyleContent, advancing: Bool, context ctx: RenderContext) -> CGSize {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if viewport.superlayer !== root { root.addSublayer(viewport) }
        guard case .lyrics(let st) = content, !st.lyrics.lines.isEmpty else { return showStill(content, ctx) }

        note?.isHidden = true
        viewport.isHidden = false
        let lines = st.lyrics.lines
        let key = "\(st.id)|\(ctx.fontSize)|\(ctx.face)|\(ctx.scale)|\(lines.count)|\(lines[0].time)|\(lines[lines.count - 1].time)"
        if key != tapeKey {
            buildTape(st, ctx)
            tapeKey = key
        }
        tickerWidth = min(ctx.wrapWidth, ctx.fontSize * 14)
        pixel = 1 / max(1, ctx.scale)
        let q = min(items.count - 1, (st.index ?? -1) + 1)
        let changed = current != nil && current != q
        current = q
        state = st
        syncPieces(around: q, ctx)
        highlight(animated: advancing && changed)
        let size = CGSize(width: tickerWidth, height: rowHeight)
        setBlockSize(size)
        let P = ctx.padding
        let r = CGRect(x: -size.width / 2, y: -size.height - P, width: size.width, height: size.height + 2 * P)
        viewport.bounds = r
        viewport.position = r.origin             // viewport coordinates = block coordinates
        fade.frame = r
        applyMotion(st)
        return size
    }

    /// No timed lines: a single still line in the middle (like the other styles).
    private func showStill(_ content: StyleContent, _ ctx: RenderContext) -> CGSize {
        dropPieces()
        strip.removeAllAnimations()
        current = nil
        state = nil
        viewport.isHidden = true
        let isNote: Bool
        let text: String
        if case .note(let s) = content { text = s; isNote = true } else { text = "♪"; isNote = false }
        let l = note ?? { let l = makeTextLayer(ctx) { $0.layout("") }; root.addSublayer(l); note = l; return l }()
        setText(l, ctx) { isNote ? $0.noteLayout(text) : $0.layout(text) }
        l.isHidden = false
        ctx.applyShadow(to: l)
        place(l, topCentre: .zero)
        let size = CGSize(width: max(l.layout.map(Self.inkWidth) ?? 0, 24), height: l.bounds.height)
        setBlockSize(size)
        return size
    }

    // MARK: The tape

    /// Lays the whole song out on one row (metrics only; layers are made lazily near the centre).
    private func buildTape(_ st: LyricsState, _ ctx: RenderContext) {
        dropPieces()
        current = nil
        let m = Measurer()
        separator = m.measure(ctx.attributed("•"))
        spacing = max(ctx.attributed(" • ").size().width, separator.width + ctx.fontSize * 0.3)
        let lines = st.lyrics.lines
        let first = st.start(0)
        var entries: [(text: String, start: TimeInterval, end: TimeInterval)] = [("♪", min(0, first - 2), first)]
        for i in lines.indices { entries.append((Self.tapeText(lines[i].text), st.start(i), st.end(i))) }
        if !lines[lines.count - 1].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let e = st.end(lines.count - 1)
            entries.append(("♪", e, e + 5))      // outro: only ever seen on the right, never sung
        }
        var x: CGFloat = 0
        var above = separator.baseline, below = separator.height - separator.baseline
        items = []
        items.reserveCapacity(entries.count)
        for e in entries {
            let metrics = m.measure(ctx.attributed(e.text))
            let right = x + spacing + metrics.width
            items.append(Item(text: e.text, start: e.start, end: max(e.end, e.start + 0.001), left: x, right: right, metrics: metrics))
            above = max(above, metrics.baseline)
            below = max(below, metrics.height - metrics.baseline)
            x = right
        }
        lastLine = lines.count
        // One baseline and one height for the whole song: the block never changes size between lines.
        ascent = above
        rowHeight = ceil(above + below)
    }

    /// The text shown for a line on the single row: stacked lines joined, gaps as ♪.
    private static func tapeText(_ raw: String) -> String {
        let parts = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "♪" : parts.joined(separator: " / ")
    }

    /// Rounds to whole device pixels: text at rest that is not on the pixel grid is resampled, and blurs.
    private func snap(_ v: CGFloat) -> CGFloat { (v / pixel).rounded() * pixel }

    /// Tape x at the ticker centre at playback time `t`, while item `k` is current.
    private func tapeX(_ k: Int, at t: TimeInterval) -> CGFloat {
        let it = items[k]
        let p = min(max((t - it.start) / (it.end - it.start), 0), 1)
        return it.left + (it.right - it.left) * CGFloat(p)
    }

    /// One linear move per line, from its left separator to its right one, timed from the clock. It carries
    /// on along the same mapping through the following line, so if the line change is handled late the
    /// strip is already where the next line's animation will take over (no stall, no jump).
    private func applyMotion(_ st: LyricsState) {
        guard let q = current, items.indices.contains(q) else { return }
        let it = items[q]
        strip.removeAnimation(forKey: "glide")
        let t = st.clock.playbackTime()
        guard st.clock.playing, t < it.end else {
            strip.position = CGPoint(x: snap(-tapeX(q, at: t)), y: 0)
            return
        }
        var stops: [(time: TimeInterval, x: CGFloat)] = [(it.start, it.left), (it.end, it.right)]
        if q < lastLine, items.indices.contains(q + 1) { stops.append((items[q + 1].end, items[q + 1].right)) }
        let span = stops[stops.count - 1].time - it.start
        strip.position = CGPoint(x: snap(-stops[stops.count - 1].x), y: 0)
        let a = CAKeyframeAnimation(keyPath: "position.x")
        a.values = stops.map { -$0.x }
        a.keyTimes = stops.map { NSNumber(value: ($0.time - it.start) / span) }
        a.calculationMode = .linear
        a.beginTime = strip.convertTime(st.clock.hostTime(of: it.start), from: nil)
        a.duration = span
        a.fillMode = .backwards
        strip.add(a, forKey: "glide")
    }

    // MARK: Layers

    /// Keeps text layers for every item that can enter the ticker while item `q` is current (and drops the
    /// rest). Anything added or dropped is beyond the faded edge at that moment, so nothing pops.
    private func syncPieces(around q: Int, _ ctx: RenderContext) {
        let reach = tickerWidth / 2 + ctx.fontSize
        let lo = items[q].left - reach, hi = items[q].right + reach
        var a = q, b = q
        while a > 0, items[a - 1].right > lo { a -= 1 }
        while b + 1 < items.count, items[b + 1].left < hi { b += 1 }
        let separators = max(1, a)...max(1, min(items.count - 1, b + 1))
        for k in Array(texts.keys) where k < a || k > b {
            texts.removeValue(forKey: k)?.forEach { forget($0) }
        }
        for k in Array(bullets.keys) where !separators.contains(k) {
            if let l = bullets.removeValue(forKey: k) { forget(l) }
        }
        for k in a...b where texts[k] == nil {
            let it = items[k]
            let left = it.left + spacing / 2
            texts[k] = segments(of: it, ctx).map { piece($0.text, left: left + $0.offset, metrics: $0.metrics, ctx) }
        }
        for k in separators where bullets[k] == nil && k < items.count {
            let l = piece("•", left: items[k].left - separator.width / 2, metrics: separator, ctx)
            l.opacity = Self.bulletAlpha
            bullets[k] = l
        }
    }

    /// A text layer for an unwrapped piece of the tape: its first glyph starts at tape x `left` and its
    /// baseline sits on the row's shared baseline. Laid out wider than its text so it never wraps.
    private func piece(_ text: String, left: CGFloat, metrics: Metrics, _ ctx: RenderContext) -> TextLayer {
        let width = ceil(metrics.width) + 2 * ceil(ctx.fontSize)
        let l = makeTextLayer(ctx) { $0.layout(text, width: width) }
        l.anchorPoint = CGPoint(x: 0, y: 1)
        // One centred line: its text starts (width − advance) / 2 into the layer.
        l.position = CGPoint(x: snap(left - (width - metrics.width) / 2), y: snap(metrics.baseline - ascent))
        l.opacity = RenderContext.dimAlpha
        ctx.applyShadow(to: l)
        strip.addSublayer(l)
        return l
    }

    /// A line is normally one layer; one wider than a bitmap comfortably allows is split between words.
    private func segments(of it: Item, _ ctx: RenderContext) -> [(text: String, offset: CGFloat, metrics: Metrics)] {
        let limit = max(ctx.fontSize * 4, 6000 / max(1, ctx.scale))
        guard it.metrics.width > limit else { return [(it.text, 0, it.metrics)] }
        let m = Measurer()
        let line = m.measure(ctx.attributed(it.text))
        let words = m.words()
        guard !words.isEmpty else { return [(it.text, 0, it.metrics)] }
        func span(_ i: Int, _ j: Int) -> NSRange {
            NSRange(location: words[i].location, length: NSMaxRange(words[j]) - words[i].location)
        }
        var chunks: [(range: NSRange, left: CGFloat)] = []
        var i = 0
        while i < words.count {
            var j = i
            while j + 1 < words.count, m.extent(span(i, j + 1)).width <= limit { j += 1 }
            chunks.append((span(i, j), m.extent(span(i, j)).minX))
            i = j + 1
        }
        let ns = it.text as NSString
        return chunks.map { chunk in
            let text = ns.substring(with: chunk.range)
            return (text, chunk.left - line.start, m.measure(ctx.attributed(text)))
        }
    }

    /// The line being sung is bright, the rest dimmed; on a line change the two cross-fade.
    private func highlight(animated: Bool) {
        for (k, layers) in texts {
            let target: Float = k == current ? 1 : RenderContext.dimAlpha
            for l in layers {
                let from = (l.presentation() ?? l).opacity
                l.removeAnimation(forKey: "glideHighlight")
                l.opacity = target
                guard animated, from != target else { continue }
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = from
                a.toValue = target
                a.duration = transitionDuration
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                l.add(a, forKey: "glideHighlight")
            }
        }
    }

    private func dropPieces() {
        for l in texts.values.joined() { forget(l) }
        for l in bullets.values { forget(l) }
        texts.removeAll()
        bullets.removeAll()
    }

    // MARK: StyleRenderer

    func retime(_ state: LyricsState, context: RenderContext) {
        guard let q = current, let shown = self.state, shown.id == state.id,
              min(items.count - 1, (state.index ?? -1) + 1) == q else { return }
        self.state = state
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyMotion(state)
        CATransaction.commit()
    }

    func recolor(context: RenderContext) { recolorRegistered(context) }

    override func applyShadows(_ context: RenderContext) {
        for l in texts.values.joined() { context.applyShadow(to: l) }
        for l in bullets.values { context.applyShadow(to: l) }
        if let note { context.applyShadow(to: note) }
    }

    /// Words of the line being sung where they are right now, limited to the unfaded middle of the ticker.
    func currentWords() -> [(text: String, rect: CGRect)] {
        guard let q = current, let st = state, let layers = texts[q] else {
            guard let note, !note.isHidden else { return [] }
            return wordsOf(note)
        }
        let dx = -tapeX(q, at: st.clock.playbackTime())
        let reach = tickerWidth * CGFloat(0.5 - Self.edge)
        var out: [(text: String, rect: CGRect)] = []
        for l in layers {
            for w in l.layout?.words ?? [] {
                let r = l.convert(w.rect, to: strip).offsetBy(dx: dx, dy: 0)
                if abs(r.midX) <= reach { out.append((w.text, r)) }
            }
        }
        return out
    }

    override func teardown() {
        super.teardown()
        strip.removeAllAnimations()
        strip.sublayers?.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
        texts.removeAll()
        bullets.removeAll()
        note = nil
        current = nil
        state = nil
        items.removeAll()
        tapeKey = ""
    }

    // MARK: Measuring

    /// TextKit metrics of one unwrapped line, laid out the way `TextLayout` lays it out. Horizontal extents
    /// are typeset (advances, not glyph boxes), so " • " spaces the tape exactly as typed text would.
    private struct Metrics {
        var start: CGFloat = 0       // left end of the text (container x), in either writing direction
        var width: CGFloat = 0       // advance width of the line
        var height: CGFloat = 0      // == TextLayout.size.height
        var baseline: CGFloat = 0    // from the top of the layout
    }

    /// One reusable TextKit stack at an unlimited width.
    @MainActor private final class Measurer {
        private let storage = NSTextStorage()
        private let manager = NSLayoutManager()
        private let container = NSTextContainer(size: NSSize(width: GlideRenderer.unwrapped, height: .greatestFiniteMagnitude))

        init() {
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
        }

        func measure(_ s: NSAttributedString) -> Metrics {
            storage.setAttributedString(s)
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            var m = Metrics(height: ceil(used.height) + 2, baseline: used.height * 0.8)
            let glyphs = manager.glyphRange(for: container)
            guard glyphs.length > 0 else { return m }
            let fragment = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            m.start = used.minX
            m.width = used.width
            m.baseline = fragment.minY + manager.location(forGlyphAt: glyphs.location).y
            return m
        }

        /// Character ranges of the words (runs of non-whitespace) of the last measured string.
        func words() -> [NSRange] {
            let s = storage.string
            let regex = try! NSRegularExpression(pattern: #"\S+"#)
            return regex.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).map(\.range)
        }

        /// Typeset extent of a character range of the last measured string: the union of its selection
        /// rects, which matches the range measured on its own (in any script and writing direction).
        func extent(_ characters: NSRange) -> CGRect {
            let glyphs = manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            var u = CGRect.null
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                            in: container) { r, _ in u = u.union(r) }
            return u.isNull ? .zero : u
        }
    }
}

/// A gradient layer without implicit animations (the ticker's edge fade).
private final class QuietGradientLayer: CAGradientLayer {
    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
    override func action(forKey event: String) -> CAAction? { nil }
}
