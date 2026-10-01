import AppKit
import QuartzCore
import OverlyricCore

// MARK: - Reveal mask (typewriter characters / karaoke sweep)

/// A mask for a `TextLayout` that uncovers it over time, visual line by visual line: either character by
/// character (discrete, typewriter) or as a smooth left-to-right sweep (karaoke). Runs entirely on the
/// compositor; `apply` re-times it for the current clock.
@MainActor final class RevealMask {
    let mask = QuietLayer()
    private var bars: [QuietLayer] = []
    private let layout: TextLayout
    private let slack: CGFloat

    init(layout: TextLayout, slack: CGFloat) {
        self.layout = layout
        self.slack = slack
        mask.frame = CGRect(origin: .zero, size: layout.size)
        for f in layout.fragments {
            let bar = QuietLayer()
            bar.backgroundColor = NSColor.black.cgColor
            bar.anchorPoint = CGPoint(x: 0, y: 0.5)
            bar.bounds = CGRect(x: 0, y: 0, width: 0, height: f.rect.height + 2 * slack)
            bar.position = CGPoint(x: f.rect.minX - slack, y: f.rect.midY)
            mask.addSublayer(bar)
            bars.append(bar)
        }
    }

    private var characterCount: Int { max(1, layout.characterStops.count) }

    /// Width of bar `j` once character `k` (global index) is revealed.
    private func width(bar j: Int, upTo k: Int) -> CGFloat {
        let f = layout.fragments[j]
        let stops = layout.characterStops
        guard k >= 0, !stops.isEmpty else { return 0 }
        let stop = stops[min(k, stops.count - 1)]
        if stop.fragment < j { return 0 }
        if stop.fragment > j { return f.rect.width + 2 * slack }
        return max(0, stop.x - (f.rect.minX - slack)) + 1
    }

    private func fullWidth(_ j: Int) -> CGFloat { layout.fragments[j].rect.width + 2 * slack }

    /// Character range of each bar as global indices (first, last).
    private func range(of j: Int) -> (Int, Int)? {
        let idx = layout.characterStops.indices.filter { layout.characterStops[$0].fragment == j }
        guard let a = idx.first, let b = idx.last else { return nil }
        return (a, b)
    }

    /// Reveals over `[start, start + duration]` (host time). `progress` = fixed state when paused.
    func apply(start: CFTimeInterval, duration: TimeInterval, discrete: Bool, pausedProgress: Double?) {
        let N = characterCount
        let D = max(0.05, duration)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (j, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            let full = fullWidth(j)
            if let p = pausedProgress {
                let revealed = Int((Double(N) * min(max(p, 0), 1)).rounded(.down))   // chars shown
                let w: CGFloat
                if discrete {
                    w = revealed <= 0 ? 0 : width(bar: j, upTo: revealed - 1)
                } else {
                    w = continuousWidth(bar: j, progress: p)
                }
                bar.bounds.size.width = min(full, w)
                continue
            }
            bar.bounds.size.width = full
            guard let (a, b) = range(of: j) else { continue }
            let anim = CAKeyframeAnimation(keyPath: "bounds.size.width")
            if discrete {
                var values: [CGFloat] = [0]
                var times: [NSNumber] = [0]
                for k in a...b {
                    times.append(NSNumber(value: Double(k) / Double(N)))
                    values.append(width(bar: j, upTo: k))
                }
                values[values.count - 1] = full
                times.append(1)
                anim.calculationMode = .discrete
                anim.values = values
                anim.keyTimes = times
            } else {
                let t0 = Double(a) / Double(N), t1 = Double(b + 1) / Double(N)
                anim.calculationMode = .linear
                anim.values = [0, 0, full, full]
                anim.keyTimes = [0, NSNumber(value: t0), NSNumber(value: max(t0, t1)), 1]
            }
            anim.beginTime = bar.convertTime(start, from: nil)
            anim.duration = D
            anim.fillMode = .both
            anim.isRemovedOnCompletion = false
            bar.add(anim, forKey: "reveal")
        }
        CATransaction.commit()
    }

