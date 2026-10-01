import AppKit
import QuartzCore
import OverlyricCore

// MARK: - Line moves

/// Moves a line like `BaseRenderer.animate` (top-centre position, scale and opacity; the model is set to the
/// end state), but changes its opacity only within `fade`, a window of the move's eased progress: an
/// outgoing line can be gone before it reaches an edge, an incoming one can wait until the way is clear.
@MainActor private func moveLine(_ l: CALayer, from: (CGPoint, CGFloat, Float), to: (CGPoint, CGFloat, Float),
                                 duration: TimeInterval, fade: ClosedRange<Double> = 0...1,
                                 completion: (() -> Void)? = nil) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.setCompletionBlock(completion)
    l.position = to.0
    l.transform = CATransform3DMakeScale(to.1, to.1, 1)
    l.opacity = to.2
    let p = CABasicAnimation(keyPath: "position"); p.fromValue = NSValue(point: from.0); p.toValue = NSValue(point: to.0)
    let s = CABasicAnimation(keyPath: "transform.scale"); s.fromValue = from.1; s.toValue = to.1
    let o = CAKeyframeAnimation(keyPath: "opacity")
    o.values = [from.2, from.2, to.2, to.2]
    o.keyTimes = [0, fade.lowerBound, fade.upperBound, 1].map { NSNumber(value: $0) }
    let g = CAAnimationGroup()
    g.animations = [p, s, o]
    g.duration = duration
    g.timingFunction = BaseRenderer.ease
    l.add(g, forKey: "styleMove")
    CATransaction.commit()
}

/// Lines on their way out. A ghost keeps its text layers, still registered so a recolour reaches them, until
/// its exit ends or a non-advancing show clears it.
@MainActor private final class Ghosts {
    private struct Ghost {
        let layer: CALayer
        let texts: [TextLayer]
        let shadowed: [CALayer]
    }

    private var all: [Ghost] = []
    private unowned let owner: BaseRenderer

    init(owner: BaseRenderer) { self.owner = owner }

    /// The ghosts' layers that carry a glyph shadow.
    var shadowed: [CALayer] { all.flatMap(\.shadowed) }

    /// Floats `layer` up by `rise` from wherever it is on screen right now, shrinking it by `scale` and fading
    /// it out within `fade` (of the move's eased progress), then drops it.
    func release(_ layer: CALayer, texts: [TextLayer], shadowed: [CALayer], rise: CGFloat, scale: CGFloat,
                 duration: TimeInterval, fade: ClosedRange<Double> = 0...0.5) {
        let now = layer.presentation() ?? layer
        let from = (now.position, now.transform.m11, now.opacity)
        layer.removeAllAnimations()
        all.append(Ghost(layer: layer, texts: texts, shadowed: shadowed))
        moveLine(layer, from: from, to: (CGPoint(x: from.0.x, y: from.0.y + rise), from.1 * scale, 0),
                 duration: duration, fade: fade) { [weak self, weak layer] in
            if let layer { self?.drop(layer) }
        }
    }

    func clear() {
        for g in all { remove(g) }
        all.removeAll()
    }

    private func drop(_ layer: CALayer) {
        guard let k = all.firstIndex(where: { $0.layer === layer }) else { return }
        remove(all.remove(at: k))
    }

    private func remove(_ g: Ghost) {
        for t in g.texts { owner.forget(t) }
        g.layer.removeAllAnimations()
        g.layer.removeFromSuperlayer()
    }
}

// MARK: - Reveal mask (typewriter characters / karaoke sweep)

/// A mask for a `TextLayout` that uncovers it over time, visual line by visual line: either character by
/// character (typewriter) or as a soft-edged left-to-right sweep (karaoke). Each visual line has a bar that
/// slides in from the left inside a clip around that line, so it never uncovers a neighbouring line. Runs
/// entirely on the compositor.
@MainActor private final class RevealMask {
    enum Style {
        case characters
        case sweep(feather: CGFloat)
    }

    let mask = QuietLayer()
    private let layout: TextLayout
    private let discrete: Bool
    private var bars: [CALayer] = []
    private var left: [CGFloat] = []                // x of each clip's left edge (layout coordinates)
    private var travel: [CGFloat] = []              // bar position once its line is fully uncovered
    private var ranges: [ClosedRange<Int>?] = []    // global character indices of each visual line
    private var blank: [Bool] = []                  // per character (characterStops order): whitespace

