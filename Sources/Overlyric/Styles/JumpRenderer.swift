import AppKit
import QuartzCore
import OverlyricCore

// MARK: - Jump

/// Instagram's "Dynamic Lyrics: Jump": the whole line is laid out up front (wrapped, centred), and each
/// word jumps up into its place from just below, with a little spring-like overshoot, as it is sung.
/// The outgoing line fades up and away. Everything moves on the compositor; nothing runs per frame.
@MainActor final class JumpRenderer: BaseRenderer, StyleRenderer {
    /// One jumping piece of the line (a word, or the part of a wrapped word on one visual line), the
    /// playback time its jump starts (-∞ = always shown, never jumps) and, while a jump is scheduled or
    /// running, its host start time.
    private struct Unit {
        let layer: TextLayer
        let at: TimeInterval
        var jumpStart: CFTimeInterval? = nil
    }

    /// A line on its way out, with its text layers (still registered, so a recolour reaches them).
    private struct Ghost {
        let block: QuietLayer
        let layers: [TextLayer]
    }

    /// Where a piece of a word sits in the full line layout (layout coordinates). `trailing` = pinned by
    /// its right edge (a piece that ends its visual line), otherwise by its left edge.
    private struct Slot {
        let text: String
        let rect: CGRect
        let trailing: Bool
    }

    private var block: QuietLayer?
    private var units: [Unit] = []
    private var ghosts: [Ghost] = []
    private var lineWords: [(text: String, rect: CGRect)] = []
    private var lineID: String?
    private var lineIndex: Int?
    private var rise: CGFloat = 0              // how far below its slot a word starts its jump
    let transitionDuration: TimeInterval = 0.3

    private static let jumpKey = "jump"
    private static let jumpDuration: CFTimeInterval = 0.28

    func show(_ content: StyleContent, advancing: Bool, context ctx: RenderContext) -> CGSize {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A line change while playing lets earlier ghosts finish their fade; anything else starts clean.
        if !advancing { clearGhosts() }
        var leaving: QuietLayer?
        if let old = block {
            if advancing {
                leaving = retire(old)
            } else {
                for u in units { forget(u.layer) }
                old.removeFromSuperlayer()
            }
        }
        block = nil
        units.removeAll()
        lineWords.removeAll()
        lineID = nil
        lineIndex = nil

        let b = QuietLayer()
        b.anchorPoint = CGPoint(x: 0.5, y: 1)
        b.position = .zero
        ctx.applyShadow(to: b)
        root.addSublayer(b)
        block = b

        let size: CGSize
        if case .lyrics(let st) = content, let i = st.index {
            // A gap shows ♪, which jumps in like a word.
            let raw = st.text(i)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            lineID = st.id
            lineIndex = i
            rise = ctx.fontSize * 0.5
            size = layoutWords(raw.isEmpty ? "♪" : raw, st: st, line: i, in: b, ctx: ctx)
            applyTiming(st)
        } else {
            // Before the first line, loading or a note: one static layer.
            let text: String
            let isNote: Bool
            if case .note(let s) = content { text = s; isNote = true } else { text = "♪"; isNote = false }
            let l = makeTextLayer(ctx) { isNote ? $0.noteLayout(text) : $0.layout(text) }
            l.anchorPoint = CGPoint(x: 0.5, y: 1)
            l.position = .zero
            b.addSublayer(l)
            units = [Unit(layer: l, at: -.infinity)]
            size = CGSize(width: max(Self.inkWidth(l.layout!), 24), height: l.bounds.height)
        }
        setBlockSize(size)
        CATransaction.commit()

        if let leaving {
            let s = leaving.position
            animate(leaving, from: (s, 1, 1), to: (CGPoint(x: s.x, y: s.y + ctx.fontSize * 0.4), 1, 0),
                    duration: transitionDuration) { [weak self, weak leaving] in
                guard let self, let leaving else { return }
                self.dropGhost(leaving)
            }
        }
        return size
    }

    /// Turns the current block into a ghost as it looks right now: a word still waiting for its moment
    /// stays hidden (it must not pop up on the way out), a word mid-jump finishes its jump as it fades.
    private func retire(_ old: QuietLayer) -> QuietLayer {
        let now = CACurrentMediaTime()
        for u in units {
            guard let start = u.jumpStart, now < start + 0.01 else { continue }
            u.layer.removeAnimation(forKey: Self.jumpKey)
            u.layer.opacity = 0
        }
        ghosts.append(Ghost(block: old, layers: units.map(\.layer)))
        return old
    }

    private func dropGhost(_ block: QuietLayer) {
        guard let k = ghosts.firstIndex(where: { $0.block === block }) else { return }
        let g = ghosts.remove(at: k)
        for l in g.layers { forget(l) }
        g.block.removeAllAnimations()
        g.block.removeFromSuperlayer()
    }

    private func clearGhosts() {
        let all = ghosts
        ghosts.removeAll()
        for g in all {
            for l in g.layers { forget(l) }
            g.block.removeAllAnimations()
            g.block.removeFromSuperlayer()
        }
    }

