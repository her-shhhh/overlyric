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

    private(set) var color: NSColor = .white {
        didSet { if color != oldValue { renderer.recolor(context: context) } }
    }

    var style: LyricsStyle = .defaultStyle {
        didSet {
            guard style != oldValue else { return }
            renderer.teardown()
            renderer.layer.removeFromSuperlayer()
            renderer = style.makeRenderer()
            block.insertSublayer(renderer.layer, at: 0)
            render(advancing: false)
        }
    }

    /// Changes the colour. An animated change (automatic ones should feel calm) dims the words, recolours
    /// them and brings them back. Not a cross-fade: that would freeze a snapshot of moving lyrics and
    /// show them twice.
    func setColor(_ c: NSColor, animated: Bool) {
        guard c != (dipColor ?? color) else { return }
        guard animated, window?.isVisible == true else {
            dipColor = nil
            stage.removeAnimation(forKey: "colorDip")
            color = c
            return
        }
        let dipping = dipColor != nil
        dipColor = c
        guard !dipping else { return }          // the running dip lands on the newest colour
        let down = CABasicAnimation(keyPath: "opacity")
        down.fromValue = stage.presentation()?.opacity ?? 1      // may still be coming back from the last dip
        down.toValue = Self.dipOpacity
        down.duration = 0.18
        down.timingFunction = CAMediaTimingFunction(name: .easeIn)
        down.fillMode = .forwards
        down.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.finishColorDip() }
        stage.add(down, forKey: "colorDip")
        CATransaction.commit()
    }

    private static let dipOpacity: Float = 0.3

    private func finishColorDip() {
        guard let c = dipColor else { return }
        dipColor = nil
        color = c
        let up = CABasicAnimation(keyPath: "opacity")
        up.fromValue = Self.dipOpacity
        up.toValue = 1
        up.duration = 0.3
        up.timingFunction = CAMediaTimingFunction(name: .easeOut)
        stage.add(up, forKey: "colorDip")
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

    private var content: StyleContent = .empty
    private let root = QuietLayer()
    /// Everything visible lives in `stage` (so a colour change can act on all of it).
    private let stage = QuietLayer()
    /// Moves with the words: holds the renderer's layer and the easter eggs' toast and particles. Its
    /// origin is the top-centre of the words.
    let block = QuietLayer()
    private(set) var renderer: StyleRenderer = LyricsStyle.defaultStyle.makeRenderer()
    private var layoutGeneration = 0
    private var blockSize: CGSize = .zero
    /// Where the words rest on screen (screen coordinates).
    private var wordsFrame: NSRect?
    /// While a line change plays out: the largest block still on screen and how far from its resting
    /// place the block started, so the window keeps covering the outgoing words until they're gone.
    private var hold: (size: CGSize, offset: CGVector)?
    private var dipColor: NSColor?
    /// Room the window keeps above the words for a short note (the easter-egg toast), centred on them.
    var accessorySize: CGSize = .zero {
        didSet { if accessorySize != oldValue { relayout() } }
    }
    /// Where the words are (view coordinates). Only this area takes the mouse; the transparent padding
    /// around it lets clicks fall through to whatever is underneath.
    private var interactiveRect: NSRect = .zero
    private var pointerMonitor: Any?
    private var gateArea: NSTrackingArea?
    /// A plain scroll over the words hands the mouse to the window underneath: for a second, then until
    /// the pointer next moves.
    private var scrollThroughUntil = Date.distantPast
    private var resizeGeneration = 0
    private var resizePending = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = root                 // layer-hosting: we own the tree
        wantsLayer = true
        root.addSublayer(stage)
        stage.addSublayer(block)
        block.addSublayer(renderer.layer)
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
        // Usually called from inside a window move: lay out again once that has finished.
        DispatchQueue.main.async { [weak self] in self?.render(advancing: false) }
    }

    var context: RenderContext {
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let maxW = (screen?.visibleFrame.width ?? 1200) * 0.8
        let wrap = min(max(fontSize * 16, 320), maxW)
        return RenderContext(fontSize: fontSize, color: color,
                             wrapWidth: 2 * floor(wrap / 2),     // even: a centred line's edges land on whole points
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

    /// The song moved on to a later line while playing (as opposed to a seek, a new song or a first show).
    /// Lines too short for the boundary timer to catch still count, as long as the step happened just now.
    private static func isAdvance(from old: StyleContent, to new: StyleContent) -> Bool {
        guard case .lyrics(let o) = old, case .lyrics(let n) = new, o.id == n.id, n.clock.playing,
              let b = n.index else { return false }
        let first = (o.index ?? -1) + 1          // the first line after the one that was showing
        return b >= first && n.clock.playbackTime() - n.start(first) < 1
    }

    private func render(advancing: Bool) {
        layoutGeneration += 1
        let generation = layoutGeneration
        let fromTop = advancing ? currentWordsTop : nil
        let oldSize = blockSize
        blockSize = renderer.show(content, advancing: advancing, context: context)
        guard let fromTop, let panel = window as? OverlayPanel else {
            hold = nil
            block.removeAnimation(forKey: "slide")
            relayout()
            return
        }
        let rest = restingWords(panel, padding: context.padding)
        let offset = CGVector(dx: fromTop.x - rest.midX, dy: fromTop.y - rest.maxY)
        let held = hold?.size ?? .zero
        hold = (CGSize(width: max(oldSize.width, held.width), height: max(oldSize.height, held.height)), offset)
        relayout()
        if abs(offset.dx) > 0.5 || abs(offset.dy) > 0.5 {
            // The new line rests elsewhere (one of them had to be pushed in from a screen edge): glide
            // there with the line change instead of jumping.
            let slide = CABasicAnimation(keyPath: "position")
            slide.isAdditive = true
            slide.fromValue = NSValue(point: NSPoint(x: offset.dx, y: offset.dy))
            slide.toValue = NSValue(point: .zero)
            slide.duration = renderer.transitionDuration
            slide.timingFunction = BaseRenderer.ease
            block.add(slide, forKey: "slide")
        } else {
            block.removeAnimation(forKey: "slide")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + renderer.transitionDuration + 0.05) { [weak self] in
            guard let self, self.layoutGeneration == generation else { return }
            self.hold = nil
            self.relayout()
        }
    }

    /// Where the top-centre of the words is drawn right now (screen coordinates), mid-glide included.
    private var currentWordsTop: NSPoint? {
        guard let wordsFrame else { return nil }
        var top = NSPoint(x: wordsFrame.midX, y: wordsFrame.maxY)
        if block.animation(forKey: "slide") != nil, let shown = block.presentation() {
            top.x += shown.position.x - block.position.x
            top.y += shown.position.y - block.position.y
        }
        return top
    }

    /// Where the words rest: their top-centre `padding` below the user's anchor, moved in just enough to
    /// keep them on screen, on whole device pixels.
    private func restingWords(_ panel: OverlayPanel, padding P: CGFloat) -> NSRect {
        let anchor = panel.anchorTop
        let r = panel.clampText(NSRect(x: anchor.x - blockSize.width / 2, y: anchor.y - P - blockSize.height,
                                       width: blockSize.width, height: blockSize.height))
        let s = window?.backingScaleFactor ?? 2
        let top = NSPoint(x: (r.midX * s).rounded() / s, y: (r.maxY * s).rounded() / s)
        return NSRect(x: top.x - r.width / 2, y: top.y - r.height, width: r.width, height: r.height)
    }

    /// Sizes and places the window around the words, plus the outgoing words while a line change plays
    /// out and the room asked for above them.
    func relayout() {
        guard let panel = window as? OverlayPanel else { return }
        let P = context.padding
        let words = restingWords(panel, padding: P)
        wordsFrame = words
        let top = NSPoint(x: words.midX, y: words.maxY)
        var extent = blockSize
        var tops = [top]
        if let hold {
            extent = CGSize(width: max(extent.width, hold.size.width), height: max(extent.height, hold.size.height))
            tops.append(NSPoint(x: top.x + hold.offset.dx, y: top.y + hold.offset.dy))
        }
        var frame = NSRect.null
        for t in tops {
            frame = frame.union(NSRect(x: t.x - extent.width / 2 - P, y: t.y - extent.height - P,
                                       width: extent.width + 2 * P, height: extent.height + 2 * P))
            if accessorySize != .zero { frame = frame.union(accessoryRect(at: t)) }
        }
        frame = NSRect(x: floor(frame.minX), y: floor(frame.minY),
                       width: ceil(frame.maxX) - floor(frame.minX), height: ceil(frame.maxY) - floor(frame.minY))
        if frame != panel.frame {
            panel.setFrame(frame, display: false, animate: false)   // the layer transaction below draws it
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = bounds
        block.position = CGPoint(x: top.x - frame.minX, y: top.y - frame.minY)
        CATransaction.commit()
        var hot = words.insetBy(dx: -8, dy: -8)
        if accessorySize != .zero { hot = hot.union(accessoryRect(at: top)) }
        interactiveRect = hot.offsetBy(dx: -frame.minX, dy: -frame.minY)
        updateTrackingAreas()
        updateMouseGate()
    }

    private func accessoryRect(at top: NSPoint) -> NSRect {
        NSRect(x: top.x - accessorySize.width / 2, y: top.y, width: accessorySize.width, height: accessorySize.height)
    }

    /// Whether `height` points fit between the top of the words and the top of the usable screen.
    func hasRoom(above height: CGFloat) -> Bool {
        guard let panel = window as? OverlayPanel, let wordsFrame, let screen = panel.screen(for: wordsFrame) else { return false }
        return wordsFrame.maxY + height <= screen.visibleFrame.maxY
    }

    // MARK: Mouse gate

    /// Takes the mouse only while the pointer is over the words (and never when locked).
    func updateMouseGate() {
        guard let window else { return }
        let onScreen = window.convertToScreen(convert(interactiveRect, to: nil))
        let ignore = locked || !window.isVisible || Date() < scrollThroughUntil || !onScreen.contains(NSEvent.mouseLocation)
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
    /// The full settings menu on right-click / Control-click on the lyrics — handy when the menu-bar icon
    /// is hidden behind the notch.
    var contextMenu: NSMenu?

    override func rightMouseDown(with event: NSEvent) {
        guard let contextMenu else { return }
        NSMenu.popUpContextMenu(contextMenu, with: event, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        guard let panel = window as? OverlayPanel, let words = wordsFrame else { return }
        let P = context.padding
        let startMouse = NSEvent.mouseLocation
        var dragging = false
        var shake = ShakeDetector()
        while let e = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                      inMode: .eventTracking, dequeue: true) {
            let p = NSEvent.mouseLocation
            let dx = p.x - startMouse.x, dy = p.y - startMouse.y
            if !dragging, hypot(dx, dy) >= 3 { dragging = true }
            if dragging {
                // The anchor follows the pointer, so a line change mid-drag lays out where the words are.
                panel.setAnchor(NSPoint(x: words.midX + dx, y: words.maxY + dy + P), save: false)
                relayout()
                if shake.feed(x: Double(p.x), time: e.timestamp) { onShake?() }
            }
            if e.type == .leftMouseUp { break }
        }
        guard dragging else { onClick?(); return }
        // Remember where the words visibly ended up (pushed back on screen if dragged past an edge).
        if let kept = wordsFrame { panel.setAnchor(NSPoint(x: kept.midX, y: kept.maxY + P), save: true) }
    }

    /// ⌘ + scroll over the lyrics resizes them (scroll events reach an inactive window reliably). Plain
    /// scrolling is handed to the window underneath.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            commitResize()                       // ⌘ released before the gesture ended
            scrollThroughUntil = Date().addingTimeInterval(1)
            updateMouseGate()
            return
        }
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04)
        let proposed = Settings.clampFont(fontSize * (1 + delta))
        if proposed != fontSize { fontSize = proposed }
        // Saved once the gesture (and its momentum) has settled.
        resizePending = true
        resizeGeneration += 1
        let generation = resizeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.resizeGeneration == generation else { return }
            self.commitResize()
        }
    }

    private func commitResize() {
        guard resizePending else { return }
        resizePending = false
        resizeGeneration += 1
        onResizeEnded?(fontSize)
    }
}

extension PlaybackClock {
    /// Same timeline within 50 ms (clocks are re-derived on every refresh).
    func isEquivalent(to o: PlaybackClock) -> Bool {
        playing == o.playing && abs(playbackTime() - o.playbackTime()) < 0.05
    }
}
