import AppKit
import QuartzCore
import OverlyricCore

// MARK: - Pop

/// Instagram's "Dynamic Lyrics: Pop": the line flashes on screen one word at a time as it is sung — big,
/// centred, each word popping in (a quick shrink + fade in) in the very frame the previous one cuts out.
/// A word of three letters or fewer shares its flash with the word after it ("in the", "I'm gonna").
///
/// Every flash of the line is laid out up front and its visibility is driven purely by Core Animation
/// keyframes timed from the playback clock, so nothing runs per frame. The block is sized to the widest
/// flash of the line (plus the pop's overshoot), so the window never resizes while the words flash.
@MainActor final class PopRenderer: BaseRenderer, StyleRenderer {
    /// One flash: a word (or a short word with the one after it) and when it is sung (playback time).
    private struct Flash {
        let layer: TextLayer
        let onset: TimeInterval
    }

    /// How the flashes were last timed: the flash current then, the playback time its pop started (nil =
    /// shown as is) and the clock both are measured on. Later flashes pop in at their onsets on that clock.
    private struct Shown {
        let index: Int
        let popStart: TimeInterval?
        let clock: PlaybackClock
    }

    private var flashes: [Flash] = []
    /// ♪ (before the first line / gaps) or a status note.
    private var still: TextLayer?
    /// The sung line on screen (track id, line index); nil while showing ♪ or a note.
    private var line: (id: String, index: Int)?
    private var shown: Shown?
    let transitionDuration: TimeInterval = 0.16

    private static let sizeFactor: CGFloat = 1.6
    private static let popScale: CGFloat = 1.25
    private static let popDuration: TimeInterval = 0.16