    /// Lays the whole line out once and gives every word its own layer exactly where the line puts it.
    private func layoutWords(_ text: String, st: LyricsState, line i: Int, in b: CALayer, ctx: RenderContext) -> CGSize {
        let full = ctx.layout(text)
        let W = full.width, H = full.size.height
        let pad = ceil(ctx.fontSize * 0.25)
        // Whole device pixels, so a word at rest is as crisp as the plain line (the block origin is).
        let px = 1 / max(1, ctx.scale)
        func snap(_ v: CGFloat) -> CGFloat { (v / px).rounded() * px }
        let words = full.words
        let onsets = Self.onsets(of: words.map(\.text), characters: text.count, start: st.start(i), end: st.end(i))
        for (w, at) in zip(words, onsets) {
            for slot in Self.slots(of: w, in: full) {
                let piece = slot.text
                // Wide enough never to wrap (the slot is at least as wide as the piece), room for overhangs.
                let width = ceil(slot.rect.width) + 2 * pad
                let l = makeTextLayer(ctx) { TextLayout($0.attributed(piece), width: width) }
                let own = l.layout?.fragments.first?.rect ?? .zero
                let x = slot.trailing ? slot.rect.maxX - own.maxX : slot.rect.minX - own.minX
                l.anchorPoint = .zero
                l.position = CGPoint(x: snap(x - W / 2), y: snap(slot.rect.minY - own.minY - H))
                b.addSublayer(l)
                units.append(Unit(layer: l, at: at))
            }
            lineWords.append((w.text, w.rect.offsetBy(dx: -W / 2, dy: -H)))
        }
        return CGSize(width: max(Self.inkWidth(full), 24), height: H)
    }

    /// Normally the word itself. A token the layout wrapped mid-way (a long "ooh-ooh-ooh-…" run) is split
    /// per visual line; each piece then starts its line or ends it, and is pinned to that edge.
    private static func slots(of w: TextLayout.Word, in full: TextLayout) -> [Slot] {
        let frags = full.fragments.filter { NSIntersectionRange($0.characterRange, w.characterRange).length > 0 }
        guard frags.count > 1 else { return [Slot(text: w.text, rect: w.rect, trailing: false)] }
        let ns = full.string.string as NSString
        return frags.compactMap { f in
            let part = NSIntersectionRange(f.characterRange, w.characterRange)
            let text = ns.substring(with: part)
            guard !text.isEmpty else { return nil }
            return Slot(text: text, rect: f.rect, trailing: part.location > f.characterRange.location)
        }
    }

    /// When each word is sung, interpolated across the line (the same weighting as Pop): weight = letters
    /// (+1.5 after clause punctuation), spread over 85% of min(line duration, 0.35 s + 75 ms per character).
    private static func onsets(of words: [String], characters: Int, start: TimeInterval, end: TimeInterval) -> [TimeInterval] {
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

    private static func letters(in word: String) -> Int {
        word.reduce(0) { $0 + ($1.isLetter || $1.isNumber ? 1 : 0) }
    }

    private static let clauseMarks: Set<Character> = [",", ".", "!", "?", ";", ":", "…", "—", "–"]

    /// The word ends with punctuation that makes the singer breathe ("love," "go!" "(yeah)").
    private static func endsClause(_ word: String) -> Bool {
        var w = Substring(word)
        while let c = w.last, "\"'”’)]".contains(c) {
            if c == ")" || c == "]" { return true }
            w = w.dropLast()
        }
        return w.last.map { clauseMarks.contains($0) } ?? false
    }

    /// Re-times every jump for `st.clock`: sung words in place, the rest jumping at their moment.
    private func applyTiming(_ st: LyricsState) {
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for k in units.indices {
            let u = units[k]
            units[k].jumpStart = nil
            u.layer.removeAnimation(forKey: Self.jumpKey)
            u.layer.opacity = 1
            guard u.at.isFinite else { continue }
            guard st.clock.playing else {
                u.layer.opacity = st.clock.position >= u.at ? 1 : 0
                continue
            }
            let start = st.clock.hostTime(of: u.at)
            guard start + Self.jumpDuration > now else { continue }   // already in place
            addJump(to: u.layer, at: start, rise: rise)
            units[k].jumpStart = start
        }
        CATransaction.commit()
    }

    /// Up from half a font size below with a small overshoot and settle; invisible until it starts.
    private func addJump(to l: CALayer, at start: CFTimeInterval, rise: CGFloat) {
        let y = CAKeyframeAnimation(keyPath: "transform.translation.y")
        y.values = [-rise, rise * 0.22, -rise * 0.06, 0]
        y.keyTimes = [0, 0.55, 0.8, 1]
        y.timingFunctions = [CAMediaTimingFunction(name: .easeOut),
                             CAMediaTimingFunction(name: .easeInEaseOut),
                             CAMediaTimingFunction(name: .easeInEaseOut)]
        let o = CAKeyframeAnimation(keyPath: "opacity")
        o.values = [0, 1, 1]
        o.keyTimes = [0, 0.35, 1]
        let g = CAAnimationGroup()
        g.animations = [y, o]
        g.duration = Self.jumpDuration
        g.beginTime = l.convertTime(start, from: nil)
        g.fillMode = .backwards                                       // hidden below until its moment
        l.add(g, forKey: Self.jumpKey)
    }

    func retime(_ state: LyricsState, context: RenderContext) {
        guard lineIndex != nil, state.id == lineID, state.index == lineIndex else { return }
        applyTiming(state)
    }

    func recolor(context: RenderContext) { recolorRegistered(context) }

    override func applyShadows(_ context: RenderContext) {
        if let block { context.applyShadow(to: block) }
        for g in ghosts { context.applyShadow(to: g.block) }
    }

    func currentWords() -> [(text: String, rect: CGRect)] {
        if lineIndex != nil { return lineWords }
        return units.first.map { wordsOf($0.layer) } ?? []
    }

    override func teardown() {
        super.teardown()
        block = nil; units.removeAll(); ghosts.removeAll(); lineWords.removeAll()
        lineID = nil; lineIndex = nil
    }
}
