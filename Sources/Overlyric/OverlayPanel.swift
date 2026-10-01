import AppKit

/// Borderless, transparent, always-on-top, non-activating panel that is exactly the size of its lyrics.
final class OverlayPanel: NSPanel, NSWindowDelegate {
    let overlayView = OverlayView()
    private var suppressMoveSave = false
    /// The top-centre the user chose. Content re-sizing is anchored here, so the current line's top stays
    /// put while lines wrap/unwrap below it, and a window clamped at a screen edge never "ratchets" away.
    private var anchorTop: NSPoint?
    /// How far the transparent padding may hang off the screen edge: the TEXT, not the invisible
    /// window, is what has to stay on screen. Set by OverlayView from its current padding.
    var overhang: CGFloat = 0

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isFloatingPanel = true          // NOTE: this resets `level` to .floating, so set the level AFTER it.
        becomesKeyOnlyIfNeeded = true
        level = .statusBar
        isMovableByWindowBackground = false     // OverlayView drags by hand so a click can be told apart
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        titleVisibility = .hidden
        contentView = overlayView
        makeFirstResponder(overlayView)
        delegate = self
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Resizes the window so the content view is `size`, keeping the anchor top-centre fixed and on screen.
    func setContentSizeKeepingTop(_ size: NSSize) {
        let t = anchorTop ?? topPoint
        var nf = NSRect(x: t.x - size.width / 2, y: t.y - size.height, width: size.width, height: size.height)
        nf = clamp(nf, to: screenFor(point: t))
        guard nf != frame else { return }
        suppressMoveSave = true
        setFrame(nf, display: false, animate: false)   // the layer transaction that follows draws it
        suppressMoveSave = false
    }

    /// Like `setContentSizeKeepingTop` but anchored on the window's current top, so a frame that was
    /// clamped at a screen edge doesn't hop when it shrinks after a transition.
    func setContentSizeKeepingCurrentTop(_ size: NSSize) {
        let t = topPoint
        var nf = NSRect(x: t.x - size.width / 2, y: t.y - size.height, width: size.width, height: size.height)
        nf = clamp(nf, to: screenFor(point: t))
        guard nf != frame else { return }
        suppressMoveSave = true
        setFrame(nf, display: false, animate: false)
        suppressMoveSave = false
    }

    /// Live drag from OverlayView (clamped as it goes; persisted when the drag ends).
    func dragMove(to origin: NSPoint) {
        var f = frame
        f.origin = origin
        f = clamp(f, to: screenFor(point: NSEvent.mouseLocation))
        suppressMoveSave = true
        setFrameOrigin(f.origin)
        suppressMoveSave = false
    }

    /// End of a user drag: keep the overlay reachable on screen and remember where it was put.
    func dragEnded() {
        let f = clamp(frame, to: screenFor(point: NSPoint(x: frame.midX, y: frame.midY)))
        if f != frame {
            suppressMoveSave = true
            setFrame(f, display: true, animate: false)
            suppressMoveSave = false
        }
        anchorTop = topPoint
        Settings.shared.windowTop = topPoint
    }

    /// Moves the window so its top-centre is at `top` (or the default subtitle position).
    func moveTop(to top: NSPoint?) {
        let target = top ?? Self.defaultTop()
        anchorTop = target
        var nf = frame
        nf.origin = NSPoint(x: target.x - nf.width / 2, y: target.y - nf.height)
        nf = clamp(nf, to: screenFor(point: target))
        suppressMoveSave = true
        setFrame(nf, display: true, animate: false)
        suppressMoveSave = false
    }

    var topPoint: NSPoint { NSPoint(x: frame.midX, y: frame.maxY) }

    static func defaultTop() -> NSPoint {
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: vf.midX, y: vf.minY + vf.height * 0.16 + 70)
    }

    private func screenFor(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? screen ?? NSScreen.main
    }

    /// Keeps the lyrics on screen: the left, right and bottom edges of the screen are the limit for the
    /// text (the window's transparent padding may hang off them), and the text never covers the menu bar.
    private func clamp(_ rect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let screen else { return rect }
        let sf = screen.frame, top = screen.visibleFrame.maxY
        let limit = NSRect(x: sf.minX - overhang, y: sf.minY - overhang,
                           width: sf.width + 2 * overhang, height: (top + overhang) - (sf.minY - overhang))
        var r = rect
        if r.width <= limit.width {
            r.origin.x = min(max(r.origin.x, limit.minX), limit.maxX - r.width)
        } else {
            r.origin.x = limit.midX - r.width / 2
        }
        if r.height <= limit.height {
            r.origin.y = min(max(r.origin.y, limit.minY), limit.maxY - r.height)
        } else {
            r.origin.y = limit.midY - r.height / 2
        }
        return r
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        // User drags are persisted in dragEnded(); moves made by the system (display disconnected)
        // are deliberately not saved, so the overlay returns when the display comes back.
    }
}
