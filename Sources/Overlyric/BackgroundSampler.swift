import AppKit
import CoreGraphics
import ScreenCaptureKit
import OverlyricCore

/// Samples the screen behind the overlay window (excluding the overlay itself) with one-shot
/// ScreenCaptureKit captures and picks a colourful, readable lyric colour for it.
///
/// - Sampling is event-driven (app switch, Space change, overlay moved/resized, screen wake) plus a slow
///   periodic tick only while music is playing: macOS lights the purple screen-capture indicator for a few
///   seconds after each capture, so a fast fixed cadence would keep it on permanently.
/// - Nothing is captured while the screen is locked or asleep, or while the overlay is hidden.
/// - Permission is judged by the live ScreenCaptureKit result (CGPreflightScreenCaptureAccess is cached
///   for the life of the process and would never notice a grant made after launch).
@MainActor
final class BackgroundSampler {
    enum Status: Equatable {
        case off
        case sampling
        case needsPermission
        case failed(String)
    }

    private(set) var status: Status = .off
    /// The last pick. Kept across stop/start so re-showing the overlay starts from the last good colour.
    private(set) var choice: ContrastChooser.Choice?
    var onChoice: ((ContrastChooser.Choice) -> Void)?
    var onStatusChange: (() -> Void)?

    private weak var window: NSWindow?
    private var enabled = false
    private var periodic = false
    private var suspended = false        // screen locked / asleep
    private var timer: Timer?
    private var generation = 0
    private var inFlight = false
    private var pendingKick: DispatchWorkItem?
    private var content: SCShareableContent?
    private var contentFetchedAt = Date.distantPast
    private var consecutiveFailures = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var requestedAccessOnce = false
    private var lastSampleAt = Date.distantPast
    private var declinedAt: Date?
    /// Set when the user explicitly asks for the permission; only then may a capture attempt run
    /// without a known grant (that attempt is what lets a grant made after launch take effect).
    private var probeUntil = Date.distantPast
    private var forceNewOnNextSample = false
    private var lastStats: Stats?

    private static let interval: TimeInterval = 6
    private static let minGap: TimeInterval = 0.8
    private static let declinedBackoff: TimeInterval = 5
    nonisolated private static let sampleWidth = 48
    nonisolated private static let sampleHeight = 24

    init(window: NSWindow) {
        self.window = window
    }

