import AppKit
import QuartzCore
import OverlyricCore

/// Hosts the lyrics: owns the layer tree, the current style renderer, window sizing and interaction
/// (drag to move, click to open Spotify, ⌘ + scroll to resize). Styles only draw.
final class OverlayView: NSView {
    // MARK: Appearance

    var fontSize: CGFloat = Settings.defaultFontSize {
        didSet { if fontSize != oldValue { render(advancing: false) } }
    }

    var color: NSColor = .white {
        didSet { if color != oldValue { renderer.recolor(context: context) } }
    }

    var style: LyricsStyle = .classic {
        didSet {
            guard style != oldValue else { return }
            renderer.teardown()
            renderer.layer.removeFromSuperlayer()
            renderer = style.makeRenderer()
            stage.addSublayer(renderer.layer)
            render(advancing: false)
        }
    }

    /// Changes the colour, cross-fading when asked (automatic colour changes should feel calm).
    func setColor(_ c: NSColor, animated: Bool) {
        guard c != color else { return }
        if animated, window?.isVisible == true {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.45
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            stage.add(fade, forKey: "colorFade")
        }
        color = c
    }

    // MARK: Callbacks

    var onClick: (() -> Void)?
    var onResizeEnded: ((CGFloat) -> Void)?
    var onShake: (() -> Void)?

    /// Lock Position: every click passes through to what's underneath.
    var locked = false {
        didSet { updateMouseGate() }
    }

    // MARK: State

    private(set) var content: StyleContent = .empty
    private let root = QuietLayer()
    /// Everything visible lives in `stage` (so a colour cross-fade or an easter egg can act on all of it).
    let stage = QuietLayer()
    private(set) var renderer: StyleRenderer = LyricsStyle.classic.makeRenderer()
    private var layoutGeneration = 0
    private var blockSize: CGSize = .zero
    /// Where the words are (view coordinates). Only this area takes the mouse; the transparent padding
    /// around it lets clicks fall through to whatever is underneath.
    private var interactiveRect: NSRect = .zero
    private var pointerMonitor: Any?
    private var gateArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = root                 // layer-hosting: we own the tree
        wantsLayer = true
        root.addSublayer(stage)
        stage.addSublayer(renderer.layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isOpaque: Bool { false }

    deinit {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, pointerMonitor == nil else { return }
        // While the window ignores the mouse, pointer moves go to other apps: watch them (no permission
        // needed for mouse-moved) to notice the pointer arriving over the words.
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.updateMouseGate()
        }
        updateMouseGate()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render(advancing: false)
    }