    /// `slack` = room around each visual line for ink that overhangs it.
    init(layout: TextLayout, style: Style, slack: CGFloat) {
        self.layout = layout
        let feather: CGFloat
        switch style {
        case .characters: discrete = true; feather = 0
        case .sweep(let f): discrete = false; feather = f
        }
        mask.frame = CGRect(origin: .zero, size: layout.size)
        let ns = layout.string.string as NSString
        for f in layout.fragments {
            var c = f.characterRange.location
            while c < NSMaxRange(f.characterRange) {
                let r = ns.rangeOfComposedCharacterSequence(at: c)
                blank.append(ns.substring(with: r).allSatisfy(\.isWhitespace))
                c = NSMaxRange(r)
            }
        }
        let stops = layout.characterStops
        let last = layout.fragments.count - 1
        for (j, f) in layout.fragments.enumerated() {
            let width = f.rect.width + 2 * slack
            // Up into the line above (already uncovered by then), but down only below the last line: never
            // into the next one, which is still to come.
            let top = f.rect.maxY + slack, bottom = f.rect.minY - (j == last ? slack : 0)
            let clip = QuietLayer()
            clip.masksToBounds = true
            clip.frame = CGRect(x: f.rect.minX - slack, y: bottom, width: width, height: top - bottom)
            let bar: CALayer
            if feather > 0 {
                let g = CAGradientLayer()
                g.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
                g.locations = [0, NSNumber(value: Double(width / (width + feather))), 1]
                g.startPoint = CGPoint(x: 0, y: 0.5)
                g.endPoint = CGPoint(x: 1, y: 0.5)
                bar = g
            } else {
                bar = QuietLayer()
                bar.backgroundColor = NSColor.black.cgColor
            }
            // position.x is the bar's leading edge: 0 hides the line, `travel` shows all of it.
            bar.anchorPoint = CGPoint(x: 1, y: 0)
            bar.bounds = CGRect(x: 0, y: 0, width: width + feather, height: top - bottom)
            bar.position = .zero
            clip.addSublayer(bar)
            mask.addSublayer(clip)
            bars.append(bar)
            left.append(f.rect.minX - slack)
            travel.append(width + feather)
            let idx = stops.indices.filter { stops[$0].fragment == j }
            ranges.append(idx.isEmpty ? nil : idx[0]...idx[idx.count - 1])
        }
    }

    private var characterCount: Int { max(1, layout.characterStops.count) }

    /// Leading edge of bar `j` once characters 0...k are uncovered. A space has no ink, so typing one keeps
    /// the edge where it was (moving it would bare the next word's first serif).
    private func edge(_ j: Int, through k: Int) -> CGFloat {
        guard let r = ranges[j] else { return 0 }
        if k >= r.upperBound { return travel[j] }        // the line's last character: all of it, overhangs too
        var k = k
        while k >= r.lowerBound, k < blank.count, blank[k] { k -= 1 }
        guard k >= r.lowerBound else { return 0 }
        return min(travel[j], max(0, layout.characterStops[k].x - left[j]))
    }

    /// Fraction of the reveal at which bar `j` starts and finishes (characters share the time equally).
    private func window(_ r: ClosedRange<Int>) -> (Double, Double) {
        let n = Double(characterCount)
        return (Double(r.lowerBound) / n, Double(r.upperBound + 1) / n)
    }

    /// Uncovers the text over [start, start + duration] (host time). Character k is done at (k+1)/N of it:
    /// swept by then, or typed in one step then.
    func play(from start: CFTimeInterval, duration: TimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (j, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            bar.position.x = travel[j]
            guard let r = ranges[j] else { continue }
            let a = CAKeyframeAnimation(keyPath: "position.x")
            if discrete {
                a.calculationMode = .discrete
                a.values = [0] + r.map { edge(j, through: $0) }
                a.keyTimes = ([0] + r.map { Double($0 + 1) / Double(characterCount) } + [1]).map { NSNumber(value: $0) }
            } else {
                let (t0, t1) = window(r)
                a.values = [0, 0, travel[j], travel[j]]
                a.keyTimes = [0, t0, t1, 1].map { NSNumber(value: $0) }
            }
            a.beginTime = bar.convertTime(start, from: nil)
            a.duration = max(0.05, duration)
            a.fillMode = .backwards
            bar.add(a, forKey: "reveal")
        }
        CATransaction.commit()
    }