    private func continuousWidth(bar j: Int, progress p: Double) -> CGFloat {
        guard let (a, b) = range(of: j) else { return 0 }
        let N = Double(characterCount)
        let t0 = Double(a) / N, t1 = Double(b + 1) / N
        if p <= t0 { return 0 }
        if p >= t1 { return fullWidth(j) }
        return fullWidth(j) * CGFloat((p - t0) / (t1 - t0))
    }
}

/// Timing of the reveal of line `i`.
private func revealTiming(_ st: LyricsState, _ i: Int, characters: Int, perCharacter: Double, fraction: Double) -> (start: TimeInterval, duration: TimeInterval) {
    let s = st.start(i), e = st.end(i)
    let span = max(0.2, (e - s) * fraction)
    return (s, min(span, max(0.25, Double(characters) * perCharacter)))
}

// MARK: - Typewriter

/// The line types itself out, character by character, at the pace it is sung.
@MainActor final class TypewriterRenderer: BaseRenderer, StyleRenderer {
    private var group: QuietLayer?
    private var text: TextLayer?
    private var reveal: RevealMask?
    private var ghosts: [CALayer] = []
    private var lineIndex: Int?
    let transitionDuration: TimeInterval = 0.32

    func show(_ content: StyleContent, advancing: Bool, context ctx: RenderContext) -> CGSize {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for g in ghosts { g.removeFromSuperlayer() }
        ghosts.removeAll()
        if advancing, let old = group {
            old.removeAllAnimations()
            ghosts.append(old)                          // keep it on screen as the outgoing line
        } else {
            group?.removeFromSuperlayer()
        }
        if let t = text { forget(t) }

        let g = QuietLayer()
        g.anchorPoint = CGPoint(x: 0.5, y: 1)
        g.position = .zero
        ctx.applyShadow(to: g)
        root.addSublayer(g)
        group = g

        var timed: (LyricsState, Int)?
        let layoutText: (RenderContext) -> TextLayout
        switch content {
        case .empty: layoutText = { $0.layout("♪") }
        case .note(let s): layoutText = { $0.noteLayout(s) }
        case .lyrics(let st):
            let raw = st.text(st.index)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let i = st.index, !raw.isEmpty {
                timed = (st, i)
                layoutText = { $0.layout(raw, typewriter: true) }
            } else {
                layoutText = { $0.layout("♪") }
            }
        }
        let t = makeTextLayer(ctx, layoutText)
        t.anchorPoint = CGPoint(x: 0.5, y: 1)
        t.position = .zero
        g.addSublayer(t)
        text = t
        lineIndex = timed?.1
        reveal = nil
        if let (st, _) = timed, let layout = t.layout {
            let r = RevealMask(layout: layout, slack: ctx.shadowRadius)
            t.mask = r.mask
            reveal = r
            applyTiming(st)
        }
        let size = CGSize(width: max(Self.inkWidth(t.layout!), 24), height: t.bounds.height)
        setBlockSize(size)
        CATransaction.commit()

        if advancing {
            let travel = ctx.fontSize * 0.45
            for old in ghosts {
                let s = old.position
                animate(old, from: (s, 1, 1), to: (CGPoint(x: s.x, y: s.y + travel), 0.96, 0), duration: transitionDuration) { [weak self, weak old] in
                    old?.removeFromSuperlayer()
                    if let old { self?.ghosts.removeAll { $0 === old } }
                }
            }
        }
        return size
    }

    private func applyTiming(_ st: LyricsState) {
        guard let reveal, let i = lineIndex, let layout = text?.layout else { return }
        let n = layout.characterStops.count
        let (s, d) = revealTiming(st, i, characters: n, perCharacter: 0.085, fraction: 0.85)
        if st.clock.playing {
            reveal.apply(start: st.clock.hostTime(of: s), duration: d, discrete: true, pausedProgress: nil)
        } else {
            reveal.apply(start: 0, duration: d, discrete: true, pausedProgress: (st.clock.position - s) / d)
        }
    }

