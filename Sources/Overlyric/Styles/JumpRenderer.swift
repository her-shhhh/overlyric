import AppKit
import QuartzCore
import OverlyricCore

// MARK: - Jump

/// Instagram's "Dynamic Lyrics: Jump": the whole line is laid out up front (wrapped, centred), and each
/// word jumps up into its place from just below, with a little spring-like overshoot, as it is sung.
/// The outgoing line floats up and fades out quickly. Everything moves on the compositor; nothing runs
/// per frame.
///
/// The line is laid out once and every word is drawn from that one layout by its own layer, so at rest
/// the words are exactly the plain line, in any script (nothing is re-laid out or re-measured per word).
@MainActor final class JumpRenderer: BaseRenderer, StyleRenderer {
    /// One jumping piece of the line (a word, or the part of a wrapped word on one visual line), the
    /// playback time its jump starts and, while a jump is scheduled or running, its host start time.
    private struct Unit {
        let layer: GlyphLayer
        let at: TimeInterval
        var jumpStart: CFTimeInterval? = nil
    }

    /// A line on its way out. Its layers are kept until its fade ends (so a recolour still reaches them).
    private struct Ghost {
        let block: QuietLayer
        let still: TextLayer?
        let ink: LineInk?
        let layers: [GlyphLayer]
    }

    private var block: QuietLayer?
    private var still: TextLayer?               // ♪ before the first line, loading, or a note
    private var ink: LineInk?                   // the sung line (or a gap's ♪), which the units draw from
    private var units: [Unit] = []
    private var ghosts: [Ghost] = []
    private var lineWords: [(text: String, rect: CGRect)] = []
    private var line: (id: String, index: Int)?
    private var rise: CGFloat = 0               // how far below its place a word starts its jump
    let transitionDuration: TimeInterval = 0.3

    private static let jumpKey = "jump"
    private static let jumpDuration: CFTimeInterval = 0.28
    /// The outgoing line is gone this fast, before the first word of the new line lands where it was.
    private static let fadeOutDuration: CFTimeInterval = 0.08

    func show(_ content: StyleContent, advancing: Bool, context ctx: RenderContext) -> CGSize {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A line change while playing lets earlier ghosts finish leaving; anything else starts clean.
        if !advancing { clearGhosts() }
        var leaving: QuietLayer?
        if let old = block {
            if advancing {
                leaving = retire(old)
            } else {
                if let still { forget(still) }
                old.removeFromSuperlayer()
            }
        }
        block = nil
        still = nil
        ink = nil
        units.removeAll()
        lineWords.removeAll()
        line = nil

        let b = QuietLayer()
        b.anchorPoint = CGPoint(x: 0.5, y: 1)
        b.position = .zero
        ctx.applyShadow(to: b)
        root.addSublayer(b)
        block = b

        let size: CGSize
        if case .lyrics(let st) = content, let i = st.index {
            // A gap shows ♪, which jumps in like a word.
            let raw = st.text(i)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            line = (st.id, i)
            rise = ctx.fontSize * 0.5
            size = layoutWords(raw.isEmpty ? "♪" : raw, st: st, line: i, in: b, ctx: ctx)
            applyTiming(st.clock)
        } else {
            // Before the first line, loading or a note: one still layer.
            let text: String
            let isNote: Bool
            if case .note(let s) = content { text = s; isNote = true } else { text = "♪"; isNote = false }
            let l = makeTextLayer(ctx) { isNote ? $0.noteLayout(text) : $0.layout(text) }
            l.anchorPoint = CGPoint(x: 0.5, y: 1)
            l.position = .zero
            b.addSublayer(l)
            still = l
            size = CGSize(width: max(Self.inkWidth(l.layout!), 24), height: l.bounds.height)
        }
        setBlockSize(size)
        CATransaction.commit()

        if let leaving { leave(leaving, travel: ctx.fontSize * 0.4) }
        return size
    }

    // MARK: Layout