    /// Shows the reveal standing still at `progress` (fraction of its duration), exactly as `play` shows it then.
    func freeze(at progress: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (j, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            guard let r = ranges[j] else { bar.position.x = travel[j]; continue }
            if discrete {
                let typed = Int(min(max(Double(characterCount) * progress, 0), Double(characterCount)))
                bar.position.x = edge(j, through: typed - 1)
            } else {
                let (t0, t1) = window(r)
                bar.position.x = travel[j] * CGFloat(min(max((progress - t0) / (t1 - t0), 0), 1))
            }
        }
        CATransaction.commit()
    }
}

// MARK: - Typewriter

/// The line types itself out, character by character, at the pace it is sung.
@MainActor final class TypewriterRenderer: BaseRenderer, StyleRenderer {
    private var group: QuietLayer?
    private var text: TextLayer?
    private var reveal: RevealMask?
    private lazy var ghosts = Ghosts(owner: self)
    private var lineIndex: Int?
    let transitionDuration: TimeInterval = 0.32

    func show(_ content: StyleContent, advancing: Bool, context ctx: RenderContext) -> CGSize {
        let leaving = advancing ? group : nil
        let leavingTexts = [text].compactMap { $0 }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !advancing {
            ghosts.clear()
            leavingTexts.forEach(forget)
            group?.removeFromSuperlayer()
        }

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
                layoutText = { c in
                    // A typewriter has no ligatures: every character is typed on its own.
                    let s = NSMutableAttributedString(attributedString: c.attributed(raw, typewriter: true))
                    s.addAttribute(.ligature, value: 0, range: NSRange(location: 0, length: s.length))
                    return TextLayout(s, width: c.wrapWidth)
                }
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
        if timed == nil, leaving != nil {
            // Nothing to type (♪ / a note): let the outgoing line clear first, then fade in.
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0
            a.toValue = 1
            a.beginTime = t.convertTime(CACurrentMediaTime(), from: nil) + 0.07
            a.duration = 0.22
            a.fillMode = .backwards
            t.add(a, forKey: "enter")
        }
        if let (st, _) = timed, let layout = t.layout {
            let r = RevealMask(layout: layout, style: .characters, slack: ctx.fontSize * 0.2)
            t.mask = r.mask
            reveal = r
            applyTiming(st)
        }
        let size = CGSize(width: max(Self.inkWidth(t.layout!), 24), height: t.bounds.height)
        setBlockSize(size)
        CATransaction.commit()

        if let leaving {
            ghosts.release(leaving, texts: leavingTexts, shadowed: [leaving], rise: ctx.fontSize * 0.45, scale: 0.96,
                           duration: transitionDuration)
        }
        return size
    }

    /// About 85 ms a character, within the first 85% of the line. The first character lands one step in,
    /// when the outgoing line has already faded from the same spot.
    private func applyTiming(_ st: LyricsState) {
        guard let reveal, let i = lineIndex, let layout = text?.layout else { return }
        let s = st.start(i)
        let d = min(max(0.2, (st.end(i) - s) * 0.85), max(0.25, Double(layout.characterStops.count) * 0.085))
        if st.clock.playing {
            reveal.play(from: st.clock.hostTime(of: s), duration: d)
        } else {
            reveal.freeze(at: (st.clock.position - s) / d)
        }
    }

    func retime(_ state: LyricsState, context: RenderContext) {
        guard state.index == lineIndex else { return }
        applyTiming(state)
    }

    func recolor(context: RenderContext) { recolorRegistered(context) }
    override func applyShadows(_ context: RenderContext) {
        if let group { context.applyShadow(to: group) }
        for l in ghosts.shadowed { context.applyShadow(to: l) }
    }
    func currentWords() -> [(text: String, rect: CGRect)] { text.map(wordsOf) ?? [] }
    override func teardown() {
        ghosts.clear()
        super.teardown()
        group = nil; text = nil; reveal = nil; lineIndex = nil
    }
}

// MARK: - Karaoke

/// The current line sits dimmed and lights up left to right as it is sung; the next line waits below. On a
/// line change everything scrolls up together: the preview grows into the current line in place.
@MainActor final class KaraokeRenderer: BaseRenderer, StyleRenderer {
    private var currentGroup: QuietLayer?
    private var dim: TextLayer?
    private var lit: QuietLayer?                // carries the lit copy's shadow (the copy itself is masked)
    private var bright: TextLayer?
    private var sweep: RevealMask?
    private var next: TextLayer?
    private var nextText: String?               // what the preview shows; nil = hidden
    private lazy var ghosts = Ghosts(owner: self)
    private var lineIndex: Int?
    let transitionDuration: TimeInterval = 0.42