    func retime(_ state: LyricsState, context: RenderContext) {
        guard state.index == lineIndex else { return }
        applyTiming(state)
    }

    func recolor(context: RenderContext) { recolorRegistered(context) }
    override func applyShadows(_ context: RenderContext) {
        if let group { context.applyShadow(to: group) }
        for g in ghosts { context.applyShadow(to: g) }
    }
    func currentWords() -> [(text: String, rect: CGRect)] { text.map(wordsOf) ?? [] }
    override func teardown() { super.teardown(); group = nil; text = nil; reveal = nil; ghosts.removeAll() }
}

// MARK: - Karaoke

/// The current line sits dimmed and lights up left to right as it is sung; the next line waits below.
@MainActor final class KaraokeRenderer: BaseRenderer, StyleRenderer {
    private var currentGroup: QuietLayer?
    private var bright: TextLayer?
    private var dim: TextLayer?
    private var next: TextLayer?
    private var sweep: RevealMask?
    private var ghosts: [CALayer] = []
    private var lineIndex: Int?
    let transitionDuration: TimeInterval = 0.42

    func show(_ content: StyleContent, advancing: Bool, context ctx: RenderContext) -> CGSize {
        let pair = LinePair(content, withNext: true)
        let W = ctx.wrapWidth, WN = W / RenderContext.nextScale
        let gap = ctx.fontSize * 0.2
        let travel = ctx.fontSize * 0.45
        let oldNextTop = (next?.presentation() ?? next)?.position
        let oldNextVisible = next.map { !$0.isHidden } ?? false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for g in ghosts { g.removeFromSuperlayer() }
        ghosts.removeAll()
        if advancing, let old = currentGroup {
            old.removeAllAnimations()
            // The outgoing line leaves fully lit.
            bright?.mask = nil
            ghosts.append(old)
        } else {
            currentGroup?.removeFromSuperlayer()
        }
        for l in [bright, dim].compactMap({ $0 }) { forget(l) }
        bright = nil; dim = nil; sweep = nil

        var timed: (LyricsState, Int)?
        if case .lyrics(let st) = content, let i = st.index,
           !(st.text(i) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            timed = (st, i)
        }
        lineIndex = timed?.1

        let g = QuietLayer()
        g.anchorPoint = CGPoint(x: 0.5, y: 1)
        ctx.applyShadow(to: g)
        root.addSublayer(g)
        currentGroup = g
        let curText = pair.current, isNote = pair.isNote
        let d = makeTextLayer(ctx) { c in
            isNote ? c.noteLayout(curText) : TextLayout(c.attributed(curText, alpha: timed == nil ? 1 : 0.42), width: W)
        }
        d.anchorPoint = CGPoint(x: 0.5, y: 1); d.position = .zero
        g.addSublayer(d)
        dim = d
        if let (st, _) = timed {
            let b = makeTextLayer(ctx) { $0.layout(curText, width: W) }
            b.anchorPoint = CGPoint(x: 0.5, y: 1); b.position = .zero
            g.addSublayer(b)
            bright = b
            let m = RevealMask(layout: b.layout!, slack: 2)
            b.mask = m.mask
            sweep = m
            applyTiming(st)
        }

        let nxt = next ?? { let l = makeTextLayer(ctx) { $0.layout("") }; root.addSublayer(l); next = l; return l }()
        nxt.removeAllAnimations()
        if let nextText = pair.next { setText(nxt, ctx) { $0.layout(nextText, width: WN) } }
        nxt.isHidden = pair.next == nil
        ctx.applyShadow(to: nxt)

        let hC = d.bounds.height
        let visualN = pair.next == nil ? 0 : nxt.bounds.height * RenderContext.nextScale
        let nextTop = CGPoint(x: 0, y: -(hC + gap))
        place(g, topCentre: .zero)
        place(nxt, topCentre: nextTop, scale: RenderContext.nextScale, opacity: RenderContext.dimAlpha)
        let width = max(Self.inkWidth(d.layout!), pair.next == nil ? 0 : Self.inkWidth(nxt.layout!) * RenderContext.nextScale, 24)
        let size = CGSize(width: width, height: hC + (pair.next == nil ? 0 : gap + visualN))
        setBlockSize(size)
        CATransaction.commit()

        guard advancing else { return size }
        let dur = transitionDuration
        for old in ghosts {
            let s = old.position
            animate(old, from: (s, 1, 1), to: (CGPoint(x: s.x, y: s.y + travel), 0.94, 0), duration: dur) { [weak self, weak old] in
                old?.removeFromSuperlayer()
                if let old { self?.ghosts.removeAll { $0 === old } }
            }
        }
        let riseFrom = oldNextVisible ? (oldNextTop ?? CGPoint(x: 0, y: -travel)) : CGPoint(x: 0, y: -travel)
        animate(g, from: (riseFrom, RenderContext.nextScale, RenderContext.dimAlpha), to: (.zero, 1, 1), duration: dur)
        if pair.next != nil {
            animate(nxt, from: (CGPoint(x: 0, y: nextTop.y - travel * 0.7), RenderContext.nextScale * 0.92, 0),
                    to: (nextTop, RenderContext.nextScale, RenderContext.dimAlpha), duration: dur)
        }
        return size
    }

