import AppKit

extension Notification.Name {
    static let overlyricSettingsDidChange = Notification.Name("OverlyricSettingsDidChange")
}

struct ColorPreset {
    let name: String
    let color: NSColor
    static let all: [ColorPreset] = [
        .init(name: "White", color: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
        .init(name: "Lemon", color: NSColor(srgbRed: 1.00, green: 0.89, blue: 0.40, alpha: 1)),
        .init(name: "Mint", color: NSColor(srgbRed: 0.56, green: 0.94, blue: 0.78, alpha: 1)),
        .init(name: "Sky", color: NSColor(srgbRed: 0.56, green: 0.84, blue: 1.00, alpha: 1)),
        .init(name: "Lavender", color: NSColor(srgbRed: 0.79, green: 0.72, blue: 1.00, alpha: 1)),
        .init(name: "Rose", color: NSColor(srgbRed: 1.00, green: 0.61, blue: 0.76, alpha: 1)),
        .init(name: "Coral", color: NSColor(srgbRed: 1.00, green: 0.54, blue: 0.40, alpha: 1)),
        .init(name: "Black", color: NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)),
    ]
}

/// All user preferences, persisted in UserDefaults. Every setter posts `.overlyricSettingsDidChange`.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        // One-time migration from the unprefixed keys used by the first builds.
        for (old, new) in [("enabled", Key.enabled), ("fontSize", Key.fontSize), ("colorRGB", Key.colorRGB),
                           ("clickThrough", Key.clickThrough), ("centerX", Key.centerX), ("centerY", Key.centerY),
                           ("hasCenter", Key.hasCenter)] {
            if d.object(forKey: new) == nil, let v = d.object(forKey: old) {
                d.set(v, forKey: new)
                d.removeObject(forKey: old)
            }
        }
    }

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
        // Pre-top-anchor builds stored the window centre.
        static let centerX = "overlyric.centerX"
        static let centerY = "overlyric.centerY"
        static let hasCenter = "overlyric.hasCenter"
        static let autoContrast = "overlyric.autoContrast"
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

    /// Pick the lyric colour automatically from what is behind the overlay (needs Screen Recording).
    var autoContrast: Bool {
        get { d.bool(forKey: Key.autoContrast) }
        set { d.set(newValue, forKey: Key.autoContrast); notify() }
    }

    var clickThrough: Bool {
        get { d.bool(forKey: Key.clickThrough) }
        set { d.set(newValue, forKey: Key.clickThrough); notify() }
    }

    /// Top-centre of the overlay window in screen coordinates (the anchor that stays put as lines wrap).
    var windowTop: NSPoint? {
        get {
            if d.bool(forKey: Key.hasTop) {
                return NSPoint(x: d.double(forKey: Key.topX), y: d.double(forKey: Key.topY))
            }
            if d.bool(forKey: Key.hasCenter) {   // migrate an old centre: assume a two-line block
                return NSPoint(x: d.double(forKey: Key.centerX), y: d.double(forKey: Key.centerY) + 60)
            }
            return nil
        }
        set {
            if let p = newValue {
                d.set(Double(p.x), forKey: Key.topX)
                d.set(Double(p.y), forKey: Key.topY)
                d.set(true, forKey: Key.hasTop)
            } else {
                d.set(false, forKey: Key.hasTop)
                d.set(false, forKey: Key.hasCenter)
            }
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: .overlyricSettingsDidChange, object: self)
    }
}
