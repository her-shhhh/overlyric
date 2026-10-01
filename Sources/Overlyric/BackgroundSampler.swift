import AppKit
import CoreGraphics
import ScreenCaptureKit
import OverlyricCore

/// Samples the screen behind the overlay window (excluding the overlay itself) with one-shot
/// ScreenCaptureKit captures and derives a readable lyric colour from it. Needs the Screen Recording
/// permission; reports clearly when it doesn't have it.
@MainActor
final class BackgroundSampler {
    enum Status: Equatable {
        case off
        case sampling
        case needsPermission      // not granted yet
        case needsRelaunch        // granted, but this process started before the grant
        case failed(String)
    }

    private(set) var status: Status = .off
    private(set) var choice: ContrastChooser.Choice?
    /// Called on the main thread whenever the chosen colour changes meaningfully.
    var onChoice: ((ContrastChooser.Choice) -> Void)?
    var onStatusChange: (() -> Void)?

    private weak var window: NSWindow?
    private var timer: Timer?
    private var inFlight = false
    private var pendingKick: DispatchWorkItem?
    private var content: SCShareableContent?
    private var contentFetchedAt = Date.distantPast
    private var consecutiveFailures = 0
    private var observers: [NSObjectProtocol] = []
    private var requestedAccessOnce = false

    private static let interval: TimeInterval = 1.5
    nonisolated private static let sampleWidth = 48
    nonisolated private static let sampleHeight = 24

    init(window: NSWindow) {
        self.window = window
    }

    var isEnabled: Bool { timer != nil }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        if on { start() } else { stop() }
    }

    // MARK: Lifecycle

    private func start() {
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let wc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.kick(after: 0.25) }
            })
        }
        if let window {
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.kick(after: 0.3) }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.kick(after: 0.3) }
            })
        }
        setStatus(.sampling)
        sample()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        pendingKick?.cancel()
        for o in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            NotificationCenter.default.removeObserver(o)
        }
        observers.removeAll()
        choice = nil
        setStatus(.off)
    }

    /// Re-samples soon (debounced) after something behind us probably changed.
    func kick(after delay: TimeInterval) {
        guard isEnabled else { return }
        pendingKick?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.sample() } }
        pendingKick = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: Permission

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt once per process; afterwards the user has to use System Settings.
    func requestPermission() {
        guard !Self.hasPermission, !requestedAccessOnce else { return }
        requestedAccessOnce = true
        _ = CGRequestScreenCaptureAccess()
        kick(after: 1)
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Sampling

    private func sample() {
        guard isEnabled, !inFlight, let window, window.isVisible else { return }
        guard Self.hasPermission else {
            setStatus(.needsPermission)
            return
        }
        inFlight = true
        let frame = window.frame
        let windowNumber = CGWindowID(window.windowNumber)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.inFlight = false }
            do {
                let (rect, display) = try self.displayRect(for: frame)
                let content = try await self.shareableContent()
                guard let scDisplay = content.displays.first(where: { $0.displayID == display }) else {
                    throw SamplerError.noDisplay
                }
                let me = content.windows.filter { $0.windowID == windowNumber }
                let filter = SCContentFilter(display: scDisplay, excludingWindows: me)
                let config = SCStreamConfiguration()
                config.width = Self.sampleWidth
                config.height = Self.sampleHeight
                config.sourceRect = rect
                config.showsCursor = false
                config.scalesToFit = true
                config.captureResolution = .nominal
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard let stats = Self.average(image) else { throw SamplerError.noPixels }
                self.consecutiveFailures = 0
                self.setStatus(.sampling)
                self.apply(stats)
            } catch {
                self.consecutiveFailures += 1
                self.content = nil
                let ns = error as NSError
                Log.ui.error("background sample failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(ns.localizedDescription, privacy: .public)")
                if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.userDeclined.rawValue {
                    self.setStatus(Self.hasPermission ? .needsRelaunch : .needsPermission)
                } else if self.consecutiveFailures >= 3 {
                    self.setStatus(.failed(ns.localizedDescription))
                }
            }
        }
    }

    private enum SamplerError: Error { case noScreen, noDisplay, noPixels }

    /// The window's frame converted to ScreenCaptureKit's display space (points, origin top-left of
    /// the display that contains the window's centre).
    private func displayRect(for frame: NSRect) throws -> (CGRect, CGDirectDisplayID) {
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(centre) } ?? window?.screen ?? NSScreen.main
        guard let screen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw SamplerError.noScreen
        }
        let clipped = frame.intersection(screen.frame)
        guard !clipped.isEmpty else { throw SamplerError.noScreen }
        let rect = CGRect(x: clipped.minX - screen.frame.minX,
                          y: screen.frame.maxY - clipped.maxY,
                          width: clipped.width, height: clipped.height)
        return (rect, id)
    }

    private func shareableContent() async throws -> SCShareableContent {
        if let content, Date().timeIntervalSince(contentFetchedAt) < 120 { return content }
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        content = c
        contentFetchedAt = Date()
        return c
    }

    struct Stats {
        let mean: RGB
        let luminance: Double
    }

    /// Mean sRGB colour and mean per-pixel relative luminance of a small image.
    nonisolated static func average(_ image: CGImage) -> Stats? {
        let w = sampleWidth, h = sampleHeight
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = { ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return ctx.data }() else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var r = 0.0, g = 0.0, b = 0.0, lum = 0.0
        var n = 0
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let a = Double(p[i + 3]) / 255
            guard a > 0.05 else { continue }      // transparent (nothing there, e.g. off-display) → skip
            let pr = Double(p[i]) / 255 / a, pg = Double(p[i + 1]) / 255 / a, pb = Double(p[i + 2]) / 255 / a
            r += pr; g += pg; b += pb
            lum += ContrastChooser.luminance(RGB(r: min(1, pr), g: min(1, pg), b: min(1, pb)))
            n += 1
        }
        guard n > 0 else { return nil }
        let d = Double(n)
        return Stats(mean: RGB(r: min(1, r / d), g: min(1, g / d), b: min(1, b / d)), luminance: lum / d)
    }

    private func apply(_ stats: Stats) {
        let new = ContrastChooser.choose(background: stats.mean, luminance: stats.luminance, previousLightText: choice?.lightText)
        if let old = choice, old.lightText == new.lightText, old.color.distance(to: new.color) < 0.06 { return }
        choice = new
        Log.ui.notice("auto colour: bg=(\(String(format: "%.2f %.2f %.2f", stats.mean.r, stats.mean.g, stats.mean.b), privacy: .public)) L=\(String(format: "%.3f", stats.luminance), privacy: .public) → \(new.lightText ? "light" : "dark", privacy: .public) (\(String(format: "%.2f %.2f %.2f", new.color.r, new.color.g, new.color.b), privacy: .public))")
        onChoice?(new)
    }

    private func setStatus(_ s: Status) {
        guard s != status else { return }
        status = s
        onStatusChange?()
    }
}
