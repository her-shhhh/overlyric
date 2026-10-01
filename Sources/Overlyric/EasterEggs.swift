import AppKit
import QuartzCore
import OverlyricCore

/// Small, rare delights. All of them are subtle, short, and can be switched off from the ⌥-menu.
///  1. Sparkle words — "stars", "rain", "fire", "kiss", "snow" … get a matching flourish as they're sung
///     (at most twice a song).
///  2. Shake it off — shake the lyrics while dragging and they wobble like jelly and throw confetti.
///  3. On repeat — the third play of the same song in a row gets a knowing nod.
///  4. Encore — as the song ends, a quiet "encore?"; click the lyrics and it starts again.
@MainActor final class EasterEggs {
    var enabled = true {
        didSet { if !enabled { endEncore() } }
    }
    /// Asked to play the given Spotify track again from the top.
    var onEncore: ((String) -> Void)?

    private weak var view: OverlayView?
    private let toast = TextLayer()
    private var toastGeneration = 0
    /// Bumped whenever the track changes, so anything scheduled for the previous play is dropped.
    private var songGeneration = 0
    private var flourishesThisSong = 0
    private var lastFlourishAt = Date.distantPast
    private var playCount = 0
    private var countedTrack: String?
    private var encoreOfferedFor: String?
    private var encoreTrackID: String?
    private var encoreUntil: Date?

    private static let flourishesPerSong = 2
    private static let flourishSpacing: TimeInterval = 40

    init(view: OverlayView) {
        self.view = view
        toast.opacity = 0
        view.block.addSublayer(toast)
    }

    // MARK: Track

    /// Call when the current track changes or starts over: ends an encore offer and anything still
    /// scheduled for the previous play.
    func trackChanged() {
        songGeneration += 1
        flourishesThisSong = 0
        encoreOfferedFor = nil
        endEncore()
    }

    // MARK: 1. Sparkle words

    private enum Flourish: CaseIterable {
        case stars, rain, fire, love, snow

        // Only words that are rare enough in lyrics to feel like a surprise.
        var words: Set<String> {
            switch self {
            case .stars: return ["star", "stars", "shine", "shining", "shines", "sparkle", "sparkling", "glow", "glowing", "twinkle", "diamond", "diamonds"]
            case .rain: return ["rain", "raining", "rainy", "tears", "teardrop", "teardrops", "storm"]
            case .fire: return ["fire", "fires", "burn", "burning", "burns", "flame", "flames", "blaze", "spark", "sparks"]
            case .love: return ["lover", "lovers", "hearts", "kiss", "kisses", "kissing", "darling", "sweetheart"]
            case .snow: return ["snow", "snowing", "snowflake", "snowflakes", "winter", "frozen", "freeze", "ice"]
            }
        }

        static func of(_ word: String) -> Flourish? {
            let key = word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            return allCases.first { $0.words.contains(key) }
        }
    }

