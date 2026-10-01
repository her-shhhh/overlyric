import AppKit
import QuartzCore
import OverlyricCore

/// Small, rare delights. All of them are subtle, short, and can be switched off from the ⌥-menu.
///  1. Sparkle words — "stars", "rain", "fire", "love", "snow" … get a matching flourish, once per line.
///  2. Shake it off — shake the lyrics while dragging and they wobble like jelly and throw confetti.
///  3. On repeat — the third play of the same song in a row gets a knowing nod.
///  4. Encore — after the last line, a quiet "encore?"; click it and the song starts again.
@MainActor final class EasterEggs {
    var enabled = true
    var onEncore: (() -> Void)?

    private weak var view: OverlayView?
    private let toast = TextLayer()
    private var toastGeneration = 0
    private var lastSparkleLine: (String, Int)?
    private var playCount = 0
    private var countedTrack: String?
    private var encoreOfferedFor: String?
    private var encoreUntil: Date?

    init(view: OverlayView) {
        self.view = view
        toast.anchorPoint = CGPoint(x: 0.5, y: 0)
        toast.opacity = 0
        view.stage.addSublayer(toast)
    }

    // MARK: 1. Sparkle words

    private enum Flourish: CaseIterable {
        case stars, rain, fire, love, snow

        var words: Set<String> {
            switch self {
            case .stars: return ["star", "stars", "shine", "shining", "shines", "sparkle", "sparkling", "glow", "glowing", "twinkle", "diamond", "diamonds"]
            case .rain: return ["rain", "raining", "rainy", "tears", "teardrop", "teardrops", "cry", "crying", "storm"]
            case .fire: return ["fire", "fires", "burn", "burning", "burns", "flame", "flames", "blaze", "spark", "sparks", "lit"]
            case .love: return ["love", "loving", "lover", "heart", "hearts", "kiss", "kisses", "darling", "baby", "babe"]
            case .snow: return ["snow", "snowing", "snowflake", "winter", "frozen", "freeze", "ice", "cold"]
            }
        }
    }

