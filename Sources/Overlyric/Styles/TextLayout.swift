import AppKit
import QuartzCore

/// TextKit layout of one lyric line at a fixed width, shared by drawing and by every style that needs
/// glyph geometry (typewriter reveal, word pops, karaoke fill). Geometry is reported in the layer's
/// coordinate space (origin bottom-left, y up), sized to `size`.
final class TextLayout {
    let string: NSAttributedString
    let width: CGFloat
    private let storage: NSTextStorage
    private let manager = NSLayoutManager()
    private let container: NSTextContainer
    /// Ink-safe size: used rect height + a little room for descenders/shadow subpixels.
    let size: CGSize

    struct Fragment {
        /// Glyph extent of the visual line (layer coordinates).
        let rect: CGRect
        let characterRange: NSRange
    }

    struct Word {
        let text: String
        let rect: CGRect               // layer coordinates
        let characterRange: NSRange
    }

    init(_ string: NSAttributedString, width: CGFloat) {
        self.string = string
        self.width = width
        storage = NSTextStorage(attributedString: string)
        container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        size = CGSize(width: width, height: ceil(used.height) + 2)
    }

    var isEmpty: Bool { string.length == 0 }

    /// Converts a TextKit (top-left, y down) rect into layer coordinates (bottom-left, y up).
    private func toLayer(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)
    }

    /// Visual lines in reading order.
    lazy var fragments: [Fragment] = {
        var out: [Fragment] = []
        let glyphs = manager.glyphRange(for: container)
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, usedRect, _, glyphRange, _ in
            let chars = self.manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let ink = self.manager.boundingRect(forGlyphRange: glyphRange, in: self.container)
            let rect = CGRect(x: ink.minX, y: usedRect.minY, width: ink.width, height: usedRect.height)
            out.append(Fragment(rect: self.toLayer(rect), characterRange: chars))
        }
        return out
    }()

    /// Words (runs of non-whitespace) with their glyph rects.
    lazy var words: [Word] = {
        let ns = string.string as NSString
        var out: [Word] = []
        let regex = try! NSRegularExpression(pattern: #"\S+"#)
        for m in regex.matches(in: string.string, range: NSRange(location: 0, length: ns.length)) {
            let glyphs = manager.glyphRange(forCharacterRange: m.range, actualCharacterRange: nil)
            let r = manager.boundingRect(forGlyphRange: glyphs, in: container)
            // Use the full line height so words of one visual line share a baseline box.
            var lineRect = manager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            lineRect.origin.x = r.minX
            lineRect.size.width = r.width
            out.append(Word(text: ns.substring(with: m.range), rect: toLayer(lineRect), characterRange: m.range))
        }
        return out
    }()

    /// x positions (layer coordinates) of the right edge of each character within its fragment, used for
    /// a character-by-character reveal. Returned per fragment: [(fragmentIndex, rightEdgeX)] in order.
    lazy var characterStops: [(fragment: Int, x: CGFloat)] = {
        var stops: [(Int, CGFloat)] = []
        for (fi, f) in fragments.enumerated() {
            var c = f.characterRange.location
            while c < NSMaxRange(f.characterRange) {
                let range = (string.string as NSString).rangeOfComposedCharacterSequence(at: c)
                let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let r = manager.boundingRect(forGlyphRange: glyphs, in: container)
                stops.append((fi, max(r.maxX, f.rect.minX)))
                c = NSMaxRange(range)
            }
        }
        return stops
    }()

    /// Draws the text into a layer context (bottom-left origin) whose bounds are `size`.
    func draw(in ctx: CGContext, bounds: CGRect) {
        let glyphs = manager.glyphRange(for: container)
        ctx.saveGState()
        ctx.translateBy(x: bounds.minX, y: bounds.minY + size.height)
        ctx.scaleBy(x: 1, y: -1)
        let g = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        manager.drawBackground(forGlyphRange: glyphs, at: .zero)
        manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }
}

/// A Core Animation layer that draws a `TextLayout`. No implicit animations: only explicit ones move it.
final class TextLayer: CALayer {
    var layout: TextLayout? {
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

    override func action(forKey event: String) -> CAAction? { nil }

    override func draw(in ctx: CGContext) {
        layout?.draw(in: ctx, bounds: bounds)
    }
}

/// A plain container layer without implicit animations.
final class QuietLayer: CALayer {
    override init() { super.init(); masksToBounds = false }
    override init(layer: Any) { super.init(layer: layer) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
    override func action(forKey event: String) -> CAAction? { nil }
}
