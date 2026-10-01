import AppKit

/// Borderless, transparent, always-on-top, non-activating panel that is exactly the size of its lyrics.
final class OverlayPanel: NSPanel, NSWindowDelegate {
    let overlayView = OverlayView()
    private var suppressMoveSave = false
    /// The top-centre the user chose. Content re-sizing is anchored here, so the current line's top stays
    /// put while lines wrap/unwrap below it, and a window clamped at a screen edge never "ratchets" away.
    private var anchorTop: NSPoint?

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
        isMovableByWindowBackground = true
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
        nf = Self.clamp(nf, to: screenFor(point: t))
        guard nf != frame else { return }
        suppressMoveSave = true
        setFrame(nf, display: false, animate: false)   // the layer transaction that follows draws it
        suppressMoveSave = false
    }

    /// Moves the window so its top-centre is at `top` (or the default subtitle position).
    func moveTop(to top: NSPoint?) {
        let target = top ?? Self.defaultTop()
        anchorTop = target
        var nf = frame
        nf.origin = NSPoint(x: target.x - nf.width / 2, y: target.y - nf.height)
        nf = Self.clamp(nf, to: screenFor(point: target))
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

    private static func clamp(_ rect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let vf = screen?.visibleFrame else { return rect }
        var r = rect
        if r.width <= vf.width {
            r.origin.x = min(max(r.origin.x, vf.minX), vf.maxX - r.width)
        } else {
            r.origin.x = vf.midX - r.width / 2
        }
        if r.height <= vf.height {
            r.origin.y = min(max(r.origin.y, vf.minY), vf.maxY - r.height)
        } else {
            r.origin.y = vf.midY - r.height / 2
        }
        return r
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard !suppressMoveSave else { return }
        // Only persist drags by the user, not the system relocating us when a display disconnects.
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        anchorTop = topPoint
        Settings.shared.windowTop = topPoint
    }
}
