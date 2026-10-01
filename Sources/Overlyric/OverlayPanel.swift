import AppKit

/// Borderless, transparent, always-on-top, non-activating panel. OverlayView sizes and places it around
/// the lyrics; the panel remembers where the user put them and keeps the text on screen.
final class OverlayPanel: NSPanel {
    let overlayView = OverlayView()
    /// The window top-centre the user chose. The lyrics are laid out from here every time, so a line that
    /// had to be pushed in from a screen edge never moves the ones after it.
    private(set) var anchorTop = OverlayPanel.defaultTop()

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
        level = .statusBar
        isMovableByWindowBackground = false     // OverlayView drags by hand so a click can be told apart
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        contentView = overlayView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Moves the lyrics so the window's top-centre is at `top` (or the default subtitle position).
    func moveTop(to top: NSPoint?) {
        anchorTop = top ?? Self.defaultTop()
        overlayView.relayout()
    }

    /// Follows a drag; `save` persists the spot (at the end of the drag).
    func setAnchor(_ top: NSPoint, save: Bool) {
        anchorTop = top
        if save { Settings.shared.windowTop = top }
    }

    static func defaultTop() -> NSPoint {
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: vf.midX, y: vf.minY + vf.height * 0.16 + 70)
    }

    /// The screen the text (screen coordinates) is on: the one under its centre, else the one it overlaps
    /// most, else the main screen. Judged by the text, not the window, whose padding may reach a neighbour.
    func screen(for text: NSRect) -> NSScreen? {
        let centre = NSPoint(x: text.midX, y: text.midY)
        if let s = NSScreen.screens.first(where: { $0.frame.contains(centre) }) { return s }
        let overlap = { (s: NSScreen) -> CGFloat in
            let i = s.frame.intersection(text)
            return i.isNull ? 0 : i.width * i.height
        }
        if let best = NSScreen.screens.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 { return best }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Moves `text` (screen coordinates) the least distance that keeps it on its screen: inside the left,
    /// right and bottom edges, and below the menu bar. The window's transparent padding may hang off.
    func clampText(_ text: NSRect) -> NSRect {
        guard let screen = screen(for: text) else { return text }
        let margin: CGFloat = 6
        let sf = screen.frame
        let limit = NSRect(x: sf.minX + margin, y: sf.minY + margin, width: sf.width - 2 * margin,
                           height: screen.visibleFrame.maxY - margin - (sf.minY + margin))
        var r = text
        r.origin.x = r.width <= limit.width ? min(max(r.minX, limit.minX), limit.maxX - r.width) : limit.midX - r.width / 2
        r.origin.y = r.height <= limit.height ? min(max(r.minY, limit.minY), limit.maxY - r.height) : limit.midY - r.height / 2
        return r
    }
}