    private func applyTiming(_ st: LyricsState) {
        guard let sweep, let i = lineIndex else { return }
        let s = st.start(i)
        let d = max(0.3, (st.end(i) - s) * 0.92)
        if st.clock.playing {
            sweep.apply(start: st.clock.hostTime(of: s), duration: d, discrete: false, pausedProgress: nil)
        } else {
            sweep.apply(start: 0, duration: d, discrete: false, pausedProgress: (st.clock.position - s) / d)
        }
    }

    func retime(_ state: LyricsState, context: RenderContext) {
        guard state.index == lineIndex else { return }
        applyTiming(state)
    }

    func recolor(context: RenderContext) { recolorRegistered(context) }
    override func applyShadows(_ context: RenderContext) {
        for l in [currentGroup, next].compactMap({ $0 }) as [CALayer] + ghosts { context.applyShadow(to: l) }
    }
    func currentWords() -> [(text: String, rect: CGRect)] { (bright ?? dim).map(wordsOf) ?? [] }
    override func teardown() {
        super.teardown()
        currentGroup = nil; bright = nil; dim = nil; next = nil; sweep = nil; ghosts.removeAll()
    }
}

// MARK: - Dynamic

/// Instagram-style kinetic type: the line is broken into short rows, each row sized to fill the width,
/// and the words pop in one by one as they are sung.
@MainActor final class DynamicRenderer: BaseRenderer, StyleRenderer {
    private struct PlacedWord { let layer: TextLayer; let at: TimeInterval }
    private var block: QuietLayer?
    private var words: [PlacedWord] = []
    private var ghosts: [CALayer] = []
    private var lineIndex: Int?
    let transitionDuration: TimeInterval = 0.32