    func show(_ content: StyleContent, advancing: Bool, context ctx: RenderContext) -> CGSize {
        let previousLine = line, previous = shown
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        clear()

        var sung: (state: LyricsState, index: Int, text: String)?
        if case .lyrics(let st) = content, let i = st.index {
            let text = (st.text(i) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { sung = (st, i, text) }
        }
        let size: CGSize
        if let sung {
            line = (sung.state.id, sung.index)
            size = layoutFlashes(sung.text, state: sung.state, line: sung.index, context: ctx)
            // A line change pops its first word. A relayout of the same line (resize) carries on exactly
            // where it was; anything else (seek to another line, first show) shows the current word as is.
            let relayout = !advancing && previousLine?.id == sung.state.id && previousLine?.index == sung.index
            applyTiming(sung.state.clock, popCurrent: advancing, carry: relayout ? previous : nil)
        } else {
            var note: String?
            if case .note(let s) = content { note = s }
            size = showStill(note, popping: advancing && note == nil, context: ctx)
        }
        setBlockSize(size)
        return size
    }

    // MARK: Layout

    /// ♪ or a note, centred and static (♪ pops in when a gap starts while playing).
    private func showStill(_ note: String?, popping: Bool, context ctx: RenderContext) -> CGSize {
        let l: TextLayer
        if let note {
            l = makeTextLayer(ctx) { $0.noteLayout(note) }
            mount(l, context: ctx)
        } else {
            l = makeFlashLayer("♪", context: ctx)
        }
        l.opacity = 1
        still = l
        if popping {
            let now = l.convertTime(CACurrentMediaTime(), from: nil)
            l.add(keyframes("opacity", [0, 1], at: [0, 1], begin: now, duration: Self.popDuration, fill: .backwards), forKey: "popOpacity")
            l.add(keyframes("transform.scale", [Self.popScale, 1], at: [0, 1], begin: now, duration: Self.popDuration, fill: .backwards), forKey: "popScale")
        }
        return CGSize(width: blockWidth(ink: Self.ink(l), context: ctx), height: l.bounds.height)
    }

    /// Lays out every flash of the line (hidden), top-aligned and centred; returns the block size.
    private func layoutFlashes(_ text: String, state st: LyricsState, line i: Int, context ctx: RenderContext) -> CGSize {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let onsets = WordTiming.onsets(of: words, characters: text.count, start: st.start(i), end: st.end(i))
        var maxInk: CGFloat = 0
        var height: CGFloat = 0
        for phrase in Self.phrases(words) {
            let l = makeFlashLayer(phrase.text, context: ctx)
            l.opacity = 0
            flashes.append(Flash(layer: l, onset: onsets[phrase.firstWord]))
            maxInk = max(maxInk, Self.ink(l))
            height = max(height, l.bounds.height)
        }
        return CGSize(width: blockWidth(ink: maxInk, context: ctx), height: max(height, ctx.fontSize))
    }

    /// A big flash of text, laid out just wider than its natural width (it wraps only past the wrap
    /// width), so its bitmap hugs the text and its centre is the text's centre.
    private func makeFlashLayer(_ text: String, context ctx: RenderContext) -> TextLayer {
        let size = ctx.fontSize * Self.sizeFactor
        let natural = ceil(ctx.attributed(text, size: size).size().width)
        let width = min(ctx.wrapWidth, natural + ceil(size * 0.25))
        let l = makeTextLayer(ctx) { $0.layout(text, size: size, width: width) }
        mount(l, context: ctx)
        return l
    }

    /// Centred, top at the block's top-centre, anchored at its middle so the pop scales about it.
    private func mount(_ l: TextLayer, context ctx: RenderContext) {
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        l.position = CGPoint(x: 0, y: -l.bounds.height / 2)
        l.transform = CATransform3DIdentity
        ctx.applyShadow(to: l)
        root.addSublayer(l)
    }

    /// Ink width of a text layer: its typeset extent, never more than its bitmap (which clips anyway).
    private static func ink(_ l: TextLayer) -> CGFloat {
        min(inkWidth(l.layout!), l.bounds.width)
    }

    /// Wide enough for the widest flash and, up to the wrap width, for it at the start of its pop
    /// (scaled up) to stay inside the window's padding.
    private func blockWidth(ink: CGFloat, context ctx: RenderContext) -> CGFloat {
        max(24, ink, min(ceil(Self.popScale * ink - 2 * ctx.padding), ctx.wrapWidth))
    }

    /// Groups the words into flashes: a word of ≤ 3 letters goes with the word after it (unless it ends
    /// a clause — "oh," stays on its own). At most two words per flash.
    private static func phrases(_ words: [String]) -> [(text: String, firstWord: Int)] {
        var out: [(text: String, firstWord: Int)] = []
        var j = 0
        while j < words.count {
            if j + 1 < words.count, WordTiming.letters(in: words[j]) <= 3, !WordTiming.endsClause(words[j]) {
                out.append((words[j] + " " + words[j + 1], j))
                j += 2
            } else {
                out.append((words[j], j))
                j += 1
            }
        }
        return out
    }

    // MARK: Timing

    /// (Re)builds every flash's visibility from `clock`. Playing: each flash is shown exactly from its
    /// onset to the next flash's onset (the last one stays), popping in; all on the compositor. Paused: the
    /// flash current at `clock.position` is shown still (held mid-pop if it was popping).
    /// `carry` = what was on screen before: while the same flash is current it carries on as it was (its
    /// pop neither restarts nor snaps), and if playback moved to another word, that word pops in now.
    /// Without it, the current flash pops in only when `popCurrent`.
    private func applyTiming(_ clock: PlaybackClock, popCurrent: Bool, carry: Shown?) {
        guard !flashes.isEmpty else { return }
        let now = CACurrentMediaTime()
        let t = clock.playbackTime(at: now)
        let current = flashIndex(at: t)
        var popStart = popCurrent ? min(flashes[current].onset, t) : nil
        if let carry {
            // The flash on screen right now under the old clock, and when its pop started.
            let before = carry.clock.playbackTime(at: now)
            let onScreen = flashIndex(at: before)
            if onScreen == current {
                let started = onScreen == carry.index ? carry.popStart : flashes[onScreen].onset
                popStart = started.map { t - (before - $0) }
            } else if clock.playing {
                popStart = t
            }
        }
        shown = Shown(index: current, popStart: popStart, clock: clock)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (k, f) in flashes.enumerated() {
            let l = f.layer
            l.removeAllAnimations()
            l.transform = CATransform3DIdentity
            guard clock.playing else {
                l.opacity = k == current ? 1 : 0
                if k == current, let popStart, (0..<Self.popDuration).contains(t - popStart) { holdPop(l, at: t - popStart) }
                continue
            }
            guard k >= current else {
                l.opacity = 0                                     // already sung
                continue
            }
            let until = k + 1 < flashes.count ? clock.hostTime(of: flashes[k + 1].onset) : nil
            if k > current {
                flash(l, from: clock.hostTime(of: f.onset), until: until, pop: Self.popDuration)
            } else if let popStart {
                flash(l, from: clock.hostTime(of: popStart), until: until, pop: Self.popDuration)
            } else {
                flash(l, from: min(clock.hostTime(of: f.onset), now), until: until, pop: 0)
            }
        }
        CATransaction.commit()
    }

    /// The flash being sung at playback time `t` (the first one before the line's first onset).
    private func flashIndex(at t: TimeInterval) -> Int {
        flashes.lastIndex { $0.onset <= t } ?? 0
    }

    /// Shows `l` from host time `from` until host time `until` (nil = for the rest of the line), popping
    /// in over `pop` seconds (0 = shown as is). Outside that window the model keeps it hidden, so the
    /// previous flash cuts out in the same frame the next one starts.
    private func flash(_ l: CALayer, from: CFTimeInterval, until: CFTimeInterval?, pop: TimeInterval) {
        let begin = l.convertTime(from, from: nil)
        guard let until else {
            l.opacity = 1                                         // the last flash stays once shown
            guard pop > 0 else { return }
            l.add(keyframes("opacity", [0, 1], at: [0, 1], begin: begin, duration: pop, fill: .backwards), forKey: "popOpacity")
            l.add(keyframes("transform.scale", [Self.popScale, 1], at: [0, 1], begin: begin, duration: pop, fill: .backwards), forKey: "popScale")
            return
        }
        l.opacity = 0
        let window = until - from
        guard window > 0.001 else { return }                      // sung together with the next flash
        guard pop > 0 else {
            l.add(keyframes("opacity", [1, 1], at: [0, 1], begin: begin, duration: window, fill: .removed), forKey: "popOpacity")
            return
        }
        // A word shorter than the pop still reaches full size before it is replaced.
        let t = min(pop, window * 0.6) / window
        l.add(keyframes("opacity", [0, 1, 1], at: [0, t, 1], begin: begin, duration: window, fill: .removed), forKey: "popOpacity")
        l.add(keyframes("transform.scale", [Self.popScale, 1, 1], at: [0, t, 1], begin: begin, duration: window, fill: .removed), forKey: "popScale")
    }

    /// Holds a pop still, `elapsed` seconds in (paused mid-pop); resuming re-times it from there.
    private func holdPop(_ l: CALayer, at elapsed: TimeInterval) {
        for (key, path, values) in [("popOpacity", "opacity", [0, 1]), ("popScale", "transform.scale", [Self.popScale, 1])] {
            let a = keyframes(path, values, at: [0, 1], begin: 0, duration: Self.popDuration, fill: .both)
            a.speed = 0
            a.timeOffset = elapsed
            l.add(a, forKey: key)
        }
    }

    /// A keyframe animation whose first segment eases out (the pop) and whose rest holds linearly.
    private func keyframes(_ keyPath: String, _ values: [CGFloat], at times: [Double], begin: CFTimeInterval,
                           duration: TimeInterval, fill: CAMediaTimingFillMode) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.keyTimes = times.map { NSNumber(value: $0) }
        a.timingFunctions = (0..<max(1, values.count - 1)).map { $0 == 0 ? Self.ease : CAMediaTimingFunction(name: .linear) }
        a.calculationMode = .linear
        a.beginTime = begin
        a.duration = duration
        a.fillMode = fill
        a.isRemovedOnCompletion = false
        return a
    }