    /// Lays the whole line out once and gives every word its own layer, which draws just that word's glyphs
    /// from the line's layout, where the line has them. Returns the plain line's block size.
    private func layoutWords(_ text: String, st: LyricsState, line i: Int, in b: CALayer, ctx: RenderContext) -> CGSize {
        let full = ctx.layout(text)
        let lineInk = LineInk(text, context: ctx)
        let W = full.width, H = full.size.height
        // Room for glyphs that overhang their typeset extent (only the word's own glyphs are drawn, so its
        // neighbours never show in it).
        let pad = ceil(ctx.fontSize * 0.3)
        // Bitmaps on the plain line's device-pixel grid, so a word at rest is rasterized exactly like it.
        let px = 1 / max(1, ctx.scale)
        let words = full.words
        let onsets = WordTiming.onsets(of: words.map(\.text), characters: text.count, start: st.start(i), end: st.end(i))
        for (w, at) in zip(words, onsets) {
            var extent = CGRect.null
            for piece in lineInk.pieces(of: w.characterRange) {
                let r = piece.rect.insetBy(dx: -pad, dy: -pad)
                let x0 = (r.minX / px).rounded(.down) * px, y0 = (r.minY / px).rounded(.down) * px
                let l = GlyphLayer()
                l.contentsScale = ctx.scale
                l.anchorPoint = .zero
                l.bounds = CGRect(x: x0, y: y0, width: (r.maxX / px).rounded(.up) * px - x0,
                                  height: (r.maxY / px).rounded(.up) * px - y0)
                l.position = CGPoint(x: x0 - W / 2, y: y0 - H)
                l.glyphs = piece.glyphs
                l.ink = lineInk
                b.addSublayer(l)
                units.append(Unit(layer: l, at: at))
                extent = extent.union(piece.rect)
            }
            if !extent.isNull { lineWords.append((w.text, extent.offsetBy(dx: -W / 2, dy: -H))) }
        }
        ink = lineInk
        return CGSize(width: max(Self.inkWidth(full), 24), height: H)
    }

    // MARK: Timing

    /// Times every jump from `clock`, as a pure function of it (so a re-time, a pause or a relayout carries
    /// on seamlessly). Playing: each word jumps at its moment, on the compositor. Paused: each word is shown
    /// as it is at `clock.position`, held mid-jump if it is jumping; resuming carries on from there.
    private func applyTiming(_ clock: PlaybackClock) {
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for k in units.indices {
            let l = units[k].layer, at = units[k].at
            units[k].jumpStart = nil
            l.removeAnimation(forKey: Self.jumpKey)
            l.opacity = 1
            guard clock.playing else {
                let elapsed = clock.position - at
                if elapsed < 0 {
                    l.opacity = 0
                } else if elapsed < Self.jumpDuration {
                    let j = jump()
                    j.speed = 0
                    j.timeOffset = elapsed
                    l.add(j, forKey: Self.jumpKey)
                }
                continue
            }
            let start = clock.hostTime(of: at)
            guard start + Self.jumpDuration > now else { continue }   // already in place
            let j = jump()
            j.beginTime = l.convertTime(start, from: nil)
            j.fillMode = .backwards                                   // hidden below until its moment
            l.add(j, forKey: Self.jumpKey)
            units[k].jumpStart = start
        }
        CATransaction.commit()
    }

    /// Up from half a font size below with a small overshoot and settle, fading in on the way up.
    private func jump() -> CAAnimationGroup {
        let y = CAKeyframeAnimation(keyPath: "transform.translation.y")
        y.values = [-rise, rise * 0.22, -rise * 0.06, 0]
        y.keyTimes = [0, 0.55, 0.8, 1]
        y.timingFunctions = [CAMediaTimingFunction(name: .easeOut),
                             CAMediaTimingFunction(name: .easeInEaseOut),
                             CAMediaTimingFunction(name: .easeInEaseOut)]
        let o = CAKeyframeAnimation(keyPath: "opacity")
        o.values = [0, 1, 1]
        o.keyTimes = [0, 0.35, 1]
        let g = CAAnimationGroup()
        g.animations = [y, o]
        g.duration = Self.jumpDuration
        return g
    }

    func retime(_ state: LyricsState, context: RenderContext) {
        guard let line, line.id == state.id, line.index == state.index else { return }
        applyTiming(state.clock)
    }

    // MARK: Line changes

    /// Turns the current block into a ghost as it looks right now: a word still waiting for its moment
    /// stays hidden (it must not pop up on the way out), a word mid-jump finishes its jump as it fades.
    private func retire(_ old: QuietLayer) -> QuietLayer {
        let now = CACurrentMediaTime()
        for u in units {
            guard let start = u.jumpStart, now < start + 0.01 else { continue }
            u.layer.removeAnimation(forKey: Self.jumpKey)
            u.layer.opacity = 0
        }
        ghosts.append(Ghost(block: old, still: still, ink: ink, layers: units.map(\.layer)))
        return old
    }