    func show(_ content: StyleContent, advancing: Bool, context ctx: RenderContext) -> CGSize {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for g in ghosts { g.removeFromSuperlayer() }
        ghosts.removeAll()
        if advancing, let old = block {
            old.removeAllAnimations()
            ghosts.append(old)
        } else {
            block?.removeFromSuperlayer()
        }
        for w in words { forget(w.layer) }
        words.removeAll()

        let b = QuietLayer()
        b.anchorPoint = CGPoint(x: 0.5, y: 1)
        b.position = .zero
        ctx.applyShadow(to: b)
        root.addSublayer(b)
        block = b

        var size = CGSize(width: 24, height: ctx.fontSize)
        lineIndex = nil
        switch content {
        case .empty, .note:
            let isNote: Bool
            let text: String
            if case .note(let s) = content { text = s; isNote = true } else { text = "♪"; isNote = false }
            let l = makeTextLayer(ctx) { isNote ? $0.noteLayout(text) : $0.layout(text) }
            l.anchorPoint = CGPoint(x: 0.5, y: 1); l.position = .zero
            b.addSublayer(l)
            words = [PlacedWord(layer: l, at: -.infinity)]
            size = CGSize(width: max(Self.inkWidth(l.layout!), 24), height: l.bounds.height)
        case .lyrics(let st):
            let raw = st.text(st.index)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let i = st.index, !raw.isEmpty {
                lineIndex = i
                size = layoutRows(raw, st: st, line: i, in: b, ctx: ctx)
                applyTiming(st)
            } else {
                let l = makeTextLayer(ctx) { $0.layout("♪") }
                l.anchorPoint = CGPoint(x: 0.5, y: 1); l.position = .zero
                b.addSublayer(l)
                words = [PlacedWord(layer: l, at: -.infinity)]
                size = CGSize(width: max(Self.inkWidth(l.layout!), 24), height: l.bounds.height)
            }
        }
        setBlockSize(size)
        CATransaction.commit()

        if advancing {
            for old in ghosts {
                let s = old.position
                animate(old, from: (s, 1, 1), to: (CGPoint(x: s.x, y: s.y + ctx.fontSize * 0.3), 0.85, 0), duration: transitionDuration) { [weak self, weak old] in
                    old?.removeFromSuperlayer()
                    if let old { self?.ghosts.removeAll { $0 === old } }
                }
            }
        }
        return size
    }

    /// Breaks the line into rows of ≤ ~12 characters, sizes each row to the target width, places words.
    private func layoutRows(_ text: String, st: LyricsState, line i: Int, in b: CALayer, ctx: RenderContext) -> CGSize {
        let S = ctx.fontSize
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        var rows: [[String]] = []
        var row: [String] = []
        for t in tokens {
            let len = (row + [t]).joined(separator: " ").count
            if !row.isEmpty, len > 12 { rows.append(row); row = [t] } else { row.append(t) }
        }
        if !row.isEmpty { rows.append(row) }

        let target = min(ctx.wrapWidth, S * 8.5)
        let totalChars = max(1, tokens.reduce(0) { $0 + $1.count + 1 })
        let s = st.start(i)
        let span = min(max(0.3, (st.end(i) - s) * 0.8), Double(tokens.count) * 0.5)
        var charsBefore = 0
        var y: CGFloat = 0
        var maxWidth: CGFloat = 0
        for (r, words) in rows.enumerated() {
            // Natural width at the base size decides how much this row is scaled up or down.
            let natural = ctx.attributed(words.joined(separator: " "), size: S).size().width
            let size = min(S * 1.9, max(S * 0.75, S * target / max(1, natural)))
            let weight: NSFont.Weight = r % 2 == 0 ? .heavy : .bold
            let space = ctx.attributed(" ", size: size, weight: weight).size().width
            var layers: [(TextLayer, CGFloat)] = []
            var rowWidth: CGFloat = 0
            var rowHeight: CGFloat = 0
            for w in words {
                // Measure unwrapped, then lay the word out at exactly that width so the layer is tight.
                let ink = Self.inkWidth(ctx.layout(w, size: size, weight: weight, width: 10_000)) + 2
                let l = makeTextLayer(ctx) { $0.layout(w, size: size, weight: weight, width: ink) }
                layers.append((l, ink))
                rowWidth += ink
                rowHeight = max(rowHeight, l.bounds.height)
            }
            rowWidth += space * CGFloat(max(0, words.count - 1))
            var x = -rowWidth / 2
            for (k, (l, ink)) in layers.enumerated() {
                l.anchorPoint = CGPoint(x: 0.5, y: 1)
                l.position = CGPoint(x: x + ink / 2, y: -y)
                b.addSublayer(l)
                let at = s + span * Double(charsBefore) / Double(totalChars)
                self.words.append(PlacedWord(layer: l, at: at))
                charsBefore += words[k].count + 1
                x += ink + space
            }
            y += rowHeight * 0.92
            maxWidth = max(maxWidth, rowWidth)
        }
        return CGSize(width: max(maxWidth, 24), height: max(y, S))
    }

