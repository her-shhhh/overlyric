import AppKit
import QuartzCore
import OverlyricCore

/// What a line-based style shows: the current line (or ♪ / a note) and optionally the next sung line.
struct LinePair {
    var current: String
    var isNote: Bool
    var next: String?

    init(_ content: StyleContent, withNext: Bool) {
        switch content {
        case .empty:
            current = "♪"; isNote = false; next = nil
        case .note(let s):
            current = s; isNote = true; next = nil
        case .lyrics(let st):
            current = RenderContext.displayText(st.text(st.index))
            isNote = false
            next = withNext ? st.nextSung(after: st.index).flatMap { st.text($0) } : nil
        }
    }
}

// MARK: - Two lines (current + next)

/// The original look: the current line, and the next one smaller and dimmer underneath. On a line change
/// the old line drifts up and fades, the next line rises into place, the new next line fades in.
@MainActor final class ClassicRenderer: BaseRenderer, StyleRenderer {
    private var current: TextLayer?
    private var next: TextLayer?
    private var ghosts: [TextLayer] = []
    let transitionDuration: TimeInterval = 0.42

    func show(_ content: StyleContent, advancing: Bool, context ctx: RenderContext) -> CGSize {
        let pair = LinePair(content, withNext: true)
        let W = ctx.wrapWidth, WN = W / RenderContext.nextScale
        let gap = ctx.fontSize * 0.2
        let travel = ctx.fontSize * 0.45

        // Where things are on screen right now (presentation values if a transition is still running).
        let oldNextTop = (next?.presentation() ?? next)?.position
        let oldNextVisible = next.map { !$0.isHidden && $0.opacity > 0 } ?? false
        let oldCurrent = current

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for g in ghosts { forget(g) }
        ghosts.removeAll()

        // Ghost of the outgoing line.
        if advancing, let oldCurrent, let oldLayout = oldCurrent.layout, !oldLayout.isEmpty {
            let g = makeTextLayer(ctx) { _ in oldLayout }
            g.position = (oldCurrent.presentation() ?? oldCurrent).position
            g.anchorPoint = CGPoint(x: 0.5, y: 1)
            ctx.applyShadow(to: g)
            root.addSublayer(g)
            ghosts.append(g)
        }

        let cur = current ?? { let l = makeTextLayer(ctx) { $0.layout("") }; root.addSublayer(l); current = l; return l }()
        let nxt = next ?? { let l = makeTextLayer(ctx) { $0.layout("") }; root.insertSublayer(l, below: cur); next = l; return l }()
        cur.removeAllAnimations(); nxt.removeAllAnimations()

        let curText = pair.current, isNote = pair.isNote
        setText(cur, ctx) { isNote ? $0.noteLayout(curText) : $0.layout(curText, width: W) }
        let nextText = pair.next
        if let nextText { setText(nxt, ctx) { $0.layout(nextText, width: WN) } }
        nxt.isHidden = nextText == nil
        ctx.applyShadow(to: cur); ctx.applyShadow(to: nxt)

        let hC = cur.bounds.height
        let visualN = nextText == nil ? 0 : nxt.bounds.height * RenderContext.nextScale
        let nextTop = CGPoint(x: 0, y: -(hC + gap))
        place(cur, topCentre: .zero)
        place(nxt, topCentre: nextTop, scale: RenderContext.nextScale, opacity: RenderContext.dimAlpha)
        let width = max(Self.inkWidth(cur.layout!), nextText == nil ? 0 : Self.inkWidth(nxt.layout!) * RenderContext.nextScale, 24)
        let size = CGSize(width: width, height: hC + (nextText == nil ? 0 : gap + visualN))
        setBlockSize(size)
        CATransaction.commit()

        guard advancing else { return size }
        let d = transitionDuration
        for g in ghosts {
            let start = g.position
            animate(g, from: (start, 1, 1), to: (CGPoint(x: start.x, y: start.y + travel), 0.94, 0), duration: d) { [weak self, weak g] in
                guard let self, let g else { return }
                self.forget(g); self.ghosts.removeAll { $0 === g }
            }
        }
        let riseFrom = oldNextVisible ? (oldNextTop ?? CGPoint(x: 0, y: -travel)) : CGPoint(x: 0, y: -travel)
        animate(cur, from: (riseFrom, RenderContext.nextScale, RenderContext.dimAlpha), to: (.zero, 1, 1), duration: d)
        if nextText != nil {
            animate(nxt, from: (CGPoint(x: 0, y: nextTop.y - travel * 0.7), RenderContext.nextScale * 0.92, 0),
                    to: (nextTop, RenderContext.nextScale, RenderContext.dimAlpha), duration: d)
        }
        return size
    }

