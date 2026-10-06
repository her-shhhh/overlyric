import AppKit

extension Notification.Name {
    static let overlyricSettingsDidChange = Notification.Name("OverlyricSettingsDidChange")
}

struct ColorPreset {
    let name: String
    let color: NSColor
    /// Menu order; the first entry is the default lyric colour.
    static let all: [ColorPreset] = [
        .init(name: "Yellow", color: NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1)),
        .init(name: "Lemon", color: NSColor(srgbRed: 1.00, green: 0.89, blue: 0.40, alpha: 1)),
        .init(name: "White", color: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
        .init(name: "Mint", color: NSColor(srgbRed: 0.56, green: 0.94, blue: 0.78, alpha: 1)),
        .init(name: "Sky", color: NSColor(srgbRed: 0.56, green: 0.84, blue: 1.00, alpha: 1)),
        .init(name: "Lavender", color: NSColor(srgbRed: 0.79, green: 0.72, blue: 1.00, alpha: 1)),
        .init(name: "Rose", color: NSColor(srgbRed: 1.00, green: 0.61, blue: 0.76, alpha: 1)),
        .init(name: "Coral", color: NSColor(srgbRed: 1.00, green: 0.54, blue: 0.40, alpha: 1)),
        .init(name: "Black", color: NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)),
    ]
}

/// All user preferences, persisted in UserDefaults. Every setter except `windowTop` (which the panel
/// itself writes) posts `.overlyricSettingsDidChange`.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {}

    static let minFontSize: CGFloat = 14
    static let maxFontSize: CGFloat = 160
    static let defaultFontSize: CGFloat = 36

    private enum Key {
        static let enabled = "overlyric.enabled"
        static let fontSize = "overlyric.fontSize"
        static let colorRGB = "overlyric.colorRGB"
        static let clickThrough = "overlyric.clickThrough"
        static let topX = "overlyric.topX"
        static let topY = "overlyric.topY"
        static let hasTop = "overlyric.hasTop"
        static let colorMode = "overlyric.colorMode"
        static let style = "overlyric.style"
        static let font = "overlyric.font"
        static let easterEggs = "overlyric.easterEggs"
    }

    var enabled: Bool {
        get { d.object(forKey: Key.enabled) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.enabled); notify() }
    }

    var fontSize: CGFloat {
        get {
            let v = d.double(forKey: Key.fontSize)
            return v == 0 ? Self.defaultFontSize : Self.clampFont(v)
        }
        set { d.set(Double(Self.clampFont(newValue)), forKey: Key.fontSize); notify() }
    }

    static func clampFont(_ v: CGFloat) -> CGFloat { min(max(v, minFontSize), maxFontSize) }

    var color: NSColor {
        get {
            // Tolerate numbers stored as strings (e.g. `defaults write … -array 1 0.89 0.4`).
            let raw = d.array(forKey: Key.colorRGB) ?? []
            let c = raw.compactMap { v -> Double? in
                if let n = v as? NSNumber { return n.doubleValue }
                if let s = v as? String { return Double(s) }
                return nil
            }
            guard c.count == 3 else { return ColorPreset.all[0].color }
            return NSColor(srgbRed: min(1, max(0, c[0])), green: min(1, max(0, c[1])), blue: min(1, max(0, c[2])), alpha: 1)
        }
        set {
            guard let c = newValue.usingColorSpace(.sRGB) else { return }
            d.set([Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)], forKey: Key.colorRGB)
            notify()
        }
    }

    enum ColorMode: String { case manual, autoContrast, artwork }

    /// Where the lyric colour comes from: a chosen colour, the screen behind the overlay, or the cover art.
    var colorMode: ColorMode {
        get { ColorMode(rawValue: d.string(forKey: Key.colorMode) ?? "") ?? .manual }
        set { d.set(newValue.rawValue, forKey: Key.colorMode); notify() }
    }

    /// How the lyrics are presented.
    var style: LyricsStyle {
        get { LyricsStyle(rawValue: d.string(forKey: Key.style) ?? "") ?? .defaultStyle }
        set { d.set(newValue.rawValue, forKey: Key.style); notify() }
    }

    /// The typeface of the lyrics.
    var font: LyricsFont {
        get { LyricsFont(rawValue: d.string(forKey: Key.font) ?? "") ?? .defaultFont }
        set { d.set(newValue.rawValue, forKey: Key.font); notify() }
    }

    /// Small hidden delights (sparkle words, shake, on-repeat, encore). Toggle lives in the ⌥-menu.
    var easterEggs: Bool {
        get { d.object(forKey: Key.easterEggs) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.easterEggs); notify() }
    }

    var clickThrough: Bool {
        get { d.bool(forKey: Key.clickThrough) }
        set { d.set(newValue, forKey: Key.clickThrough); notify() }
    }

    /// Top-centre of the overlay window in screen coordinates (the anchor that stays put as lines wrap).
    var windowTop: NSPoint? {
        get {
            guard d.bool(forKey: Key.hasTop) else { return nil }
            return NSPoint(x: d.double(forKey: Key.topX), y: d.double(forKey: Key.topY))
        }
        set {
            if let p = newValue {
                d.set(Double(p.x), forKey: Key.topX)
                d.set(Double(p.y), forKey: Key.topY)
            }
            d.set(newValue != nil, forKey: Key.hasTop)
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: .overlyricSettingsDidChange, object: self)
    }
}
