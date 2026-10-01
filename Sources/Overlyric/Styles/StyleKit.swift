import AppKit
import QuartzCore
import OverlyricCore

/// The lyric presentation styles offered in the menu (Instagram-inspired).
enum LyricsStyle: String, CaseIterable {
    // Menu order; the first case is the default style.
    case dynamic, jump, classic, single, scroll, typewriter, karaoke, pop, glide, cube

    static let defaultStyle: LyricsStyle = .dynamic

    var title: String {
        switch self {
        case .classic: return "Two Lines"
        case .single: return "One Line"
        case .scroll: return "Scrolling Lyrics"
        case .typewriter: return "Typewriter"
        case .karaoke: return "Karaoke"
        case .dynamic: return "Dynamic"
        case .pop: return "Pop"
        case .jump: return "Jump"
        case .glide: return "Glide"
        case .cube: return "Cube"
        }
    }

    var subtitle: String {
        switch self {
        case .classic: return "Current line and the next one"
        case .single: return "Just the line being sung"
        case .scroll: return "The whole song drifting upwards"
        case .typewriter: return "Types out as it's sung"
        case .karaoke: return "Words light up as they're sung"
        case .dynamic: return "Big billboard rows, words popping in"
        case .pop: return "Words flash on one at a time"
        case .jump: return "Words jump up into place as they are sung"
        case .glide: return "Lyrics glide right to left like a ticker"
        case .cube: return "Lines roll upwards like a cube"
        }
    }

    @MainActor func makeRenderer() -> StyleRenderer {
        switch self {
        case .classic: return ClassicRenderer()
        case .single: return SingleRenderer()
        case .scroll: return ScrollRenderer()
        case .typewriter: return TypewriterRenderer()
        case .karaoke: return KaraokeRenderer()
        case .dynamic: return DynamicRenderer()
        case .pop: return PopRenderer()
        case .jump: return JumpRenderer()
        case .glide: return GlideRenderer()
        case .cube: return CubeRenderer()
        }
    }
}

/// Maps Spotify playback time to Core Animation host time (CACurrentMediaTime).
struct PlaybackClock: Equatable {
    var position: TimeInterval        // playback position at `hostTime`
    var hostTime: CFTimeInterval
    var playing: Bool

    func playbackTime(at host: CFTimeInterval = CACurrentMediaTime()) -> TimeInterval {
        playing ? position + (host - hostTime) : position
    }

    /// The host time at which playback reaches `playback` (only meaningful while playing).
    func hostTime(of playback: TimeInterval) -> CFTimeInterval {
        hostTime + (playback - position)
    }
}

/// Everything a style needs to draw the lyrics at a moment.
struct LyricsState: Equatable {
    let id: String                    // track key; a new id means a new song
    let lyrics: SyncedLyrics
    let index: Int?                   // current line; nil = before the first line
    let clock: PlaybackClock

    func text(_ i: Int?) -> String? { lyrics.text(at: i) }

    /// Start time of line `i`.
    func start(_ i: Int) -> TimeInterval { lyrics.lines[i].time }

    /// When line `i` ends: the next line's start, or a few seconds after the last line.
    func end(_ i: Int) -> TimeInterval {
        i + 1 < lyrics.lines.count ? lyrics.lines[i + 1].time : lyrics.lines[i].time + 5
    }

    /// The first non-empty line after `i` (gaps are never previewed).
    func nextSung(after i: Int?) -> Int? {
        var j = (i ?? -1) + 1
        while j < lyrics.lines.count {
            if !lyrics.lines[j].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return j }
            j += 1
        }
        return nil
    }
}

enum StyleContent: Equatable {
    case empty
    case note(String)
    case lyrics(LyricsState)
}

/// Shared typography for every style.
struct RenderContext {
    var fontSize: CGFloat
    var color: NSColor
    var wrapWidth: CGFloat
    var scale: CGFloat

    static let nextScale: CGFloat = 0.86
    static let dimAlpha: Float = 0.55

    /// Instagram's Typewriter style uses a typewriter face; American Typewriter ships with macOS.
    static let typewriterFontNames = ["AmericanTypewriter-Semibold", "AmericanTypewriter-Bold", "CourierNewPS-BoldMT"]

    func font(_ size: CGFloat, _ weight: NSFont.Weight = .heavy, typewriter: Bool = false) -> NSFont {
        if typewriter {
            for name in Self.typewriterFontNames { if let f = NSFont(name: name, size: size) { return f } }
            return NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        }
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }

