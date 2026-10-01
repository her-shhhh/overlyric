import AppKit
import QuartzCore

/// A Core Animation layer that draws one lyric line with AppKit text rendering.
final class LineLayer: CALayer {
    var attributedText: NSAttributedString? {
        didSet { setNeedsDisplay() }
    }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        masksToBounds = false
        isOpaque = false
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// No implicit animations: a redraw must not cross-fade old and new text, and only the
    /// explicit transition animations may move/scale/fade the layer.
    override func action(forKey event: String) -> CAAction? { nil }

    override func draw(in ctx: CGContext) {
        guard let text = attributedText else { return }
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        text.draw(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Draws the two lyric lines (current + next) in the "story lyrics" style: heavy rounded type,
/// centred, soft shadow, no box. Line changes are animated purely on the compositor.
/// Handles pinch-to-zoom and drag-to-move itself.
final class OverlayView: NSView {
    enum Content: Equatable {
        case empty
        /// `nil` or "" renders as ♪ (instrumental / before the first line).
        case lines(current: String?, next: String?)
        /// Small dim status text (e.g. no lyrics found).
        case note(String)
    }

    /// Point size of the current line. Setting it re-lays out immediately (no animation).
    var fontSize: CGFloat = Settings.defaultFontSize {
        didSet { if fontSize != oldValue { relayout(animated: false) } }
    }
    var color: NSColor = .white {
        didSet { if color != oldValue { relayout(animated: false) } }
    }
    /// Called at the end of a pinch gesture with the final size (for persistence).
    var onZoomEnded: ((CGFloat) -> Void)?

    /// Changes the colour with a short cross-fade (used by auto-contrast so switches feel calm).
    func setColor(_ c: NSColor, animated: Bool) {
        guard c != color else { return }
        if animated, window?.isVisible == true {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.45
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            root.add(fade, forKey: "colorFade")
        }
        color = c
    }

    private(set) var content: Content = .empty
    private var pinchStartSize: CGFloat = 0
    private var globalPinchMonitor: Any?
    private let root = CALayer()
    private let currentLayer = LineLayer()
    private let nextLayer = LineLayer()
    private var ghosts: [LineLayer] = []

    private static let padding: CGFloat = 20
    private static let nextAlpha: Float = 0.55
    private static let nextScale: CGFloat = 0.86
    private static let duration: TimeInterval = 0.42
    private static let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
    private var layoutGeneration = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        root.masksToBounds = false
        // No implicit animations on the root: adding/removing the ghost sublayer would otherwise trigger
        // CA's default 0.25 s fade of the whole layer tree (that was the "doubled text" glitch).
        root.actions = ["sublayers": NSNull(), "contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer = root                 // layer-hosting: we own the sublayer tree
        wantsLayer = true
        root.addSublayer(nextLayer)
        root.addSublayer(currentLayer)
        nextLayer.opacity = Self.nextAlpha
        updateScale()
        addGestureRecognizer(NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let m = globalPinchMonitor { NSEvent.removeMonitor(m) }
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
        window?.makeFirstResponder(self)
        installGlobalPinchFallback()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
        relayout(animated: false)
    }

    private func setRasterizes(_ on: Bool) {
        // Rasterization is intentionally off: with it on, Core Animation drew a second, offset copy of
        // each layer while it was animating.
    }

    private func updateScale() {
        let s = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for l in [currentLayer, nextLayer] + ghosts {
            l.contentsScale = s
        }
    }

    // MARK: Interaction

    /// Only the lyric text (with a comfortable margin) is the grab area, not the transparent padding.
    /// Dragging is handled by the window server through `isMovableByWindowBackground` +
    /// `mouseDownCanMoveWindow` (verified: `performDrag` does nothing for a non-key panel of an inactive app).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return grabRect.contains(local) ? self : nil
    }

    private var grabRect: NSRect = .zero

    override var mouseDownCanMoveWindow: Bool { true }

    /// ⌘ + scroll over the lyrics also zooms (scroll events reach an inactive panel reliably).
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04)
        let proposed = Settings.clampFont(fontSize * (1 + delta))
        if proposed != fontSize { fontSize = proposed }
        if event.phase == .ended || event.momentumPhase == .ended || (!event.hasPreciseScrollingDeltas) {
            onZoomEnded?(fontSize)
        }
    }

    /// Trackpad pinch over the lyrics: scales the text live around the window centre.
    @objc private func handlePinch(_ g: NSMagnificationGestureRecognizer) {
        switch g.state {
        case .began:
            pinchStartSize = fontSize
            setRasterizes(false)      // no cache churn while the text is re-laid-out every event
        case .changed:
            if pinchStartSize == 0 { pinchStartSize = fontSize; setRasterizes(false) }
            fontSize = Settings.clampFont(pinchStartSize * (1 + g.magnification))
        case .ended, .cancelled, .failed:
            pinchStartSize = 0
            setRasterizes(true)
            onZoomEnded?(fontSize)
        default:
            break
        }
    }

    /// Fallback: when this app is inactive the system may hand the pinch to the active app instead of
    /// the window under the pointer. A global monitor sees those events; if the pointer is over the
    /// lyrics we zoom anyway (delta-based, since global events carry per-event magnification).
    private func installGlobalPinchFallback() {
        guard globalPinchMonitor == nil else { return }
        globalPinchMonitor = NSEvent.addGlobalMonitorForEvents(matching: .magnify) { [weak self] event in
            let delta = event.magnification
            let phase = event.phase
            DispatchQueue.main.async {
                guard let self, let panel = self.window, panel.isVisible, !panel.ignoresMouseEvents,
                      panel.frame.contains(NSEvent.mouseLocation) else { return }
                let proposed = Settings.clampFont(self.fontSize * (1 + delta))
                if proposed != self.fontSize { self.fontSize = proposed }
                if phase == .ended || phase == .cancelled { self.onZoomEnded?(self.fontSize) }
            }
        }
    }

    // MARK: Content

    func update(_ new: Content, animated: Bool) {
        guard new != content else { return }
        let old = content
        content = new
        relayout(animated: animated && Self.isLineToLine(old, new))
    }

    private static func isLineToLine(_ a: Content, _ b: Content) -> Bool {
        if case .lines = a, case .lines = b { return true }
        return false
    }

    // MARK: Layout (non-flipped: origin bottom-left; next line sits under the current line)

    private struct Layout {
        var size: NSSize
        var current: NSRect
        var next: NSRect
        var showNext: Bool
        /// Visual extent of the text (current + scaled next), for hit-testing.
        var textRect: NSRect
    }

    private func wrapWidth() -> CGFloat {
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let maxW = (screen?.visibleFrame.width ?? 1200) * 0.8
        return min(max(fontSize * 16, 320), maxW)
    }

    /// Padding must contain the glyph shadow (≈ 2 × radius + offset) and most of the ghost's upward travel
    /// (0.6 × size), otherwise the window edge clips them.
    private var padding: CGFloat {
        max(Self.padding, 2 * shadowRadius + shadowOffsetY + 2, ceil(fontSize * 0.7))
    }
    private var shadowRadius: CGFloat { max(3, fontSize / 7) }
    private var shadowOffsetY: CGFloat { max(1, fontSize / 28) }

    private func assignTextAndMeasure() -> Layout {
        let S = fontSize
        let P = padding
        let W = wrapWidth()
        let gap = S * 0.2

        var showNext = false
        switch content {
        case .empty:
            currentLayer.attributedText = styled("", .current)
        case .lines(let c, let n):
            currentLayer.attributedText = styled(Self.displayText(c), .current)
            // A gap (♪) is only shown as the current line, never previewed as "next".
            if let n, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nextLayer.attributedText = styled(Self.displayText(n), .next)
                showNext = true
            }
        case .note(let s):
            currentLayer.attributedText = styled(s, .note)
        }

        // The next layer is drawn at full size and scaled by `nextScale`, so it is measured at the
        // wider unscaled width; its visual width then equals W.
        let WN = W / Self.nextScale
        let hC = Self.measuredHeight(currentLayer.attributedText, width: W)
        let hN = showNext ? Self.measuredHeight(nextLayer.attributedText, width: WN) : 0
        let visualN = hN * Self.nextScale
        // `next` is the UNscaled box positioned so its scaled image sits flush at the bottom padding.
        let next = NSRect(x: P + (W - WN) / 2, y: P + visualN / 2 - hN / 2, width: WN, height: hN)
        let current = NSRect(x: P, y: P + (showNext ? visualN + gap : 0), width: W, height: hC)
        let height = P + hC + (showNext ? gap + visualN : 0) + P
        let textRect = NSRect(x: P, y: P, width: W, height: height - 2 * P)
        return Layout(size: NSSize(width: ceil(W + 2 * P), height: ceil(height)), current: current, next: next,
                      showNext: showNext, textRect: textRect)
    }