    func show(_ content: StyleContent, advancing: Bool, context ctx: RenderContext) -> CGSize {
        let pair = LinePair(content, withNext: true)
        let W = ctx.wrapWidth
        let gap = ctx.fontSize * 0.2
        let travel = ctx.fontSize * 0.45
        let curText = pair.current, isNote = pair.isNote
        // The preview is laid out exactly as it will be as the current line, so the hand-off is a pure move.
        let newNext = pair.next.map { RenderContext.displayText($0) }
        let oldNext = nextText == nil ? nil : next.map { $0.presentation() ?? $0 }
        let promoted = advancing && oldNext != nil && nextText == curText
        let keptNext = advancing && !promoted && oldNext != nil && nextText == newNext
        let leaving = advancing ? currentGroup : nil
        let leavingTexts = [dim, bright].compactMap { $0 }
        let leavingShadowed: [CALayer] = [dim, lit].compactMap { $0 }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !advancing {
            ghosts.clear()
            leavingTexts.forEach(forget)
            currentGroup?.removeFromSuperlayer()
        }

        var timed: (LyricsState, Int)?
        if case .lyrics(let st) = content, let i = st.index,
           !(st.text(i) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            timed = (st, i)
        }
        lineIndex = timed?.1

        let g = QuietLayer()
        g.anchorPoint = CGPoint(x: 0.5, y: 1)
        root.addSublayer(g)
        currentGroup = g
        // The unsung line is dimmed by layer opacity, like the preview, so its shadow stays clean.
        let d = makeTextLayer(ctx) { isNote ? $0.noteLayout(curText) : $0.layout(curText, width: W) }
        d.anchorPoint = CGPoint(x: 0.5, y: 1)
        d.position = .zero
        d.opacity = timed == nil ? 1 : RenderContext.dimAlpha
        ctx.applyShadow(to: d)
        g.addSublayer(d)
        dim = d
        lit = nil; bright = nil; sweep = nil
        if let (st, _) = timed {
            let w = QuietLayer()
            ctx.applyShadow(to: w)
            g.addSublayer(w)
            let b = makeTextLayer(ctx) { $0.layout(curText, width: W) }
            b.anchorPoint = CGPoint(x: 0.5, y: 1)
            b.position = .zero
            w.addSublayer(b)
            let m = RevealMask(layout: b.layout!, style: .sweep(feather: ctx.fontSize * 0.35), slack: ctx.fontSize * 0.2)
            b.mask = m.mask
            lit = w; bright = b; sweep = m
            applyTiming(st)
        }

        let nxt = next ?? { let l = makeTextLayer(ctx) { $0.layout("") }; root.insertSublayer(l, at: 0); next = l; return l }()
        nxt.removeAllAnimations()
        if let newNext { setText(nxt, ctx) { $0.layout(newNext, width: W) } }
        nxt.isHidden = newNext == nil
        nextText = newNext
        ctx.applyShadow(to: nxt)

        let hC = d.bounds.height
        let nextTop = CGPoint(x: 0, y: -(hC + gap))
        place(g, topCentre: .zero)
        place(nxt, topCentre: nextTop, scale: RenderContext.nextScale, opacity: RenderContext.dimAlpha)
        let width = max(Self.inkWidth(d.layout!), newNext == nil ? 0 : Self.inkWidth(nxt.layout!) * RenderContext.nextScale, 24)
        let size = CGSize(width: width, height: hC + (newNext == nil ? 0 : gap + nxt.bounds.height * RenderContext.nextScale))
        setBlockSize(size)
        CATransaction.commit()

        guard advancing else { return size }
        let dur = transitionDuration
        // The current line grows out of the preview it was, or (nothing previewed) fades up into place.
        let from: (CGPoint, CGFloat, Float)
        if promoted, let p = oldNext {
            from = (p.position, p.transform.m11, min(1, p.opacity / RenderContext.dimAlpha))
        } else {
            from = (CGPoint(x: 0, y: -travel), 0.92, 0)
        }
        if let leaving {
            // The old line moves up at least as far as the line below it, so they never overlap, and is gone
            // before it reaches the top of the window.
            let below = promoted ? -from.0.y : keptNext ? nextTop.y - (oldNext?.position.y ?? nextTop.y) : 0
            let rise = max(travel, below)
            let clear = Double((ctx.padding - ctx.shadowRadius) / rise)
            ghosts.release(leaving, texts: leavingTexts, shadowed: leavingShadowed, rise: rise, scale: 0.94,
                           duration: dur, fade: 0...min(0.5, max(0.2, clear)))
        }
        moveLine(g, from: from, to: (.zero, 1, 1), duration: dur, fade: promoted ? 0...1 : 0.5...1)
        let s = RenderContext.nextScale, a = RenderContext.dimAlpha
        if keptNext, let p = oldNext {
            // Same preview: it only follows the new line's height.
            moveLine(nxt, from: (p.position, p.transform.m11, p.opacity), to: (nextTop, s, a), duration: dur)
        } else if newNext != nil {
            // The new preview comes up from below the rising line (never across it) as a second, quieter beat.
            let y = min(nextTop.y - travel * 0.7, from.0.y - hC * from.1)
            moveLine(nxt, from: (CGPoint(x: 0, y: y), s * 0.92, 0), to: (nextTop, s, a), duration: dur, fade: 0.4...1)
        }
        return size
    }

