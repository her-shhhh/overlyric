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

    // Geometry uses the typeset positions (line-fragment used rects and glyph locations). Glyph bounding
    // boxes are NOT used: for complex scripts such as Devanagari they are several times wider than the
    // text actually is.

    /// x (TextKit coordinates) of glyph `g`'s origin.
    private func glyphX(_ g: Int) -> CGFloat {
        manager.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minX + manager.location(forGlyphAt: g).x
    }

    private func glyph(forCharacter c: Int) -> Int { manager.glyphIndexForCharacter(at: c) }

    /// Caret x (TextKit coordinates) after character `c` within fragment `f`.
    private func caretX(after c: Int, in f: (used: CGRect, chars: NSRange)) -> CGFloat {
        let next = NSMaxRange((string.string as NSString).rangeOfComposedCharacterSequence(at: c))
        if next < NSMaxRange(f.chars) {
            let x = glyphX(glyph(forCharacter: next))
            return min(max(x, f.used.minX), f.used.maxX)
        }
        return f.used.maxX
    }

    /// TextKit-space fragments: used rect + character range.
    private lazy var rawFragments: [(used: CGRect, chars: NSRange)] = {
        var out: [(CGRect, NSRange)] = []
        let glyphs = manager.glyphRange(for: container)
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, usedRect, _, glyphRange, _ in
            var chars = self.manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            // Trailing whitespace/newlines are not part of the visible line.
            let ns = self.string.string as NSString
            while chars.length > 0, let u = UnicodeScalar(ns.character(at: NSMaxRange(chars) - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(u) { chars.length -= 1 }
            out.append((usedRect, chars))
        }
        return out
    }()

    /// Visual lines in reading order.
    lazy var fragments: [Fragment] = rawFragments.map { f in
        Fragment(rect: toLayer(f.used), characterRange: f.chars)
    }

    /// Words (runs of non-whitespace) with their rects.
    lazy var words: [Word] = {
        let ns = string.string as NSString
        var out: [Word] = []
        let regex = try! NSRegularExpression(pattern: #"\S+"#)
        for m in regex.matches(in: string.string, range: NSRange(location: 0, length: ns.length)) {
            guard let f = rawFragments.first(where: { NSLocationInRange(m.range.location, $0.chars) }) else { continue }
            let a = glyphX(glyph(forCharacter: m.range.location))
            let b = caretX(after: NSMaxRange(m.range) - 1, in: f)
            let x0 = min(a, b), x1 = max(a, b)
            let r = CGRect(x: x0, y: f.used.minY, width: max(1, x1 - x0), height: f.used.height)
            out.append(Word(text: ns.substring(with: m.range), rect: toLayer(r), characterRange: m.range))
        }
        return out
    }()

    /// Right edge (layer coordinates) after each character, per fragment, for a character-by-character
    /// reveal. Monotonic within a fragment.
    lazy var characterStops: [(fragment: Int, x: CGFloat)] = {
        var stops: [(Int, CGFloat)] = []
        let ns = string.string as NSString
        for (fi, f) in rawFragments.enumerated() {
            var c = f.chars.location
            var last = f.used.minX
            while c < NSMaxRange(f.chars) {
                let range = ns.rangeOfComposedCharacterSequence(at: c)
                last = max(last, caretX(after: c, in: f))
                stops.append((fi, last))
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

    /// Glyphs are drawn at their layout coordinates (a non-zero bounds origin crops, it never shifts).
    override func draw(in ctx: CGContext) {
        guard let layout else { return }
        layout.draw(in: ctx, bounds: CGRect(origin: .zero, size: layout.size))
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