    func attributed(_ text: String, size: CGFloat? = nil, weight: NSFont.Weight = .heavy, alpha: CGFloat = 1,
                    typewriter: Bool = false) -> NSAttributedString {
        let S = size ?? fontSize
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        para.lineHeightMultiple = 0.98
        return NSAttributedString(string: text, attributes: [
            .font: font(S, weight, typewriter: typewriter),
            .foregroundColor: alpha >= 1 ? color : color.withAlphaComponent(alpha),
            .paragraphStyle: para,
            .kern: typewriter ? 0 : -S * 0.015,
        ])
    }

    func layout(_ text: String, size: CGFloat? = nil, weight: NSFont.Weight = .heavy, width: CGFloat? = nil,
                typewriter: Bool = false) -> TextLayout {
        TextLayout(attributed(text, size: size, weight: weight, typewriter: typewriter), width: width ?? wrapWidth)
    }

    func noteLayout(_ text: String) -> TextLayout {
        TextLayout(attributed(text, size: max(13, fontSize * 0.5), weight: .medium, alpha: 0.7), width: wrapWidth)
    }

    /// Glyph shadow that keeps the text readable on any background (light halo for dark text).
    var shadowColor: CGColor {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let lum = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return (lum < 0.35 ? NSColor.white : NSColor.black).cgColor
    }
    var shadowOpacity: Float {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let lum = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return lum < 0.35 ? 0.8 : 0.6
    }
    var shadowRadius: CGFloat { max(3, fontSize / 7) }
    var shadowOffset: CGSize { CGSize(width: 0, height: -max(1, fontSize / 28)) }
    /// Room around the text for the shadow and for lines animating in and out.
    var padding: CGFloat { max(20, 2 * shadowRadius + abs(shadowOffset.height) + 2, ceil(fontSize * 0.7)) }

    func applyShadow(to layer: CALayer) {
        layer.shadowColor = shadowColor
        layer.shadowOpacity = shadowOpacity
        layer.shadowRadius = shadowRadius
        layer.shadowOffset = shadowOffset
    }

    static func displayText(_ s: String?) -> String {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "♪" : t
    }
}

/// One presentation style. Coordinates: the renderer's `layer` has its origin at the TOP-CENTRE of the
/// text block (x to the right, y up, so content lives at negative y). Its bounds are set to the content
/// size with that origin, so resizing the block never shifts what is already drawn.
@MainActor protocol StyleRenderer: AnyObject {
    var layer: CALayer { get }
    /// How long the host must keep the window at least as large as before a line change.
    var transitionDuration: TimeInterval { get }
    /// Shows `content`. `advancing` = the next line just started (animate); otherwise lay out statically.
    /// Returns the size of the text block.
    func show(_ content: StyleContent, advancing: Bool, context: RenderContext) -> CGSize
    /// Same line, new clock (pause / resume / seek within the line): re-time any time-driven animation.
    func retime(_ state: LyricsState, context: RenderContext)
    /// Colour changed: update in place, keep geometry and running animations.
    func recolor(context: RenderContext)
    /// Word rects of the line being sung, in `layer` coordinates (for easter-egg effects).
    func currentWords() -> [(text: String, rect: CGRect)]
    func teardown()
}

/// Shared machinery for renderers.
@MainActor class BaseRenderer {
    let root = QuietLayer()
    var layer: CALayer { root }
    /// Text layers with how to rebuild them in a new colour.
    private var registry: [ObjectIdentifier: (layer: TextLayer, rebuild: (RenderContext) -> TextLayout)] = [:]

    init() {
        root.anchorPoint = CGPoint(x: 0.5, y: 1)
    }

    /// Sets the block size keeping the coordinate origin at the top-centre.
    func setBlockSize(_ size: CGSize) {
        root.bounds = CGRect(x: -size.width / 2, y: -size.height, width: size.width, height: size.height)
    }

    func makeTextLayer(_ context: RenderContext, _ build: @escaping (RenderContext) -> TextLayout) -> TextLayer {
        let l = TextLayer()
        l.contentsScale = context.scale
        let layout = build(context)
        l.layout = layout
        l.bounds = CGRect(origin: .zero, size: layout.size)
        registry[ObjectIdentifier(l)] = (l, build)
        return l
    }

    /// Replaces a text layer's layout (e.g. new line text) and its rebuild recipe.
    func setText(_ l: TextLayer, _ context: RenderContext, _ build: @escaping (RenderContext) -> TextLayout) {
        let layout = build(context)
        l.contentsScale = context.scale
        l.layout = layout
        l.bounds = CGRect(origin: .zero, size: layout.size)
        registry[ObjectIdentifier(l)] = (l, build)
    }

    func forget(_ l: CALayer) {
        registry.removeValue(forKey: ObjectIdentifier(l))
        l.removeFromSuperlayer()
    }