    /// The sweep runs across 92% of the line.
    private func applyTiming(_ st: LyricsState) {
        guard let sweep, let i = lineIndex else { return }
        let s = st.start(i)
        let d = max(0.3, (st.end(i) - s) * 0.92)
        if st.clock.playing {
            sweep.play(from: st.clock.hostTime(of: s), duration: d)
        } else {
            sweep.freeze(at: (st.clock.position - s) / d)
        }
    }

    func retime(_ state: LyricsState, context: RenderContext) {
        guard state.index == lineIndex else { return }
        applyTiming(state)
    }

    func recolor(context: RenderContext) { recolorRegistered(context) }
    override func applyShadows(_ context: RenderContext) {
        let live: [CALayer?] = [dim, lit, next]
        for l in live.compactMap({ $0 }) + ghosts.shadowed { context.applyShadow(to: l) }
    }
    func currentWords() -> [(text: String, rect: CGRect)] { (bright ?? dim).map(wordsOf) ?? [] }
    override func teardown() {
        ghosts.clear()
        super.teardown()
        currentGroup = nil; dim = nil; lit = nil; bright = nil; sweep = nil; next = nil; nextText = nil; lineIndex = nil
    }
}

// MARK: - Dynamic

/// Instagram-style kinetic type: the line is broken into short, balanced rows, each row sized to fill the
/// width, and the words pop in one by one as they are sung.
@MainActor final class DynamicRenderer: BaseRenderer, StyleRenderer {
    /// A word, the playback time it pops in (-∞ = always shown) and, while its pop is scheduled or running,
    /// the host time it starts.
    private struct PlacedWord {
        let layer: TextLayer
        let at: TimeInterval
        var popsAt: CFTimeInterval? = nil
    }

    private var block: QuietLayer?
    private var words: [PlacedWord] = []
    private lazy var ghosts = Ghosts(owner: self)
    private var lineIndex: Int?
    let transitionDuration: TimeInterval = 0.32

    private static let popKey = "pop"
    private static let popDuration: CFTimeInterval = 0.28
    /// No word of the new line pops before this moment (the outgoing line is still clearing).
    private var enterAt: CFTimeInterval = 0

    func show(_ content: StyleContent, advancing: Bool, context ctx: RenderContext) -> CGSize {
        let leaving = advancing ? block : nil
        let leavingTexts = words.map(\.layer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if leaving != nil {
            // A word still waiting for its moment must not pop up on the way out.
            let now = CACurrentMediaTime()
            for w in words where (w.popsAt ?? -.infinity) > now {
                w.layer.removeAnimation(forKey: Self.popKey)
                w.layer.opacity = 0
            }
        } else {
            ghosts.clear()
            leavingTexts.forEach(forget)
            block?.removeFromSuperlayer()
        }
        words.removeAll()
        enterAt = leaving != nil ? CACurrentMediaTime() + 0.06 : 0

        let b = QuietLayer()
        b.anchorPoint = CGPoint(x: 0.5, y: 1)
        b.position = .zero
        ctx.applyShadow(to: b)
        root.addSublayer(b)
        block = b

        let size: CGSize
        lineIndex = nil
        if case .lyrics(let st) = content, let i = st.index,
           let raw = st.text(i)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            lineIndex = i
            size = layoutRows(raw, st: st, line: i, in: b, ctx: ctx)
            applyTiming(st)
        } else {
            // Before the first line, a gap, loading or a note: one static layer.
            let text: String
            let isNote: Bool
            if case .note(let s) = content { text = s; isNote = true } else { text = "♪"; isNote = false }
            let l = makeTextLayer(ctx) { isNote ? $0.noteLayout(text) : $0.layout(text) }
            l.anchorPoint = CGPoint(x: 0.5, y: 1)
            l.position = .zero
            b.addSublayer(l)
            words = [PlacedWord(layer: l, at: -.infinity)]
            size = CGSize(width: max(Self.inkWidth(l.layout!), 24), height: l.bounds.height)
        }
        setBlockSize(size)
        CATransaction.commit()

        if let leaving {
            ghosts.release(leaving, texts: leavingTexts, shadowed: [leaving], rise: ctx.fontSize * 0.3, scale: 0.85,
                           duration: transitionDuration)
        }
        return size
    }