    var context: RenderContext {
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let maxW = (screen?.visibleFrame.width ?? 1200) * 0.8
        return RenderContext(fontSize: fontSize, color: color,
                             wrapWidth: min(max(fontSize * 16, 320), maxW),
                             scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    }

    // MARK: Content

    func update(_ new: StyleContent) {
        let old = content
        if case .lyrics(let o) = old, case .lyrics(let n) = new, o.id == n.id, o.index == n.index {
            content = new
            if !o.clock.isEquivalent(to: n.clock) { renderer.retime(n, context: context) }
            return
        }
        guard new != old else { return }
        content = new
        render(advancing: Self.isAdvance(from: old, to: new) && window?.isVisible == true)
    }

    /// The next line started while playing (as opposed to a seek, a new song or a first show).
    private static func isAdvance(from old: StyleContent, to new: StyleContent) -> Bool {
        guard case .lyrics(let o) = old, case .lyrics(let n) = new, o.id == n.id, n.clock.playing else { return false }
        switch (o.index, n.index) {
        case (nil, 0?): return true
        case (let a?, let b?): return b == a + 1
        default: return false
        }
    }

    private func render(advancing: Bool) {
        layoutGeneration += 1
        let generation = layoutGeneration
        let ctx = context
        let P = ctx.padding
        let oldSize = blockSize
        let size = renderer.show(content, advancing: advancing, context: ctx)
        blockSize = size
        // While a line change animates, keep the window at least as big as before so the outgoing line
        // isn't clipped; the window is anchored at its top-centre so nothing on screen moves either way.
        let shown = advancing ? CGSize(width: max(size.width, oldSize.width), height: max(size.height, oldSize.height)) : size
        place(blockSize: shown, padding: P)
        if advancing, shown != size {
            DispatchQueue.main.asyncAfter(deadline: .now() + renderer.transitionDuration + 0.05) { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.place(blockSize: self.blockSize, padding: self.context.padding)
            }
        }
    }

    private func place(blockSize: CGSize, padding P: CGFloat) {
        let windowSize = NSSize(width: ceil(blockSize.width + 2 * P), height: ceil(blockSize.height + 2 * P))
        interactiveRect = NSRect(x: (windowSize.width - self.blockSize.width) / 2 - 8,
                                 y: windowSize.height - P - self.blockSize.height - 8,
                                 width: self.blockSize.width + 16, height: self.blockSize.height + 16)
        if let panel = window as? OverlayPanel {
            panel.overhang = max(0, P - 6)
            panel.setContentSizeKeepingCurrentTop(windowSize)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = CGRect(origin: .zero, size: windowSize)
        renderer.layer.position = CGPoint(x: windowSize.width / 2, y: windowSize.height - P)
        CATransaction.commit()
        updateTrackingAreas()
        updateMouseGate()
    }

    // MARK: Mouse gate

    /// Takes the mouse only while the pointer is over the words (and never when locked).
    func updateMouseGate() {
        guard let window else { return }
        let onScreen = window.convertToScreen(convert(interactiveRect, to: nil))
        let ignore = locked || !window.isVisible || !onScreen.contains(NSEvent.mouseLocation)
        if window.ignoresMouseEvents != ignore { window.ignoresMouseEvents = ignore }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let gateArea { removeTrackingArea(gateArea) }
        let area = NSTrackingArea(rect: interactiveRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        gateArea = area
    }

    override func mouseEntered(with event: NSEvent) { updateMouseGate() }
    override func mouseExited(with event: NSEvent) { updateMouseGate() }

    // MARK: Interaction

    /// Only the words are interactive.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return interactiveRect.contains(local) ? self : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Press-and-release without moving = click; moving ≥ 3 pt = drag the overlay. A tracking loop is
    /// used because the panel never becomes key and its app never activates: the dragged/up events still
    /// go to the app that received the mouse-down. Also notices a quick side-to-side shake.
    override func mouseDown(with event: NSEvent) {
        guard let panel = window as? OverlayPanel else { return }
        let startMouse = NSEvent.mouseLocation
        let startOrigin = panel.frame.origin
        var dragging = false
        var shake = ShakeDetector()
        while let e = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                      inMode: .eventTracking, dequeue: true) {
            let p = NSEvent.mouseLocation
            let dx = p.x - startMouse.x, dy = p.y - startMouse.y
            if !dragging, hypot(dx, dy) >= 3 { dragging = true }
            if dragging {
                panel.dragMove(to: NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
                if shake.feed(x: Double(p.x), time: e.timestamp) { onShake?() }
            }
            if e.type == .leftMouseUp { break }
        }
        if dragging { panel.dragEnded() } else { onClick?() }
    }

    /// ⌘ + scroll over the lyrics resizes them (scroll events reach an inactive window reliably).
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04)
        let proposed = Settings.clampFont(fontSize * (1 + delta))
        if proposed != fontSize { fontSize = proposed }
        let ended = event.phase == .ended || event.momentumPhase == .ended || !event.hasPreciseScrollingDeltas
        if ended { onResizeEnded?(fontSize) }
    }
}

extension PlaybackClock {
    /// Same timeline within 50 ms (clocks are re-derived on every refresh).
    func isEquivalent(to o: PlaybackClock) -> Bool {
        playing == o.playing && abs(playbackTime() - o.playbackTime()) < 0.05
    }
}