    func retime(_ state: LyricsState, context: RenderContext) {}

    func recolor(context: RenderContext) { recolorRegistered(context) }

    override func applyShadows(_ context: RenderContext) {
        for l in [current, next].compactMap({ $0 }) + ghosts { context.applyShadow(to: l) }
    }

    func currentWords() -> [(text: String, rect: CGRect)] { current.map(wordsOf) ?? [] }

    override func teardown() {
        super.teardown()
        current = nil; next = nil; ghosts.removeAll()
    }
}

// MARK: - One line

/// Only the line being sung. The old line floats up and fades; the new one rises in from below.
@MainActor final class SingleRenderer: BaseRenderer, StyleRenderer {
    private var current: TextLayer?
    private var ghosts: [TextLayer] = []
    let transitionDuration: TimeInterval = 0.4

    func show(_ content: StyleContent, advancing: Bool, context ctx: RenderContext) -> CGSize {
        let pair = LinePair(content, withNext: false)
        let travel = ctx.fontSize * 0.5
        let old = current

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for g in ghosts { forget(g) }
        ghosts.removeAll()
        if advancing, let old, let oldLayout = old.layout, !oldLayout.isEmpty {
            let g = makeTextLayer(ctx) { _ in oldLayout }
            g.anchorPoint = CGPoint(x: 0.5, y: 1)
            g.position = (old.presentation() ?? old).position
            ctx.applyShadow(to: g)
            root.addSublayer(g)
            ghosts.append(g)
        }
        let cur = current ?? { let l = makeTextLayer(ctx) { $0.layout("") }; root.addSublayer(l); current = l; return l }()
        cur.removeAllAnimations()
        let text = pair.current, isNote = pair.isNote
        setText(cur, ctx) { isNote ? $0.noteLayout(text) : $0.layout(text) }
        ctx.applyShadow(to: cur)
        place(cur, topCentre: .zero)
        let size = CGSize(width: max(Self.inkWidth(cur.layout!), 24), height: cur.bounds.height)
        setBlockSize(size)
        CATransaction.commit()

        guard advancing else { return size }
        let d = transitionDuration
        for g in ghosts {
            let s = g.position
            animate(g, from: (s, 1, 1), to: (CGPoint(x: s.x, y: s.y + travel), 0.96, 0), duration: d * 0.85) { [weak self, weak g] in
                guard let self, let g else { return }
                self.forget(g); self.ghosts.removeAll { $0 === g }
            }
        }
        animate(cur, from: (CGPoint(x: 0, y: -travel), 0.94, 0), to: (.zero, 1, 1), duration: d)
        return size
    }

    func retime(_ state: LyricsState, context: RenderContext) {}
    func recolor(context: RenderContext) { recolorRegistered(context) }
    override func applyShadows(_ context: RenderContext) {
        for l in [current].compactMap({ $0 }) + ghosts { context.applyShadow(to: l) }
    }
    func currentWords() -> [(text: String, rect: CGRect)] { current.map(wordsOf) ?? [] }
    override func teardown() { super.teardown(); current = nil; ghosts.removeAll() }
}