    private static func displayText(_ s: String?) -> String {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "♪" : t
    }

    private static func measuredHeight(_ text: NSAttributedString?, width: CGFloat) -> CGFloat {
        guard let text, text.length > 0 else { return 0 }
        let r = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(r.height) + 2
    }

    private func relayout(animated: Bool) {
        layoutGeneration += 1
        let generation = layoutGeneration
        let oldCurrentText = currentLayer.attributedText
        // If a transition is still running, start from where the lines visibly are, not their model slots.
        let inFlight = currentLayer.animation(forKey: "lineTransition") != nil
        let oldCurrentFrame = (inFlight ? currentLayer.presentation() : nil)?.frameIgnoringTransform ?? currentLayer.frameIgnoringTransform
        let oldNextFrame = (inFlight ? nextLayer.presentation() : nil)?.frameIgnoringTransform ?? nextLayer.frameIgnoringTransform
        let oldNextVisible = !nextLayer.isHidden && nextLayer.opacity > 0
        let oldOrigin = window?.frame.origin ?? .zero
        let oldSize = bounds.size

        let L = assignTextAndMeasure()
        let animating = animated && window?.isVisible == true
        // While a transition plays, never shrink the window: the outgoing lines need the room. The window
        // is anchored at its top-centre, so content hugs the top and only the empty bottom is deferred.
        let shown = animating
            ? NSSize(width: max(L.size.width, oldSize.width), height: max(L.size.height, oldSize.height))
            : L.size
        let offset = NSPoint(x: (shown.width - L.size.width) / 2, y: shown.height - L.size.height)
        (window as? OverlayPanel)?.setContentSizeKeepingTop(shown)
        applyShadows()
        let newOrigin = window?.frame.origin ?? .zero
        grabRect = L.textRect.offsetBy(dx: offset.x, dy: offset.y).insetBy(dx: -10, dy: -8)
        window?.invalidateCursorRects(for: self)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for g in ghosts { g.removeFromSuperlayer() }
        ghosts.removeAll()
        currentLayer.removeAllAnimations()
        nextLayer.removeAllAnimations()
        nextLayer.isHidden = !L.showNext
        let current = L.current.offsetBy(dx: offset.x, dy: offset.y)
        let next = L.next.offsetBy(dx: offset.x, dy: offset.y)
        place(currentLayer, in: current)
        place(nextLayer, in: next, scale: Self.nextScale)
        currentLayer.opacity = 1
        nextLayer.opacity = Self.nextAlpha

        guard animating else { CATransaction.commit(); return }

        // The window moved/resized, so old content shifted by the window-origin delta in our coordinates.
        let dx = oldOrigin.x - newOrigin.x
        let dy = oldOrigin.y - newOrigin.y
        let travel = fontSize * 0.45

        // 1. The old current line drifts up and fades out (inserted inside the no-actions transaction).
        var ghost: LineLayer?
        var ghostStart = NSRect.zero
        if let oldCurrentText, oldCurrentText.length > 0 {
            let g = LineLayer()
            g.attributedText = oldCurrentText
            g.contentsScale = currentLayer.contentsScale
            copyShadow(from: currentLayer, to: g)
            root.insertSublayer(g, below: nextLayer)
            ghosts.append(g)
            ghostStart = oldCurrentFrame.offsetBy(dx: dx, dy: dy)
            place(g, in: ghostStart)
            ghost = g
        }
        CATransaction.commit()

        if let ghost {
            animate(ghost, from: (ghostStart.center, 1, 1),
                    to: (CGPoint(x: ghostStart.midX, y: ghostStart.midY + travel), 0.94, 0)) { [weak self, weak ghost] in
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                ghost?.removeFromSuperlayer()
                CATransaction.commit()
                if let ghost { self?.ghosts.removeAll { $0 === ghost } }
            }
        }

        // 2. The next line rises into the current slot, growing and brightening.
        let riseFrom: CGPoint = oldNextVisible
            ? oldNextFrame.offsetBy(dx: dx, dy: dy).center
            : CGPoint(x: current.midX, y: current.midY - travel)
        animate(currentLayer, from: (riseFrom, Self.nextScale, Self.nextAlpha), to: (current.center, 1, 1))

        // 3. The new next line fades in from just below its slot.
        if L.showNext {
            animate(nextLayer, from: (CGPoint(x: next.midX, y: next.midY - travel * 0.7), Self.nextScale * 0.92, 0),
                    to: (next.center, Self.nextScale, Self.nextAlpha))
        }

        // 4. Once the transition is over, drop the deferred empty space (no visual change: content hugs the top).
        if shown != L.size {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration + 0.05) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.layoutGeneration == generation else { return }
                    self.settle(to: L, from: offset)
                }
            }
        }
    }

    /// Shrinks the window to the exact content size after a transition, shifting layers so nothing moves on screen.
    private func settle(to L: Layout, from offset: NSPoint) {
        (window as? OverlayPanel)?.setContentSizeKeepingTop(L.size)
        grabRect = L.textRect.insetBy(dx: -10, dy: -8)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for g in ghosts { g.removeFromSuperlayer() }
        ghosts.removeAll()
        currentLayer.removeAllAnimations()
        nextLayer.removeAllAnimations()
        place(currentLayer, in: L.current)
        place(nextLayer, in: L.next, scale: Self.nextScale)
        currentLayer.opacity = 1
        nextLayer.opacity = Self.nextAlpha
        CATransaction.commit()
    }

    private func place(_ layer: CALayer, in frame: NSRect, scale: CGFloat = 1) {
        layer.transform = scale == 1 ? CATransform3DIdentity : CATransform3DMakeScale(scale, scale, 1)
        layer.bounds = NSRect(origin: .zero, size: frame.size)
        layer.position = frame.center
    }

    private func animate(_ layer: CALayer,
                         from: (position: CGPoint, scale: CGFloat, opacity: Float),
                         to: (position: CGPoint, scale: CGFloat, opacity: Float),
                         completion: (() -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        layer.position = to.position
        layer.transform = CATransform3DMakeScale(to.scale, to.scale, 1)
        layer.opacity = to.opacity

        let pos = CABasicAnimation(keyPath: "position")
        pos.fromValue = NSValue(point: from.position)
        pos.toValue = NSValue(point: to.position)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = from.scale
        scale.toValue = to.scale
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = from.opacity
        opacity.toValue = to.opacity

        let group = CAAnimationGroup()
        group.animations = [pos, scale, opacity]
        group.duration = Self.duration
        group.timingFunction = Self.timing
        layer.add(group, forKey: "lineTransition")   // never "transition": that key is CA's own kCATransition slot
        CATransaction.commit()
    }

    // MARK: Styling

    private enum Style { case current, next, note }

    private func styled(_ text: String, _ style: Style) -> NSAttributedString {
        let S = fontSize
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        para.lineHeightMultiple = 0.98
        var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: para, .foregroundColor: color]
        switch style {
        case .current:
            attrs[.font] = Self.roundedFont(S, .heavy)
            attrs[.kern] = -S * 0.015
        case .next:
            // Same type as the current line; the layer is scaled down with a transform so the
            // rise into the current slot is a continuous scale-up of an identical bitmap.
            attrs[.font] = Self.roundedFont(S, .heavy)
            attrs[.kern] = -S * 0.015
        case .note:
            attrs[.font] = Self.roundedFont(max(13, S * 0.5), .medium)
            attrs[.foregroundColor] = color.withAlphaComponent(0.7)
        }
        return NSAttributedString(string: text, attributes: attrs)
    }

    private func applyShadows() {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let lum = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        let dark = lum < 0.35
        for l in [currentLayer, nextLayer] {
            l.shadowColor = (dark ? NSColor.white : NSColor.black).cgColor
            l.shadowOpacity = dark ? 0.8 : 0.6
            l.shadowRadius = shadowRadius
            l.shadowOffset = CGSize(width: 0, height: -shadowOffsetY)
        }
    }

    private func copyShadow(from a: CALayer, to b: CALayer) {
        b.shadowColor = a.shadowColor
        b.shadowOpacity = a.shadowOpacity
        b.shadowRadius = a.shadowRadius
        b.shadowOffset = a.shadowOffset
    }

    private static func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }
}

private extension CALayer {
    /// The layer's frame as if its transform were identity (frame is undefined under a transform).
    var frameIgnoringTransform: NSRect {
        NSRect(x: position.x - bounds.width / 2, y: position.y - bounds.height / 2, width: bounds.width, height: bounds.height)
    }
}

private extension NSRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