    /// Splits the words into as many rows of ≤ `limit` characters as greedy filling needs, then evens the rows
    /// out (shortest longest row), so no row is a lone short word.
    private static func rows(of tokens: [String], limit: Int = 12) -> [[String]] {
        guard !tokens.isEmpty else { return [] }
        var count = 0, run = 0
        for t in tokens {
            if count > 0, run + 1 + t.count <= limit { run += 1 + t.count } else { count += 1; run = t.count }
        }
        let n = tokens.count
        let before = tokens.reduce(into: [0]) { $0.append($0[$0.count - 1] + $1.count) }
        func length(_ a: Int, _ b: Int) -> Int { before[b] - before[a] + (b - a - 1) }
        // best[r][e]: the shortest longest row splitting tokens[0..<e] into r rows; cut[r][e]: where its last row starts.
        var best = [[Int]](repeating: [Int](repeating: .max, count: n + 1), count: count + 1)
        var cut = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: count + 1)
        best[0][0] = 0
        for r in 1...count {
            for e in r...n {
                for s in (r - 1)..<e where best[r - 1][s] < .max {
                    let worst = max(best[r - 1][s], length(s, e))
                    if worst < best[r][e] { best[r][e] = worst; cut[r][e] = s }
                }
            }
        }
        var out: [[String]] = []
        var e = n
        for r in stride(from: count, to: 0, by: -1) {
            let s = cut[r][e]
            out.insert(Array(tokens[s..<e]), at: 0)
            e = s
        }
        return out
    }

    /// Sizes each row to the target width and places its words.
    private func layoutRows(_ text: String, st: LyricsState, line i: Int, in b: CALayer, ctx: RenderContext) -> CGSize {
        let S = ctx.fontSize
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        let target = min(ctx.wrapWidth, S * 8.5)
        let totalChars = max(1, tokens.reduce(0) { $0 + $1.count + 1 })
        let s = st.start(i)
        let span = min(max(0.3, (st.end(i) - s) * 0.8), Double(tokens.count) * 0.5)
        var charsBefore = 0
        var y: CGFloat = 0
        var height: CGFloat = 0
        var maxWidth: CGFloat = 0
        for (r, row) in Self.rows(of: tokens).enumerated() {
            let weight: NSFont.Weight = r % 2 == 0 ? .heavy : .bold
            // Natural width at the base size decides how much this row is scaled up or down.
            let natural = ctx.attributed(row.joined(separator: " "), size: S, weight: weight).size().width
            let size = min(S * 1.9, max(S * 0.75, S * target / max(1, natural)))
            let space = ctx.attributed(" ", size: size, weight: weight).size().width
            var layers: [(TextLayer, CGFloat)] = []
            var rowWidth: CGFloat = 0
            var rowHeight: CGFloat = 0
            for w in row {
                // Measure unwrapped, then lay the word out at exactly that width so the layer is tight.
                let ink = min(ctx.wrapWidth, Self.inkWidth(ctx.layout(w, size: size, weight: weight, width: 10_000)) + 2)
                let l = makeTextLayer(ctx) { $0.layout(w, size: size, weight: weight, width: ink) }
                layers.append((l, ink))
                rowWidth += ink
                rowHeight = max(rowHeight, l.bounds.height)
            }
            rowWidth += space * CGFloat(row.count - 1)
            var x = -rowWidth / 2
            for (k, (l, ink)) in layers.enumerated() {
                // Anchored at its centre (the default), so a word pops out from its middle.
                l.position = CGPoint(x: x + ink / 2, y: -y - l.bounds.height / 2)
                b.addSublayer(l)
                words.append(PlacedWord(layer: l, at: s + span * Double(charsBefore) / Double(totalChars)))
                charsBefore += row[k].count + 1
                x += ink + space
            }
            height = y + rowHeight
            y += rowHeight * 0.92
            maxWidth = max(maxWidth, rowWidth)
        }
        return CGSize(width: max(maxWidth, 24), height: max(height, S))
    }

    /// Re-times every pop for `st.clock`: sung words shown, the rest popping in at their moment.
    private func applyTiming(_ st: LyricsState) {
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for k in words.indices {
            let l = words[k].layer
            words[k].popsAt = nil
            l.removeAnimation(forKey: Self.popKey)
            guard st.clock.playing else {
                l.opacity = st.clock.position >= words[k].at ? 1 : 0
                continue
            }
            l.opacity = 1
            let start = max(st.clock.hostTime(of: words[k].at), enterAt)
            guard start + Self.popDuration > now else { continue }     // already sung
            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [0.4, 1.12, 1.0]
            pop.keyTimes = [0, 0.6, 1]
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1]
            fade.keyTimes = [0, 0.4, 1]
            let g = CAAnimationGroup()
            g.animations = [pop, fade]
            g.duration = Self.popDuration
            g.beginTime = l.convertTime(start, from: nil)
            g.fillMode = .backwards                            // invisible until its moment
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            l.add(g, forKey: Self.popKey)
            words[k].popsAt = start
        }
        CATransaction.commit()
    }

    func retime(_ state: LyricsState, context: RenderContext) {
        guard lineIndex != nil, state.index == lineIndex else { return }
        applyTiming(state)
    }

    func recolor(context: RenderContext) { recolorRegistered(context) }
    override func applyShadows(_ context: RenderContext) {
        if let block { context.applyShadow(to: block) }
        for l in ghosts.shadowed { context.applyShadow(to: l) }
    }
    func currentWords() -> [(text: String, rect: CGRect)] {
        words.compactMap { w in
            guard let t = w.layer.layout?.words.first?.text else { return nil }
            return (t, w.layer.convert(w.layer.bounds, to: root))
        }
    }
    override func teardown() {
        ghosts.clear()
        super.teardown()
        block = nil; words.removeAll(); lineIndex = nil
    }
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
    private var gap: CGFloat = 0
    private var fadeLength: CGFloat = 0        // height of each edge fade
    private var focusDepth: CGFloat = 0        // where a line's top sits below the block top as it starts
    private var visibleHeight: CGFloat = 0
    private var cacheKey = ""
    private var lineIndex: Int?
    private var noteLayer: TextLayer?
    private var lastState: LyricsState?
    let transitionDuration: TimeInterval = 0.4

    /// Alpha across each edge fade (smoothstep), so lines melt away rather than look sliced.
    private static let ramp: [CGFloat] = [0, 0.25, 0.5, 0.75, 1].map { $0 * $0 * (3 - 2 * $0) }

    override init() {
        super.init()
        root.addSublayer(column)
        let edge = Self.ramp.map { NSColor.black.withAlphaComponent($0).cgColor }
        fade.colors = edge + edge.reversed()
        fade.startPoint = CGPoint(x: 0.5, y: 1)
        fade.endPoint = CGPoint(x: 0.5, y: 0)
        fade.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "locations": NSNull()]
    }

    func show(_ content: StyleContent, advancing: Bool, context ctx: RenderContext) -> CGSize {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard case .lyrics(let st) = content, !st.lyrics.lines.isEmpty else {
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
        // Measure every line once per song / size (layouts are cheap; bitmaps are made lazily below).
        let key = "\(st.id)|\(S)|\(W)|\(ctx.scale)|\(st.lyrics.lines.count)"
        if key != cacheKey {
            for (_, l) in lineLayers { forget(l) }
            lineLayers.removeAll()
            gap = S * 0.28
            heights = st.lyrics.lines.map { ctx.layout(RenderContext.displayText($0.text), width: W).size.height }
            tops = []
            var y: CGFloat = 0
            for h in heights { tops.append(-y); y += h + gap }
            // While it is sung a line rises by its own height + gap; even the tallest line's whole trip stays
            // in the clear band between the edge fades.
            let tallest = heights.max() ?? S
            fadeLength = S * 0.9
            focusDepth = fadeLength + tallest + gap
            visibleHeight = max(S * 6.2, focusDepth + tallest + fadeLength)
            cacheKey = key
        }
        lineIndex = st.index
        lastState = st

        // Keep layers only for the lines that are inside the block at some point while this line is sung.
        let i = st.index ?? -1
        let cur = max(i, 0)
        let rise = st.index != nil && cur + 1 < tops.count ? heights[cur] + gap : 0
        func visible(_ k: Int) -> Bool {
            let depth = focusDepth + tops[cur] - tops[k]     // k's top below the block top as line i starts
            return depth + heights[k] > 0 && depth - rise < visibleHeight
        }
        var lo = cur, hi = cur
        while lo > 0, visible(lo - 1) { lo -= 1 }
        while hi + 1 < tops.count, visible(hi + 1) { hi += 1 }
        for (k, l) in lineLayers where k < lo || k > hi { forget(l); lineLayers.removeValue(forKey: k) }
        var width: CGFloat = 24
        for k in lo...hi {
            let target: Float = k == i ? 1 : (k < i ? 0.3 : 0.45)
            let l: TextLayer
            if let existing = lineLayers[k] {
                l = existing
                if advancing, l.opacity != target {
                    let o = CABasicAnimation(keyPath: "opacity")
                    o.fromValue = l.presentation()?.opacity ?? l.opacity
                    o.toValue = target
                    o.duration = transitionDuration
                    o.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    l.add(o, forKey: "highlight")
                }
            } else {
                let text = RenderContext.displayText(st.lyrics.lines[k].text)
                l = makeTextLayer(ctx) { $0.layout(text, width: W) }
                column.addSublayer(l)
                lineLayers[k] = l
            }
            l.anchorPoint = CGPoint(x: 0.5, y: 1)
            l.position = CGPoint(x: 0, y: tops[k])
            l.opacity = target
            ctx.applyShadow(to: l)
            width = max(width, Self.inkWidth(l.layout!))
        }
        let size = CGSize(width: width, height: visibleHeight)
        setBlockSize(size)
        // Wide enough for the side padding too, so the widest line's glyph shadow is not cut off.
        fade.frame = root.bounds.insetBy(dx: -ctx.padding, dy: 0)
        let f = Double(fadeLength / visibleHeight)
        let steps = Self.ramp.indices.map { f * Double($0) / Double(Self.ramp.count - 1) }
        fade.locations = (steps + steps.reversed().map { 1 - $0 }).map { NSNumber(value: $0) }
        root.mask = fade
        applyDrift(st)
        return size
    }

    /// Column offset that puts line `k`'s top at the focus depth.
    private func offset(for k: Int) -> CGFloat {
        guard tops.indices.contains(k) else { return 0 }
        return -focusDepth - tops[k]
    }

    /// Where the column is at `host`: across line i it drifts linearly from line i's top at the focus to line
    /// i+1's. Before the first line, line 0 waits at the focus.
    private func columnY(_ st: LyricsState, at host: CFTimeInterval = CACurrentMediaTime()) -> CGFloat {
        guard let i = st.index else { return offset(for: 0) }
        guard i + 1 < tops.count else { return offset(for: i) }
        let s = st.start(i), e = st.end(i)
        let p = e > s ? min(max((st.clock.playbackTime(at: host) - s) / (e - s), 0), 1) : 1
        return offset(for: i) + (offset(for: i + 1) - offset(for: i)) * CGFloat(p)
    }

    private func applyDrift(_ st: LyricsState) {
        column.removeAnimation(forKey: "drift")
        guard let i = st.index, i + 1 < tops.count, st.clock.playing else {
            column.position = CGPoint(x: 0, y: columnY(st))
            return
        }
        // One linear drift across the whole line, pinned to the playback clock.
        let to = offset(for: i + 1)
        column.position = CGPoint(x: 0, y: to)
        let a = CABasicAnimation(keyPath: "position.y")
        a.fromValue = offset(for: i)
        a.toValue = to
        a.beginTime = column.convertTime(st.clock.hostTime(of: st.start(i)), from: nil)
        a.duration = st.end(i) - st.start(i)
        a.fillMode = .backwards
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
        guard let st = lastState, let i = lineIndex, let l = lineLayers[i] else { return [] }
        // The column's model position is already the end of the drift; report where the words are now.
        let dy = columnY(st) - column.position.y
        return wordsOf(l).map { ($0.text, $0.rect.offsetBy(dx: 0, dy: dy)) }
    }
    override func teardown() {
        super.teardown()
        lineLayers.removeAll(); noteLayer = nil; cacheKey = ""; lineIndex = nil; lastState = nil
        root.addSublayer(column)
    }
}