// MARK: - Cube

/// One line on the face of a cube; on a line change the cube rolls upwards: the old face tips back and away
/// over the top while the next face comes up from below, in 3D perspective.
@MainActor final class CubeRenderer: BaseRenderer, StyleRenderer {
    private var current: TextLayer?
    private var outgoing: [TextLayer] = []
    let transitionDuration: TimeInterval = 0.55

    override init() {
        super.init()
        var p = CATransform3DIdentity
        p.m34 = -1 / 700
        root.sublayerTransform = p
    }

    func show(_ content: StyleContent, advancing: Bool, context ctx: RenderContext) -> CGSize {
        let pair = LinePair(content, withNext: false)
        let old = current

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for g in outgoing { forget(g) }
        outgoing.removeAll()
        var leaving: TextLayer?
        if advancing, let old, let oldLayout = old.layout, !oldLayout.isEmpty {
            let g = makeTextLayer(ctx) { _ in oldLayout }
            ctx.applyShadow(to: g)
            root.addSublayer(g)
            outgoing.append(g)
            leaving = g
        }
        let cur = current ?? { let l = makeTextLayer(ctx) { $0.layout("") }; root.addSublayer(l); current = l; return l }()
        cur.removeAllAnimations()
        let text = pair.current, isNote = pair.isNote
        setText(cur, ctx) { isNote ? $0.noteLayout(text) : $0.layout(text) }
        ctx.applyShadow(to: cur)
        let h = cur.bounds.height
        // Faces rotate about the cube's centre: anchor at the face centre, pushed back by half the height.
        cur.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        cur.anchorPointZ = -h / 2
        cur.position = CGPoint(x: 0, y: -h / 2)
        cur.zPosition = h / 2
        cur.transform = CATransform3DIdentity
        cur.opacity = 1
        if let leaving, let oh = leaving.layout?.size.height {
            leaving.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            leaving.anchorPointZ = -oh / 2
            leaving.position = CGPoint(x: 0, y: -oh / 2)
            leaving.zPosition = oh / 2
        }
        let size = CGSize(width: max(Self.inkWidth(cur.layout!), 24), height: h)
        setBlockSize(size)
        CATransaction.commit()

        guard advancing else { return size }
        let d = transitionDuration
        func roll(_ l: CALayer, from: CGFloat, to: CGFloat, fromAlpha: Float, toAlpha: Float, done: (() -> Void)? = nil) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock(done)
            l.transform = CATransform3DMakeRotation(to, 1, 0, 0)
            l.opacity = toAlpha
            let r = CABasicAnimation(keyPath: "transform.rotation.x"); r.fromValue = from; r.toValue = to
            let o = CABasicAnimation(keyPath: "opacity"); o.fromValue = fromAlpha; o.toValue = toAlpha
            let g = CAAnimationGroup(); g.animations = [r, o]; g.duration = d
            g.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.2, 1)
            l.add(g, forKey: "cubeRoll")
            CATransaction.commit()
        }
        if let leaving {
            roll(leaving, from: 0, to: -.pi / 2, fromAlpha: 1, toAlpha: 0.2) { [weak self, weak leaving] in
                guard let self, let leaving else { return }
                self.forget(leaving); self.outgoing.removeAll { $0 === leaving }
            }
        }
        roll(cur, from: .pi / 2, to: 0, fromAlpha: 0.2, toAlpha: 1)
        return size
    }

    func retime(_ state: LyricsState, context: RenderContext) {}
    func recolor(context: RenderContext) { recolorRegistered(context) }
    override func applyShadows(_ context: RenderContext) {
        for l in [current].compactMap({ $0 }) + outgoing { context.applyShadow(to: l) }
    }
    func currentWords() -> [(text: String, rect: CGRect)] { current.map(wordsOf) ?? [] }
    override func teardown() { super.teardown(); current = nil; outgoing.removeAll() }
}