    private func applyTiming(_ st: LyricsState) {
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for w in words {
            w.layer.removeAllAnimations()
            if !st.clock.playing {
                w.layer.opacity = st.clock.position >= w.at ? 1 : 0
                continue
            }
            let at = st.clock.hostTime(of: w.at)
            if at <= now - 0.3 { w.layer.opacity = 1; continue }      // already sung
            w.layer.opacity = 1
            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [0.4, 1.12, 1.0]
            pop.keyTimes = [0, 0.6, 1]
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1]
            fade.keyTimes = [0, 0.4, 1]
            let g = CAAnimationGroup()
            g.animations = [pop, fade]
            g.duration = 0.28
            g.beginTime = w.layer.convertTime(at, from: nil)
            g.fillMode = .backwards                            // invisible until its moment
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.layer.add(g, forKey: "pop")
        }
        CATransaction.commit()
    }

    func retime(_ state: LyricsState, context: RenderContext) {
        guard state.index == lineIndex, lineIndex != nil else { return }
        applyTiming(state)
    }

    func recolor(context: RenderContext) { recolorRegistered(context) }
    override func applyShadows(_ context: RenderContext) {
        if let block { context.applyShadow(to: block) }
        for g in ghosts { context.applyShadow(to: g) }
    }
    func currentWords() -> [(text: String, rect: CGRect)] {
        words.compactMap { w in
            guard let t = w.layer.layout?.words.first?.text else { return nil }
            return (t, w.layer.convert(w.layer.bounds, to: root))
        }
    }
    override func teardown() { super.teardown(); block = nil; words.removeAll(); ghosts.removeAll() }
}

// MARK: - Scrolling lyrics

/// The whole song as a column that drifts slowly upwards in time with the music; the line being sung is
/// bright, the rest dimmed, faded out at the top and bottom edges.
@MainActor final class ScrollRenderer: BaseRenderer, StyleRenderer {
    private let column = QuietLayer()
    private let fade = CAGradientLayer()
    private var lineLayers: [Int: TextLayer] = [:]
    private var heights: [CGFloat] = []
    private var tops: [CGFloat] = []           // line top relative to the column origin (≤ 0, downwards)
    private var cacheKey = ""
    private var lineIndex: Int?
    private var noteLayer: TextLayer?
    private var lastState: LyricsState?
    let transitionDuration: TimeInterval = 0.3