    func retime(_ state: LyricsState, context: RenderContext) {
        guard let line, line.id == state.id, line.index == state.index, let shown else { return }
        applyTiming(state.clock, popCurrent: false, carry: shown)
    }

    // MARK: Colour, words, teardown

    func recolor(context: RenderContext) { recolorRegistered(context) }

    override func applyShadows(_ context: RenderContext) {
        for f in flashes { context.applyShadow(to: f.layer) }
        if let still { context.applyShadow(to: still) }
    }

    func currentWords() -> [(text: String, rect: CGRect)] { flashes.flatMap { wordsOf($0.layer) } }

    private func clear() {
        for f in flashes { f.layer.removeAllAnimations(); forget(f.layer) }
        flashes.removeAll()
        if let still { still.removeAllAnimations(); forget(still) }
        still = nil
        line = nil
        shown = nil
    }

    override func teardown() {
        super.teardown()
        flashes.removeAll(); still = nil; line = nil; shown = nil
    }
}

// MARK: - Word timing

/// When each word of a line is sung, interpolated across the line. Pop and Jump share it, so both styles
/// keep the same rhythm.
enum WordTiming {
    /// Weight = letters (+1.5 after clause punctuation), spread over 85% of min(line duration, 0.35 s + 75 ms
    /// per character).
    static func onsets(of words: [String], characters: Int, start: TimeInterval, end: TimeInterval) -> [TimeInterval] {
        let span = 0.85 * min(max(0, end - start), max(0.35, 0.075 * Double(characters) + 0.35))
        let weights = words.map { Double(letters(in: $0)) + (endsClause($0) ? 1.5 : 0) }
        let total = weights.reduce(0, +)
        var out: [TimeInterval] = []
        var before = 0.0
        for (k, w) in weights.enumerated() {
            let f = total > 0 ? before / total : Double(k) / Double(max(1, words.count))
            out.append(start + span * f)
            before += w
        }
        return out
    }

    static func letters(in word: String) -> Int {
        word.reduce(0) { $0 + ($1.isLetter || $1.isNumber ? 1 : 0) }
    }

    private static let clauseMarks: Set<Character> = [",", ".", "!", "?", ";", ":", "…", "—", "–"]

    /// The word ends with punctuation that makes the singer breathe ("love," "go!" "(yeah)").
    static func endsClause(_ word: String) -> Bool {
        var w = Substring(word)
        while let c = w.last, "\"'”’)]".contains(c) {
            if c == ")" || c == "]" { return true }
            w = w.dropLast()
        }
        return w.last.map { clauseMarks.contains($0) } ?? false
    }
}