    var isEnabled: Bool { enabled }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        if on { start() } else { stop() }
    }

    /// Periodic re-sampling only makes sense while lyrics are moving (music playing).
    func setPeriodic(_ on: Bool) {
        guard on != periodic else { return }
        periodic = on
        rescheduleTimer()
    }

    /// A new song: pick a fresh colour (still readable) on the next sample.
    func reshuffle() {
        guard enabled else { return }
        forceNewOnNextSample = true
        if let stats = lastStats, Date().timeIntervalSince(lastSampleAt) < 3 {
            apply(stats)            // background is fresh enough: recolour immediately, no capture
        } else {
            kick(after: 0.1)
        }
    }

    // MARK: Lifecycle

    private func start() {
        enabled = true
        generation += 1
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.didActivateApplicationNotification) { $0.kick(after: 0.35) }
        observe(ws, NSWorkspace.activeSpaceDidChangeNotification) { $0.kick(after: 0.35) }
        observe(ws, NSWorkspace.screensDidSleepNotification) { $0.setSuspended(true) }
        observe(ws, NSWorkspace.screensDidWakeNotification) { $0.setSuspended(false) }
        let dnc = DistributedNotificationCenter.default()
        observe(dnc, Notification.Name("com.apple.screenIsLocked")) { $0.setSuspended(true) }
        observe(dnc, Notification.Name("com.apple.screenIsUnlocked")) { $0.setSuspended(false) }
        if let window {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                let token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.kick(after: 0.4) }
                }
                observers.append((NotificationCenter.default, token))
            }
        }
        rescheduleTimer()
        setStatus(.sampling)
        sample()
    }

    private func stop() {
        enabled = false
        generation += 1          // results of any in-flight capture are dropped
        inFlight = false
        pendingKick?.cancel()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        rescheduleTimer()
        setStatus(.off)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping (BackgroundSampler) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }

    private func setSuspended(_ s: Bool) {
        suspended = s
        rescheduleTimer()
        if !s { kick(after: 0.6) }
    }

    private func rescheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard enabled, periodic, !suspended else { return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Re-samples soon (debounced) after something behind us probably changed.
    func kick(after delay: TimeInterval) {
        guard enabled else { return }
        pendingKick?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.sample() } }
        pendingKick = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: Permission

    /// Shows the system prompt once per process (only if macOS still considers the question open).
    func requestPermission() {
        declinedAt = nil
        probeUntil = Date().addingTimeInterval(300)
        if !requestedAccessOnce, !CGPreflightScreenCaptureAccess() {
            requestedAccessOnce = true
            _ = CGRequestScreenCaptureAccess()
        }
        kick(after: 1.5)
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Sampling

    private func sample() {
        guard enabled, !suspended, !inFlight, let window, window.isVisible else { return }
        let now = Date()
        if let declinedAt, now.timeIntervalSince(declinedAt) < Self.declinedBackoff { return }
        // Never let a background capture be the thing that pops a permission dialog.
        if !CGPreflightScreenCaptureAccess(), now > probeUntil {
            setStatus(.needsPermission)
            return
        }
        guard now.timeIntervalSince(lastSampleAt) >= Self.minGap else { kick(after: Self.minGap); return }
        inFlight = true
        lastSampleAt = now
        let gen = generation
        let frame = window.frame
        let windowNumber = CGWindowID(window.windowNumber)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if gen == self.generation { self.inFlight = false } }
            do {
                let (rect, displayID) = try self.displayRect(for: frame)
                var content = try await self.shareableContent()
                guard gen == self.generation else { return }
                if content.displays.isEmpty { self.content = nil; return }      // display asleep
                var me = content.windows.filter { $0.windowID == windowNumber }
                if me.isEmpty {                                                   // stale list → refetch once
                    content = try await self.shareableContent(force: true)
                    me = content.windows.filter { $0.windowID == windowNumber }
                    guard !me.isEmpty else { return }                             // never sample our own text
                }
                guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else { return }
                let filter = SCContentFilter(display: scDisplay, excludingWindows: me)
                let config = SCStreamConfiguration()
                config.width = Self.sampleWidth
                config.height = Self.sampleHeight
                config.sourceRect = rect
                config.showsCursor = false
                config.preservesAspectRatio = false
                config.captureResolution = .nominal
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.sRGB
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard gen == self.generation, self.enabled else { return }
                guard let stats = Self.statistics(image) else { return }
                self.consecutiveFailures = 0
                self.declinedAt = nil
                self.setStatus(.sampling)
                self.lastStats = stats
                self.apply(stats)
            } catch {
                guard gen == self.generation else { return }
                self.content = nil
                let ns = error as NSError
                if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.userDeclined.rawValue {
                    self.declinedAt = Date()
                    self.setStatus(.needsPermission)
                    return
                }
                if error is SamplerError { return }                               // off-screen etc.: just skip
                self.consecutiveFailures += 1
                Log.ui.error("background sample failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(ns.localizedDescription, privacy: .public)")
                if self.consecutiveFailures >= 3 { self.setStatus(.failed(ns.localizedDescription)) }
            }
        }
    }

    private enum SamplerError: LocalizedError {
        case offScreen
        var errorDescription: String? { "the lyrics are off-screen" }
    }

    /// The window's frame converted to ScreenCaptureKit's display space: points, origin at the top-left
    /// of the display that contains the window's centre (verified empirically, see docs).
    private func displayRect(for frame: NSRect) throws -> (CGRect, CGDirectDisplayID) {
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(centre) } ?? window?.screen ?? NSScreen.main
        guard let screen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw SamplerError.offScreen
        }
        let clipped = frame.intersection(screen.frame)
        guard !clipped.isEmpty, clipped.width >= 2, clipped.height >= 2 else { throw SamplerError.offScreen }
        let rect = CGRect(x: clipped.minX - screen.frame.minX,
                          y: screen.frame.maxY - clipped.maxY,
                          width: clipped.width, height: clipped.height)
        return (rect, id)
    }

    private func shareableContent(force: Bool = false) async throws -> SCShareableContent {
        if !force, let content, Date().timeIntervalSince(contentFetchedAt) < 60 { return content }
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        content = c
        contentFetchedAt = Date()
        return c
    }

    struct Stats {
        let mean: RGB
        /// Median per-pixel luminance: what the text sits on for most of its area (a bright minority
        /// such as text glyphs or a window edge cannot drag it up the way a linear mean would).
        let luminance: Double
    }

    nonisolated static func statistics(_ image: CGImage) -> Stats? {
        let w = sampleWidth, h = sampleHeight
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var r = 0.0, g = 0.0, b = 0.0
        var lums: [Double] = []
        lums.reserveCapacity(w * h)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let a = Double(p[i + 3]) / 255
            guard a > 0.05 else { continue }
            let px = RGB(r: min(1, Double(p[i]) / 255 / a), g: min(1, Double(p[i + 1]) / 255 / a), b: min(1, Double(p[i + 2]) / 255 / a))
            r += px.r; g += px.g; b += px.b
            lums.append(ContrastChooser.luminance(px))
        }
        guard !lums.isEmpty else { return nil }
        lums.sort()
        let d = Double(lums.count)
        return Stats(mean: RGB(r: r / d, g: g / d, b: b / d), luminance: lums[lums.count / 2])
    }

    private func apply(_ stats: Stats) {
        let forceNew = forceNewOnNextSample
        forceNewOnNextSample = false
        let new = ContrastChooser.choose(background: stats.mean, luminance: stats.luminance, previous: choice, forceNew: forceNew)
        guard new != choice else { return }
        choice = new
        Log.ui.notice("auto colour: bg=(\(String(format: "%.2f %.2f %.2f", stats.mean.r, stats.mean.g, stats.mean.b), privacy: .public)) medianL=\(String(format: "%.3f", stats.luminance), privacy: .public) → \(new.lightText ? "bright" : "deep", privacy: .public) (\(String(format: "%.2f %.2f %.2f", new.color.r, new.color.g, new.color.b), privacy: .public))")
        onChoice?(new)
    }

    private func setStatus(_ s: Status) {
        guard s != status else { return }
        status = s
        onStatusChange?()
    }
}