    override init() {
        super.init()
        root.addSublayer(column)
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, 0.2, 0.72, 1]
        fade.startPoint = CGPoint(x: 0.5, y: 1)
        fade.endPoint = CGPoint(x: 0.5, y: 0)
        fade.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
    }

    private var focusDepth: CGFloat = 0     // where the current line's top sits below the block top

    func show(_ content: StyleContent, advancing: Bool, context ctx: RenderContext) -> CGSize {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard case .lyrics(let st) = content else {
            // Notes / empty: a single centred line, no column.
            for (_, l) in lineLayers { forget(l) }
            lineLayers.removeAll(); cacheKey = ""; lineIndex = nil; lastState = nil
            column.isHidden = true
            root.mask = nil
            let isNote: Bool
            let text: String
            if case .note(let s) = content { text = s; isNote = true } else { text = "♪"; isNote = false }
            let l = noteLayer ?? { let l = makeTextLayer(ctx) { $0.noteLayout("") }; root.addSublayer(l); noteLayer = l; return l }()
            setText(l, ctx) { isNote ? $0.noteLayout(text) : $0.layout(text) }
            l.isHidden = false
            ctx.applyShadow(to: l)
            place(l, topCentre: .zero)
            let size = CGSize(width: max(Self.inkWidth(l.layout!), 24), height: l.bounds.height)
            setBlockSize(size)
            return size
        }
        noteLayer?.isHidden = true
        column.isHidden = false
        let S = ctx.fontSize, W = ctx.wrapWidth
        let gap = S * 0.28
        // Measure every line once per song / size (layouts are cheap; bitmaps are made lazily below).
        let key = "\(st.id)|\(S)|\(W)|\(st.lyrics.lines.count)"
        if key != cacheKey {
            for (_, l) in lineLayers { forget(l) }
            lineLayers.removeAll()
            heights = st.lyrics.lines.map { ctx.layout(RenderContext.displayText($0.text), width: W).size.height }
            tops = []
            var y: CGFloat = 0
            for h in heights { tops.append(-y); y += h + gap }
            cacheKey = key
        }
        lineIndex = st.index
        lastState = st
        focusDepth = S * 1.6
        let visibleHeight = S * 6.2

        // Keep layers only for lines near the current one.
        let i = st.index ?? -1
        let lo = max(0, i - 3), hi = min(st.lyrics.lines.count - 1, i + 7)
        for (k, l) in lineLayers where k < lo || k > hi { forget(l); lineLayers.removeValue(forKey: k) }
        var maxInk: CGFloat = 24
        if lo <= hi {
            for k in lo...hi {
                let text = RenderContext.displayText(st.lyrics.lines[k].text)
                let l = lineLayers[k] ?? {
                    let l = makeTextLayer(ctx) { $0.layout(text, width: W) }
                    column.addSublayer(l)
                    lineLayers[k] = l
                    return l
                }()
                l.anchorPoint = CGPoint(x: 0.5, y: 1)
                l.position = CGPoint(x: 0, y: tops[k])
                ctx.applyShadow(to: l)
                let target: Float = k == i ? 1 : (k < i ? 0.3 : 0.45)
                if advancing, l.opacity != target {
                    let o = CABasicAnimation(keyPath: "opacity")
                    o.fromValue = l.presentation()?.opacity ?? l.opacity
                    o.toValue = target
                    o.duration = transitionDuration
                    l.add(o, forKey: "highlight")
                }
                l.opacity = target
                if abs(k - i) <= 3 { maxInk = max(maxInk, Self.inkWidth(l.layout!)) }
            }
        }
        let size = CGSize(width: maxInk, height: visibleHeight)
        setBlockSize(size)
        fade.frame = root.bounds
        root.mask = fade
        applyDrift(st)
        return size
    }

    /// Column offset that puts line `k`'s top at the focus depth.
    private func offset(for k: Int) -> CGFloat {
        guard tops.indices.contains(k) else { return 0 }
        return -focusDepth - tops[k]
    }

    private func applyDrift(_ st: LyricsState) {
        column.removeAnimation(forKey: "drift")
        let count = st.lyrics.lines.count
        guard count > 0 else { return }
        guard let i = st.index else {
            // Before the first line: line 0 waits just below the focus point.
            column.position = CGPoint(x: 0, y: offset(for: 0) - (heights.first ?? 0) * 0.5)
            return
        }
        let from = offset(for: i)
        let to = i + 1 < count ? offset(for: i + 1) : from
        let s = st.start(i), e = st.end(i)
        let span = max(0.2, e - s)
        let p = min(max((st.clock.playbackTime() - s) / span, 0), 1)
        let current = from + (to - from) * CGFloat(p)
        guard st.clock.playing, p < 1 else {
            column.position = CGPoint(x: 0, y: current)
            return
        }
        column.position = CGPoint(x: 0, y: to)
        let a = CABasicAnimation(keyPath: "position.y")
        a.fromValue = current
        a.toValue = to
        a.duration = span * (1 - p)
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        column.add(a, forKey: "drift")
    }

    func retime(_ state: LyricsState, context: RenderContext) {
        guard state.index == lineIndex, lastState?.id == state.id else { return }
        lastState = state
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyDrift(state)
        CATransaction.commit()
    }

    func recolor(context: RenderContext) { recolorRegistered(context) }
    override func applyShadows(_ context: RenderContext) {
        for (_, l) in lineLayers { context.applyShadow(to: l) }
        if let noteLayer { context.applyShadow(to: noteLayer) }
    }
    func currentWords() -> [(text: String, rect: CGRect)] {
        guard let i = lineIndex, let l = lineLayers[i] else { return [] }
        return wordsOf(l)
    }
    override func teardown() {
        super.teardown()
        lineLayers.removeAll(); noteLayer = nil; cacheKey = ""; lastState = nil
        root.addSublayer(column)
    }
}