    /// Call once whenever a new line becomes current.
    func lineShown(_ state: LyricsState) {
        guard enabled, let view, let i = state.index, state.clock.playing else { return }
        if let last = lastSparkleLine, last.0 == state.id, last.1 == i { return }
        lastSparkleLine = (state.id, i)
        let words = view.renderer.currentWords()
        for (text, rect) in words {
            let key = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            guard let kind = Flourish.allCases.first(where: { $0.words.contains(key) }) else { continue }
            // A small delay so it lands as the word is (roughly) sung, not the instant the line appears.
            let delay = 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.flourish(kind, around: rect)
            }
            return   // one flourish per line at most
        }
    }

    private func flourish(_ kind: Flourish, around rect: CGRect) {
        guard let view, view.window?.isVisible == true else { return }
        let target = view.renderer.layer.convert(rect, to: view.stage)
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = CGPoint(x: target.midX, y: target.midY)
        emitter.emitterSize = CGSize(width: target.width, height: max(4, target.height * 0.5))
        emitter.emitterShape = .rectangle
        emitter.renderMode = .additive
        let cell = CAEmitterCell()
        let S = view.fontSize
        cell.contents = Self.particleImage(kind, color: view.color)
        cell.birthRate = 26
        cell.lifetime = 1.1
        cell.lifetimeRange = 0.35
        cell.scale = max(0.12, S / 220)
        cell.scaleRange = cell.scale * 0.4
        cell.alphaSpeed = -0.9
        switch kind {
        case .stars:
            cell.velocity = 10; cell.velocityRange = 14; cell.emissionRange = .pi * 2
            cell.spin = 1.5; cell.spinRange = 2; cell.scaleSpeed = -0.08
        case .rain:
            emitter.emitterPosition.y = target.maxY + S * 0.2
            cell.velocity = 70; cell.velocityRange = 20; cell.emissionLongitude = -.pi / 2; cell.emissionRange = 0.15
            cell.yAcceleration = -160
        case .fire:
            emitter.emitterPosition.y = target.minY
            cell.velocity = 35; cell.velocityRange = 15; cell.emissionLongitude = .pi / 2; cell.emissionRange = 0.6
            cell.yAcceleration = 40; cell.scaleSpeed = -0.15
        case .love:
            cell.velocity = 28; cell.velocityRange = 10; cell.emissionLongitude = .pi / 2; cell.emissionRange = 0.9
            cell.yAcceleration = 18; cell.spinRange = 0.8
        case .snow:
            emitter.emitterPosition.y = target.maxY + S * 0.15
            cell.velocity = 18; cell.velocityRange = 8; cell.emissionLongitude = -.pi / 2; cell.emissionRange = 0.7
            cell.yAcceleration = -14; cell.spinRange = 1.2
        }
        emitter.emitterCells = [cell]
        emitter.beginTime = CACurrentMediaTime()
        view.stage.addSublayer(emitter)
        // Emit briefly, then let the particles finish and remove the layer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { emitter.birthRate = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { emitter.removeFromSuperlayer() }
    }

    private static func particleImage(_ kind: Flourish, color: NSColor) -> CGImage? {
        let size = 48
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let c = color.usingColorSpace(.sRGB) ?? color
        ctx.setFillColor(c.cgColor)
        ctx.setStrokeColor(c.cgColor)
        let m = CGFloat(size) / 2
        switch kind {
        case .stars:
            let p = CGMutablePath()
            for k in 0..<8 {
                let r: CGFloat = k % 2 == 0 ? 22 : 5
                let a = CGFloat(k) * .pi / 4
                let pt = CGPoint(x: m + r * sin(a), y: m + r * cos(a))
                k == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.closeSubpath()
            ctx.addPath(p); ctx.fillPath()
        case .rain:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: m, y: 44))
            p.addQuadCurve(to: CGPoint(x: m + 9, y: 14), control: CGPoint(x: m + 12, y: 30))
            p.addArc(center: CGPoint(x: m, y: 14), radius: 9, startAngle: 0, endAngle: .pi, clockwise: true)
            p.addQuadCurve(to: CGPoint(x: m, y: 44), control: CGPoint(x: m - 12, y: 30))
            ctx.addPath(p); ctx.fillPath()
        case .fire:
            ctx.fillEllipse(in: CGRect(x: m - 9, y: m - 9, width: 18, height: 18))
        case .love:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: m, y: 8))
            p.addCurve(to: CGPoint(x: m - 20, y: 32), control1: CGPoint(x: m - 6, y: 16), control2: CGPoint(x: m - 22, y: 20))
            p.addArc(center: CGPoint(x: m - 10, y: 33), radius: 10, startAngle: .pi, endAngle: 0, clockwise: true)
            p.addArc(center: CGPoint(x: m + 10, y: 33), radius: 10, startAngle: .pi, endAngle: 0, clockwise: true)
            p.addCurve(to: CGPoint(x: m, y: 8), control1: CGPoint(x: m + 22, y: 20), control2: CGPoint(x: m + 6, y: 16))
            ctx.addPath(p); ctx.fillPath()
        case .snow:
            ctx.setLineWidth(4); ctx.setLineCap(.round)
            for k in 0..<3 {
                let a = CGFloat(k) * .pi / 3
                ctx.move(to: CGPoint(x: m - 18 * cos(a), y: m - 18 * sin(a)))
                ctx.addLine(to: CGPoint(x: m + 18 * cos(a), y: m + 18 * sin(a)))
            }
            ctx.strokePath()
        }
        return ctx.makeImage()
    }

    // MARK: 2. Shake it off

    func shake() {
        guard enabled, let view else { return }
        let l = view.renderer.layer
        let wobble = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        wobble.values = [0, 0.09, -0.08, 0.06, -0.04, 0.02, 0]
        let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
        bounce.values = [1, 1.1, 0.94, 1.04, 0.98, 1]
        let g = CAAnimationGroup()
        g.animations = [wobble, bounce]
        g.duration = 0.7
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.add(g, forKey: "shakeItOff")
        let block = l.convert(l.bounds, to: view.stage)
        for kind in [Flourish.stars, .love] {
            flourish(kind, around: block.insetBy(dx: block.width * 0.3, dy: 0))
        }
        say("shake it off ✨", for: 1.6)
    }

    // MARK: 3. On repeat

    /// Call when a track starts playing from the top (a new track, or the same one again).
    func trackStarted(id: String) {
        guard !id.isEmpty else { return }
        if id == countedTrack { playCount += 1 } else { countedTrack = id; playCount = 1 }
        encoreOfferedFor = nil
        guard enabled, playCount == 3 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.say("on repeat again? same 🔁", for: 3)
        }
    }

    // MARK: 4. Encore

    /// Call on every refresh while lyrics show; offers an encore near the end of the song.
    func considerEncore(_ state: LyricsState, trackDuration: TimeInterval) {
        guard enabled, trackDuration > 20, encoreOfferedFor != state.id,
              let i = state.index, i == state.lyrics.lines.count - 1 || state.nextSung(after: i) == nil else { return }
        let remaining = trackDuration - state.clock.playbackTime()
        guard remaining > 0, remaining <= 8, state.clock.playing else { return }
        encoreOfferedFor = state.id
        encoreUntil = Date().addingTimeInterval(remaining + 6)
        say("encore? ↺  click", for: remaining + 6)
    }

    /// A click on the lyrics: true if it was used for the encore.
    func consumeClick() -> Bool {
        guard enabled, let until = encoreUntil, Date() < until else { return false }
        encoreUntil = nil
        hideToast()
        onEncore?()
        return true
    }

    // MARK: Toast

    private func say(_ text: String, for seconds: TimeInterval) {
        guard let view, view.window?.isVisible == true else { return }
        toastGeneration += 1
        let generation = toastGeneration
        let ctx = view.context
        let layout = TextLayout(ctx.attributed(text, size: max(12, ctx.fontSize * 0.4), weight: .semibold, alpha: 0.85),
                                width: ctx.wrapWidth)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        toast.contentsScale = ctx.scale
        toast.layout = layout
        toast.bounds = CGRect(origin: .zero, size: layout.size)
        ctx.applyShadow(to: toast)
        let top = view.renderer.layer.convert(CGPoint.zero, to: view.stage)
        toast.position = CGPoint(x: top.x, y: top.y + ctx.fontSize * 0.08)
        toast.removeFromSuperlayer()
        view.stage.addSublayer(toast)
        CATransaction.commit()
        fade(toast, to: 1, duration: 0.35)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.toastGeneration == generation else { return }
            self.hideToast()
        }
    }

    private func hideToast() { fade(toast, to: 0, duration: 0.5) }

    private func fade(_ l: CALayer, to value: Float, duration: TimeInterval) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = l.presentation()?.opacity ?? l.opacity
        a.toValue = value
        a.duration = duration
        l.opacity = value
        l.add(a, forKey: "toastFade")
    }
}