    /// The outgoing line floats up over the transition and fades out in its first moments, so it never
    /// shows through the new line's first word jumping into the same place.
    private func leave(_ g: QuietLayer, travel: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak g] in
            guard let self, let g else { return }
            self.dropGhost(g)
        }
        let y = g.position.y
        g.position.y = y + travel
        g.opacity = 0
        let move = CABasicAnimation(keyPath: "position.y")
        move.fromValue = y
        move.toValue = y + travel
        move.duration = transitionDuration
        move.timingFunction = Self.ease
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Self.fadeOutDuration
        fade.timingFunction = Self.ease
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = transitionDuration
        g.add(group, forKey: "leave")
        CATransaction.commit()
    }

    private func dropGhost(_ block: QuietLayer) {
        guard let k = ghosts.firstIndex(where: { $0.block === block }) else { return }
        drop(ghosts.remove(at: k))
    }

    private func clearGhosts() {
        let all = ghosts
        ghosts.removeAll()
        all.forEach(drop)
    }

    private func drop(_ g: Ghost) {
        if let still = g.still { forget(still) }
        g.block.removeAllAnimations()
        g.block.removeFromSuperlayer()
    }

    // MARK: Colour, words, teardown

    func recolor(context: RenderContext) {
        recolorRegistered(context)                // the still layers, and every block's shadow
        restyle(ink, units.map(\.layer), context)
        for g in ghosts { restyle(g.ink, g.layers, context) }
    }

    private func restyle(_ ink: LineInk?, _ layers: [GlyphLayer], _ ctx: RenderContext) {
        guard let ink else { return }
        ink.restyle(ctx)
        for l in layers { l.setNeedsDisplay() }
    }

    override func applyShadows(_ context: RenderContext) {
        if let block { context.applyShadow(to: block) }
        for g in ghosts { context.applyShadow(to: g.block) }
    }

    func currentWords() -> [(text: String, rect: CGRect)] {
        if line != nil { return lineWords }
        return still.map(wordsOf) ?? []
    }

    override func teardown() {
        super.teardown()
        block = nil; still = nil; ink = nil; units.removeAll(); ghosts.removeAll(); lineWords.removeAll()
        line = nil
    }
}

// MARK: - Drawing words from one line layout

/// A line laid out exactly as `TextLayout` lays it out (same attributes, width and TextKit setup), whose
/// glyphs can be drawn a word at a time.
private final class LineInk {
    private let text: String
    private let storage: NSTextStorage
    private let manager = NSLayoutManager()
    private let container: NSTextContainer
    private let height: CGFloat

    init(_ text: String, context ctx: RenderContext) {
        self.text = text
        storage = NSTextStorage(attributedString: ctx.attributed(text))
        container = NSTextContainer(size: NSSize(width: ctx.wrapWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        height = ceil(manager.usedRect(for: container).height) + 2
    }

    /// Same text and geometry in the context's colour.
    func restyle(_ ctx: RenderContext) {
        storage.setAttributedString(ctx.attributed(text))
    }

    /// A character range split per visual line: its glyphs and their typeset extent in layer coordinates
    /// (origin bottom-left, y up). The extent is the union of the selection rects, exact in any script and
    /// writing direction; vertically it is the visual line.
    func pieces(of characters: NSRange) -> [(glyphs: NSRange, rect: CGRect)] {
        let glyphs = manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        var out: [(glyphs: NSRange, rect: CGRect)] = []
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, lineGlyphs, _ in
            let g = NSIntersectionRange(glyphs, lineGlyphs)
            guard g.length > 0 else { return }
            var x = CGRect.null
            self.manager.enumerateEnclosingRects(forGlyphRange: g, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                 in: self.container) { r, _ in x = x.union(r) }
            guard !x.isNull else { return }
            out.append((g, CGRect(x: x.minX, y: self.height - used.maxY, width: x.width, height: used.height)))
        }
        return out
    }

    /// Draws `glyphs` where the line has them, into a layer context in the line's layer coordinates.
    func draw(_ glyphs: NSRange, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }
}

/// Draws some glyphs of a `LineInk` at their place in the line: its bounds (whatever their origin) crop the
/// line, they never shift it. No implicit animations.
private final class GlyphLayer: CALayer {
    var ink: LineInk? {
        didSet { setNeedsDisplay() }
    }
    var glyphs = NSRange(location: 0, length: 0)

    override init() {
        super.init()
        isOpaque = false
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func action(forKey event: String) -> CAAction? { nil }

    override func draw(in ctx: CGContext) {
        ink?.draw(glyphs, in: ctx)
    }
}