    func recolorRegistered(_ context: RenderContext) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (_, entry) in registry {
            entry.layer.layout = entry.rebuild(context)   // same geometry, new colour
        }
        applyShadows(context)
        CATransaction.commit()
    }

    /// Override point: which layers carry the glyph shadow.
    func applyShadows(_ context: RenderContext) {}

    func teardown() {
        root.removeAllAnimations()
        root.sublayers?.forEach { $0.removeAllAnimations(); $0.removeFromSuperlayer() }
        registry.removeAll()
    }

    // MARK: Animation helpers

    static let ease = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)

    /// Places a layer (no animation) so its unscaled frame's top-centre sits at `top` (block coordinates).
    func place(_ l: CALayer, topCentre top: CGPoint, scale: CGFloat = 1, opacity: Float = 1) {
        l.anchorPoint = CGPoint(x: 0.5, y: 1)
        l.position = top
        l.transform = scale == 1 ? CATransform3DIdentity : CATransform3DMakeScale(scale, scale, 1)
        l.opacity = opacity
    }

    /// Animates position (top-centre anchor), scale and opacity together; sets the model to the end state.
    func animate(_ l: CALayer, from: (CGPoint, CGFloat, Float), to: (CGPoint, CGFloat, Float),
                 duration: TimeInterval, key: String = "styleMove", completion: (() -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        l.position = to.0
        l.transform = CATransform3DMakeScale(to.1, to.1, 1)
        l.opacity = to.2
        let p = CABasicAnimation(keyPath: "position"); p.fromValue = NSValue(point: from.0); p.toValue = NSValue(point: to.0)
        let s = CABasicAnimation(keyPath: "transform.scale"); s.fromValue = from.1; s.toValue = to.1
        let o = CABasicAnimation(keyPath: "opacity"); o.fromValue = from.2; o.toValue = to.2
        let g = CAAnimationGroup()
        g.animations = [p, s, o]
        g.duration = duration
        g.timingFunction = Self.ease
        l.add(g, forKey: key)
        CATransaction.commit()
    }

    // MARK: Fade-through transitions

    /// Position (top-centre anchor), uniform scale and opacity of a layer.
    struct Pose {
        var position: CGPoint
        var scale: CGFloat
        var opacity: Float
    }

    /// Ease-out cubic: a visible glide that settles softly (≈ 1 − (1 − t)³).
    nonisolated(unsafe) static let glide = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
    nonisolated(unsafe) static let fadeOutCurve = CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)

    /// Fraction of the duration at which `glide` has covered `progress` of the distance.
    static func glideTime(forProgress progress: CGFloat) -> Double {
        let p = Double(min(max(progress, 0), 1))
        return 1 - pow(1 - p, 1.0 / 3.0)
    }

    /// What a layer looks like on screen right now (its presentation if it is animating).
    func currentPose(of l: CALayer) -> Pose {
        let p = l.presentation() ?? l
        let scale = (p.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
        return Pose(position: p.position, scale: scale, opacity: p.opacity)
    }

    /// Moves a layer with a glide while its opacity follows its own window (`fadeDelay` … +`fadeDuration`),
    /// so an outgoing and an incoming line never cross-dissolve on top of each other. Sets the model to
    /// the end pose.
    func move(_ l: CALayer, from: Pose, to: Pose, duration: TimeInterval,
              fadeDelay: TimeInterval = 0, fadeDuration: TimeInterval? = nil,
              fadeCurve: CAMediaTimingFunction? = nil,
              key: String = "styleMove", completion: (() -> Void)? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        l.position = to.position
        l.transform = CATransform3DMakeScale(to.scale, to.scale, 1)
        l.opacity = to.opacity
        let p = CABasicAnimation(keyPath: "position")
        p.fromValue = NSValue(point: from.position); p.toValue = NSValue(point: to.position)
        let s = CABasicAnimation(keyPath: "transform.scale")
        s.fromValue = from.scale; s.toValue = to.scale
        for a in [p, s] { a.duration = duration; a.timingFunction = Self.glide }
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = from.opacity; o.toValue = to.opacity
        o.beginTime = fadeDelay
        o.duration = fadeDuration ?? max(0.01, duration - fadeDelay)
        o.timingFunction = fadeCurve ?? Self.glide
        o.fillMode = .backwards                 // hold the start opacity through the delay
        let g = CAAnimationGroup()
        g.animations = [p, s, o]
        g.duration = max(duration, fadeDelay + o.duration)
        l.add(g, forKey: key)
        CATransaction.commit()
    }

    /// Width of the widest visual line of a layout (for a window that hugs the text).
    static func inkWidth(_ t: TextLayout) -> CGFloat {
        (t.fragments.map { $0.rect.width }.max() ?? 0) + 2
    }

    func wordsOf(_ l: TextLayer) -> [(text: String, rect: CGRect)] {
        guard let layout = l.layout else { return [] }
        return layout.words.map { w in (w.text, l.convert(w.rect, to: root)) }
    }
}
