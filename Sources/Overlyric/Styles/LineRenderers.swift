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

/// The current line, and the next one smaller and dimmer underneath. On a line change the whole column
/// scrolls up: the preview rises into place and brightens, the old line scrolls away by the same distance
/// (so the two never overlap) and is gone before it reaches the edge, and the new preview fades in below.
@MainActor final class ClassicRenderer: BaseRenderer, StyleRenderer {
    private var current: TextLayer?
    private var next: TextLayer?
    private var ghosts: [TextLayer] = []
    let transitionDuration: TimeInterval = 0.45

    func show(_ content: StyleContent, advancing: Bool, context ctx: RenderContext) -> CGSize {
        let pair = LinePair(content, withNext: true)
        let W = ctx.wrapWidth, WN = W / RenderContext.nextScale
        let gap = ctx.fontSize * 0.2
        let travel = ctx.fontSize * 0.45

        // What is on screen right now (mid-transition values if one is running).
        let oldNextText = next.flatMap { $0.isHidden ? nil : $0.layout?.string.string }
        let oldNextPose = next.map(currentPose)
        let oldCurrentPose = current.map(currentPose)
        let oldCurrentText = current?.layout?.string.string

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for g in ghosts { forget(g) }
        ghosts.removeAll()

        // The outgoing line, drawn BEHIND everything else.
        var ghost: TextLayer?
        if advancing, let oldCurrentText, !oldCurrentText.isEmpty, let pose = oldCurrentPose {
            let g = makeTextLayer(ctx) { $0.layout(oldCurrentText, width: W) }
            g.anchorPoint = CGPoint(x: 0.5, y: 1)
            g.position = pose.position
            g.transform = CATransform3DMakeScale(pose.scale, pose.scale, 1)
            g.opacity = pose.opacity
            ctx.applyShadow(to: g)
            root.insertSublayer(g, at: 0)
            ghosts.append(g)
            ghost = g
        }

        let cur = current ?? { let l = makeTextLayer(ctx) { $0.layout("") }; root.addSublayer(l); current = l; return l }()
        let nxt = next ?? { let l = makeTextLayer(ctx) { $0.layout("") }; root.insertSublayer(l, below: cur); next = l; return l }()
        cur.removeAllAnimations()
        nxt.removeAllAnimations()
        let curText = pair.current, isNote = pair.isNote
        setText(cur, ctx) { isNote ? $0.noteLayout(curText) : $0.layout(curText, width: W) }
        let nextText = pair.next
        if let nextText { setText(nxt, ctx) { $0.layout(nextText, width: WN) } }
        nxt.isHidden = nextText == nil
        ctx.applyShadow(to: cur)
        ctx.applyShadow(to: nxt)

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
        let rest = Pose(position: .zero, scale: 1, opacity: 1)
        let dimNext = Pose(position: nextTop, scale: RenderContext.nextScale, opacity: RenderContext.dimAlpha)
        let promoted = oldNextText != nil && oldNextText == curText
        if promoted, let from = oldNextPose {
            // The preview becomes the current line: scroll everything up by the same distance.
            let rise = max(1, -from.position.y)
            move(cur, from: from, to: rest, duration: d)
            if let ghost, let gp = oldCurrentPose {
                let room = max(1, ctx.padding - ctx.shadowRadius)
                let fadeEnd = max(0.06, d * Self.glideTime(forProgress: room / rise))
                move(ghost, from: gp, to: Pose(position: CGPoint(x: gp.position.x, y: gp.position.y + rise), scale: gp.scale, opacity: 0),
                     duration: d, fadeDuration: fadeEnd, fadeCurve: Self.fadeOutCurve) { [weak self, weak ghost] in
                    guard let self, let ghost else { return }
                    self.forget(ghost); self.ghosts.removeAll { $0 === ghost }
                }
            }
        } else {
            // Nothing was previewed (e.g. stepping into an instrumental gap): fade through in place.
            move(cur, from: Pose(position: CGPoint(x: 0, y: -travel), scale: 0.94, opacity: 0), to: rest,
                 duration: d, fadeDelay: 0.1, fadeDuration: d - 0.1)
            if let ghost, let gp = oldCurrentPose {
                move(ghost, from: gp, to: Pose(position: CGPoint(x: gp.position.x, y: gp.position.y + travel), scale: gp.scale * 0.96, opacity: 0),
                     duration: d * 0.7, fadeDuration: 0.14, fadeCurve: Self.fadeOutCurve) { [weak self, weak ghost] in
                    guard let self, let ghost else { return }
                    self.forget(ghost); self.ghosts.removeAll { $0 === ghost }
                }
            }
        }
        if let nextText {
            if !promoted, oldNextText == nextText, let from = oldNextPose {
                // The same preview stays: only follow the new current line's height.
                if from.position != nextTop { move(nxt, from: from, to: dimNext, duration: d) }
            } else {
                move(nxt, from: Pose(position: CGPoint(x: 0, y: nextTop.y - travel * 0.7), scale: RenderContext.nextScale * 0.92, opacity: 0),
                     to: dimNext, duration: d, fadeDelay: 0.12, fadeDuration: d - 0.12)
            }
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

/// Only the line being sung. The old line lifts away and is gone within a few frames; the new one rises in
/// from below just after it (a fade-through, so the two are never on top of each other).
@MainActor final class SingleRenderer: BaseRenderer, StyleRenderer {
    private var current: TextLayer?
    private var ghosts: [TextLayer] = []
    let transitionDuration: TimeInterval = 0.42

    func show(_ content: StyleContent, advancing: Bool, context ctx: RenderContext) -> CGSize {
        let pair = LinePair(content, withNext: false)
        let travel = ctx.fontSize * 0.5
        let oldPose = current.map(currentPose)
        let oldText = current?.layout?.string.string

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for g in ghosts { forget(g) }
        ghosts.removeAll()
        var ghost: TextLayer?
        if advancing, let oldText, !oldText.isEmpty, let pose = oldPose {
            let g = makeTextLayer(ctx) { $0.layout(oldText) }
            g.anchorPoint = CGPoint(x: 0.5, y: 1)
            g.position = pose.position
            g.transform = CATransform3DMakeScale(pose.scale, pose.scale, 1)
            g.opacity = pose.opacity
            ctx.applyShadow(to: g)
            root.insertSublayer(g, at: 0)
            ghosts.append(g)
            ghost = g
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
        if let ghost, let gp = oldPose {
            move(ghost, from: gp, to: Pose(position: CGPoint(x: gp.position.x, y: gp.position.y + travel), scale: gp.scale * 0.96, opacity: 0),
                 duration: 0.3, fadeDuration: 0.12, fadeCurve: Self.fadeOutCurve) { [weak self, weak ghost] in
                guard let self, let ghost else { return }
                self.forget(ghost); self.ghosts.removeAll { $0 === ghost }
            }
        }
        move(cur, from: Pose(position: CGPoint(x: 0, y: -travel), scale: 0.94, opacity: 0), to: Pose(position: .zero, scale: 1, opacity: 1),
             duration: transitionDuration, fadeDelay: 0.08, fadeDuration: 0.26)
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

/// One line on the face of a cube. On a line change the cube rolls upwards as one rigid prism: the old
/// face tips back over the top while the next face comes up from below, with real perspective.
@MainActor final class CubeRenderer: BaseRenderer, StyleRenderer {
    private struct Face {
        var angle: CGFloat
        var position: CGPoint
        var z: CGFloat
        var anchorZ: CGFloat
    }

    private var current: TextLayer?
    private var outgoing: [TextLayer] = []
    let transitionDuration: TimeInterval = 0.5
    private static let roll = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.15, 1)

    /// A face resting on the z = 0 plane, pivoting about a point `depth/2` behind it.
    private func mount(_ l: CALayer, height: CGFloat, depth: CGFloat) {
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        l.anchorPointZ = -depth / 2
        l.position = CGPoint(x: 0, y: -height / 2)
        l.zPosition = -depth / 2
        l.isDoubleSided = false
        l.transform = CATransform3DIdentity
    }

    func show(_ content: StyleContent, advancing: Bool, context ctx: RenderContext) -> CGSize {
        let pair = LinePair(content, withNext: false)
        let old = current
        // A roll interrupted by the next line continues from where the face visibly is.
        var seed: (face: Face, alpha: Float)?
        if advancing, let old, old.animation(forKey: "cubeRoll") != nil, let pr = old.presentation() {
            seed = (Face(angle: (pr.value(forKeyPath: "transform.rotation.x") as? CGFloat) ?? 0,
                         position: pr.position, z: pr.zPosition, anchorZ: pr.anchorPointZ), pr.opacity)
        }
        let oldText = old?.layout?.string.string

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for g in outgoing { forget(g) }
        outgoing.removeAll()
        var leaving: TextLayer?
        if advancing, let oldText, !oldText.isEmpty {
            let g = makeTextLayer(ctx) { $0.layout(oldText) }
            ctx.applyShadow(to: g)
            root.insertSublayer(g, at: 0)
            outgoing.append(g)
            leaving = g
        }
        let cur = current ?? { let l = makeTextLayer(ctx) { $0.layout("") }; root.addSublayer(l); current = l; return l }()
        cur.removeAllAnimations()
        let text = pair.current, isNote = pair.isNote
        setText(cur, ctx) { isNote ? $0.noteLayout(text) : $0.layout(text) }
        ctx.applyShadow(to: cur)
        let h = cur.bounds.height
        let oh = leaving?.bounds.height ?? h
        mount(cur, height: h, depth: h)
        cur.opacity = 1
        if let leaving { mount(leaving, height: oh, depth: h) }
        // Perspective scaled to the type size, vanishing point at the block's vertical centre.
        let H = advancing ? max(h, oh) : h
        var p = CATransform3DIdentity
        p.m34 = -1 / (ctx.fontSize * 9)
        root.sublayerTransform = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(0, H / 2, 0), p),
                                                     CATransform3DMakeTranslation(0, -H / 2, 0))
        let size = CGSize(width: max(Self.inkWidth(cur.layout!), 24), height: h)
        setBlockSize(size)
        CATransaction.commit()

        guard advancing else { return size }
        // One rigid prism: front = old face (height oh), depth = new face height h.
        let c0 = CGPoint(x: 0, y: -oh / 2), z0 = -h / 2
        let c1 = CGPoint(x: 0, y: -h / 2), z1 = -oh / 2
        if let leaving {
            let a0 = seed?.alpha ?? 1
            roll(leaving, from: seed?.face ?? Face(angle: 0, position: c0, z: z0, anchorZ: -h / 2),
                 to: Face(angle: -.pi / 2, position: c1, z: z1, anchorZ: -h / 2), alpha: [a0, min(a0, 0.8), 0]) { [weak self, weak leaving] in
                guard let self, let leaving else { return }
                self.forget(leaving); self.outgoing.removeAll { $0 === leaving }
            }
        }
        roll(cur, from: Face(angle: .pi / 2, position: c0, z: z0, anchorZ: -oh / 2),
             to: Face(angle: 0, position: c1, z: z1, anchorZ: -oh / 2), alpha: [0, 0.8, 1])
        return size
    }

    private func roll(_ l: CALayer, from: Face, to: Face, alpha: [Float], done: (() -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(done)
        l.transform = CATransform3DMakeRotation(to.angle, 1, 0, 0)
        l.position = to.position
        l.zPosition = to.z
        l.anchorPointZ = to.anchorZ
        l.opacity = alpha.last ?? 1
        func basic(_ key: String, _ a: Any, _ b: Any) -> CABasicAnimation {
            let x = CABasicAnimation(keyPath: key); x.fromValue = a; x.toValue = b; return x
        }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = alpha
        fade.keyTimes = [0, 0.5, 1]
        let g = CAAnimationGroup()
        g.animations = [basic("transform.rotation.x", from.angle, to.angle),
                        basic("position", NSValue(point: from.position), NSValue(point: to.position)),
                        basic("zPosition", from.z, to.z),
                        basic("anchorPointZ", from.anchorZ, to.anchorZ),
                        fade]
        g.duration = transitionDuration
        g.timingFunction = Self.roll
        l.add(g, forKey: "cubeRoll")
        CATransaction.commit()
    }

    func retime(_ state: LyricsState, context: RenderContext) {}
    func recolor(context: RenderContext) { recolorRegistered(context) }
    override func applyShadows(_ context: RenderContext) {
        for l in [current].compactMap({ $0 }) + outgoing { context.applyShadow(to: l) }
    }
    func currentWords() -> [(text: String, rect: CGRect)] { current.map(wordsOf) ?? [] }
    override func teardown() { super.teardown(); current = nil; outgoing.removeAll() }
}