    /// Call once when a new line starts being sung.
    func lineShown(_ state: LyricsState) {
        guard enabled, let view, let i = state.index, flourishesThisSong < Self.flourishesPerSong,
              Date().timeIntervalSince(lastFlourishAt) > Self.flourishSpacing else { return }
        let words = view.renderer.currentWords()
        guard let k = words.firstIndex(where: { Flourish.of($0.text) != nil }),
              let kind = Flourish.of(words[k].text) else { return }
        flourishesThisSong += 1
        lastFlourishAt = Date()
        // Land roughly as the word is sung: the line's words spread over most of its time, at speech pace.
        let sungSpan = min((state.end(i) - state.start(i)) * 0.85, Double(words.count) * 0.4)
        let sungAt = state.start(i) + sungSpan * Double(k) / Double(words.count)
        let delay = max(0.25, sungAt - state.clock.playbackTime())
        let text = words[k].text
        let song = songGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.songGeneration == song, let view = self.view else { return }
            // Ask again: the words may have moved since, or the line may have changed.
            let now = view.renderer.currentWords()
            guard k < now.count, now[k].text == text else { return }
            self.flourish(kind, around: view.renderer.layer.convert(now[k].rect, to: view.block))
        }
    }

    /// Particles around `target` (block coordinates). Their speeds scale with the text so they stay
    /// within the window's padding and fade out before reaching its edge.
    private func flourish(_ kind: Flourish, around target: CGRect) {
        guard let view, view.window?.isVisible == true else { return }
        let S = view.fontSize
        let emitter = CAEmitterLayer()
        emitter.emitterShape = .rectangle
        emitter.renderMode = .additive
        emitter.emitterPosition = CGPoint(x: target.midX, y: target.midY)
        emitter.emitterSize = CGSize(width: target.width * 0.8, height: max(4, target.height * 0.5))
        let cell = CAEmitterCell()
        cell.contents = Self.particleImage(kind, color: view.color)
        cell.birthRate = 26
        cell.scale = max(0.12, S / 220)
        cell.scaleRange = cell.scale * 0.4
        cell.lifetime = 1
        cell.lifetimeRange = 0.3
        cell.alphaSpeed = -1
        switch kind {
        case .stars:
            cell.velocity = S * 0.2; cell.velocityRange = S * 0.3; cell.emissionRange = .pi * 2
            cell.spin = 1.5; cell.spinRange = 2; cell.scaleSpeed = -0.08
        case .rain:
            emitter.emitterPosition.y = target.maxY
            emitter.emitterSize = CGSize(width: target.width, height: 1)
            cell.velocity = S * 1.1; cell.velocityRange = S * 0.3; cell.emissionLongitude = -.pi / 2; cell.emissionRange = 0.15
            cell.yAcceleration = -S * 1.6
            cell.lifetime = 0.7; cell.lifetimeRange = 0.15; cell.alphaSpeed = -1.4
        case .fire:
            emitter.emitterPosition.y = target.minY + target.height * 0.25
            emitter.emitterSize = CGSize(width: target.width * 0.9, height: max(4, target.height * 0.5))
            cell.velocity = S * 0.6; cell.velocityRange = S * 0.2; cell.emissionLongitude = .pi / 2; cell.emissionRange = 0.6
            cell.yAcceleration = S * 0.4; cell.scaleSpeed = -0.15
            cell.lifetime = 0.8; cell.lifetimeRange = 0.15; cell.alphaSpeed = -1.2
        case .love:
            cell.velocity = S * 0.4; cell.velocityRange = S * 0.15; cell.emissionLongitude = .pi / 2; cell.emissionRange = 0.9
            cell.yAcceleration = S * 0.3; cell.spinRange = 0.8
            cell.lifetime = 0.95; cell.lifetimeRange = 0.2; cell.alphaSpeed = -1.05
        case .snow:
            emitter.emitterPosition.y = target.maxY
            emitter.emitterSize = CGSize(width: target.width, height: 1)
            cell.velocity = S * 0.5; cell.velocityRange = S * 0.2; cell.emissionLongitude = -.pi / 2; cell.emissionRange = 0.7
            cell.yAcceleration = -S * 0.4; cell.spinRange = 1.2
        }
        emitter.emitterCells = [cell]
        emitter.beginTime = CACurrentMediaTime()
        view.block.addSublayer(emitter)
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
        let block = l.convert(l.bounds, to: view.block)
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
        guard enabled, playCount == 3 else { return }
        let song = songGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.songGeneration == song else { return }
            self.say("on repeat again? same 🔁", for: 3)
        }
    }

    // MARK: 4. Encore

    /// Call on every refresh while lyrics show; offers an encore of `trackID` near the end of the song.
    func considerEncore(_ state: LyricsState, trackDuration: TimeInterval, trackID: String) {
        guard enabled, trackDuration > 20, !trackID.isEmpty, encoreOfferedFor != state.id,
              let i = state.index, state.nextSung(after: i) == nil, state.clock.playing else { return }
        let remaining = trackDuration - state.clock.playbackTime()
        guard remaining > 0, remaining <= 8 else { return }
        encoreOfferedFor = state.id
        guard say("encore? ↺  click", for: remaining + 6) else { return }
        encoreTrackID = trackID
        encoreUntil = Date().addingTimeInterval(remaining + 6)
    }

    /// A click on the lyrics: true if it was used for the encore.
    func consumeClick() -> Bool {
        guard enabled, let until = encoreUntil, Date() < until, let id = encoreTrackID else { return false }
        endEncore()
        onEncore?(id)
        return true
    }

    private func endEncore() {
        encoreTrackID = nil
        guard encoreUntil != nil else { return }
        encoreUntil = nil
        hideToast()
    }

    // MARK: Toast

    /// A one-off hint above the lyrics. Not an easter egg: shown even when they are switched off.
    func showHint(_ text: String, for seconds: TimeInterval) {
        say(text, for: seconds)
    }

    /// Shows a short note just above the lyrics for `seconds`; the window makes room for it. False when
    /// the lyrics are too close to the top of the screen for it to fit.
    @discardableResult
    private func say(_ text: String, for seconds: TimeInterval) -> Bool {
        guard let view, view.window?.isVisible == true else { return false }
        let ctx = view.context
        let layout = TextLayout(ctx.attributed(text, size: max(12, ctx.fontSize * 0.4), weight: .semibold, alpha: 0.85),
                                width: ctx.wrapWidth)
        let gap = ctx.fontSize * 0.08
        let room = CGSize(width: ceil(BaseRenderer.inkWidth(layout) + 2 * ctx.shadowRadius),
                          height: ceil(gap + layout.size.height + 2 * ctx.shadowRadius))
        guard view.hasRoom(above: room.height) else { return false }
        toastGeneration += 1
        let generation = toastGeneration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        toast.contentsScale = ctx.scale
        toast.layout = layout
        toast.bounds = CGRect(origin: .zero, size: layout.size)
        toast.anchorPoint = CGPoint(x: 0.5, y: 0)
        toast.position = CGPoint(x: 0, y: gap)
        ctx.applyShadow(to: toast)
        view.block.addSublayer(toast)            // on top of the words
        CATransaction.commit()
        view.accessorySize = room
        fade(toast, to: 1, duration: 0.35)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.toastGeneration == generation else { return }
            self.hideToast()
        }
        return true
    }

    private func hideToast() {
        toastGeneration += 1
        let generation = toastGeneration
        fade(toast, to: 0, duration: 0.5) { [weak self] in
            guard let self, self.toastGeneration == generation else { return }
            self.view?.accessorySize = .zero
        }
    }

    private func fade(_ l: CALayer, to value: Float, duration: TimeInterval, completion: (() -> Void)? = nil) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = l.presentation()?.opacity ?? l.opacity
        a.toValue = value
        a.duration = duration
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        l.opacity = value
        l.add(a, forKey: "toastFade")
        CATransaction.commit()
    }
}
