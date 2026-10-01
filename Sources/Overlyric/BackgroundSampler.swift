import AppKit
import CoreGraphics
import ScreenCaptureKit
import OverlyricCore

/// Samples the screen behind the overlay window (excluding the overlay itself) with one-shot
/// ScreenCaptureKit captures and picks a colourful, readable lyric colour for it.
///
/// - Sampling is event-driven — app switch, Space change, light/dark appearance change, overlay moved or
///   resized, screen wake, and any change in the stack of windows behind the lyrics (checked cheaply,
///   without capturing) — plus a 4 s tick while music plays to catch content changing inside a window.
/// - Nothing is captured while the screen is locked or asleep, or while the overlay is hidden.
/// - Captures only run with a Screen Recording grant, so the sampler can never make macOS ask for
///   permission. Asking is always an explicit click (see `requestPermission` / `continuePermission`).
@MainActor
final class BackgroundSampler {
    enum Status: Equatable {
        case off
        case sampling
        case needsPermission
        case failed(String)
    }

    /// What clicking the menu's permission row does next.
    enum PermissionStep {
        /// Ask macOS (its dialog, or System Settings if it was answered before).
        case ask
        /// Asked in this run: a grant takes effect once the app is reopened.
        case reopen
        /// Reopened for the grant and still not allowed — typically a grant stored for a differently signed
        /// build, which System Settings shows ticked but macOS ignores. Reset it, then ask again.
        case reset
    }

    private(set) var status: Status = .off
    /// The last pick. Kept across stop/start so re-showing the overlay starts from the last good colour.
    private(set) var choice: ContrastChooser.Choice?
    var onChoice: ((ContrastChooser.Choice) -> Void)?

    private weak var window: NSWindow?
    private var enabled = false
    private var periodic = false
    private var screenAsleep = false
    private var screenLocked = false
    private var suspended: Bool { screenAsleep || screenLocked }
    private var timer: Timer?
    private var stackTimer: Timer?
    private var generation = 0
    private var inFlight = false
    private var sampleAgain = false      // something changed while a capture was in flight
    private var pendingKick: DispatchWorkItem?
    private var content: SCShareableContent?
    private var contentFetchedAt = Date.distantPast
    private var consecutiveFailures = 0
    private var listingRetries = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var lastSampleAt = Date.distantPast
    /// Signature of the windows behind the overlay; a change means "something new is behind the lyrics".
    private var stackSignature = ""
    private var forceNewOnNextSample = false
    private var lastStats: Stats?
    private var granted = false
    /// macOS refused a capture; nothing is retried until the user acts.
    private var declined = false
    private var askedThisRun = false

    private static let interval: TimeInterval = 4
    private static let minGap: TimeInterval = 0.8
    nonisolated private static let sampleWidth = 48
    nonisolated private static let sampleHeight = 24
    private static let reopenedForPermissionFlag = "--reopened-for-screen-recording"
    private static let reopenedForPermission = CommandLine.arguments.contains(reopenedForPermissionFlag)

    init(window: NSWindow) {
        self.window = window
        // Watched for the app's lifetime, so a lock or sleep that happens while sampling is off still counts.
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        watchScreen(ws, NSWorkspace.screensDidSleepNotification) { $0.screenAsleep = true }
        watchScreen(ws, NSWorkspace.screensDidWakeNotification) { $0.screenAsleep = false }
        watchScreen(dnc, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true }
        watchScreen(dnc, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false }
    }

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
        observe(ws, NSWorkspace.didActivateApplicationNotification, after: 0.35)
        observe(ws, NSWorkspace.activeSpaceDidChangeNotification, after: 0.35)
        // Light ↔ dark appearance: windows behind repaint without moving, so the stack watcher can't see it.
        observe(DistributedNotificationCenter.default(), Notification.Name("AppleInterfaceThemeChangedNotification"), after: 0.6)
        if let window {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                let token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.kick(after: 0.4) }
                }
                observers.append((NotificationCenter.default, token))
            }
        }
        rescheduleTimer()
        let watcher = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWindowStack() }
        }
        watcher.tolerance = 0.2
        RunLoop.main.add(watcher, forMode: .common)
        stackTimer = watcher
        listingRetries = 0
        status = hasAccess ? .sampling : .needsPermission
        sample()
    }

    private func stop() {
        enabled = false
        generation += 1          // results of any in-flight capture are dropped
        inFlight = false
        sampleAgain = false
        pendingKick?.cancel()
        stackTimer?.invalidate()
        stackTimer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        rescheduleTimer()
        status = .off
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, after delay: TimeInterval) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.kick(after: delay) }
        }
        observers.append((center, token))
    }

    /// Cheap (no capture): the on-screen windows overlapping the lyrics, front to back. When that changes
    /// — another window moved behind, a different tab/app came forward — re-sample right away.
    private func checkWindowStack() {
        guard enabled, !suspended, let window, window.isVisible else { return }
        let me = CGWindowID(window.windowNumber)
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let f = window.frame
        let cg = CGRect(x: f.minX, y: screenH - f.maxY, width: f.width, height: f.height)  // top-left origin
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenBelowWindow, .excludeDesktopElements], me) as? [[String: Any]] else { return }
        var parts: [String] = []
        for w in list {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let layer = w[kCGWindowLayer as String] as? Int, layer < 25 else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard r.intersects(cg) else { continue }
            parts.append("\(w[kCGWindowNumber as String] ?? 0):\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))")
            if r.contains(cg) { break }          // fully covered by this window: nothing deeper matters
        }
        let signature = parts.joined(separator: "|")
        if signature != stackSignature {
            stackSignature = signature
            kick(after: 0.15)
        }
    }

    private func watchScreen(_ center: NotificationCenter, _ name: Notification.Name, _ update: @escaping (BackgroundSampler) -> Void) {
        _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let was = self.suspended
                update(self)
                guard self.suspended != was else { return }
                self.rescheduleTimer()
                if !self.suspended { self.kick(after: 0.6) }
            }
        }
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
    private func kick(after delay: TimeInterval) {
        guard enabled else { return }
        pendingKick?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.sample() } }
        pendingKick = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: Permission

    /// Whether this process may capture. A grant made while the app runs may only take effect after the
    /// app is reopened (System Settings offers "Quit & Reopen"); until then this stays false.
    var hasAccess: Bool { isGranted && !declined }

    private var isGranted: Bool {
        if !granted { granted = CGPreflightScreenCaptureAccess() }
        return granted
    }

    var permissionStep: PermissionStep {
        guard !isGranted else { return .ask }          // allowed, but macOS refused a capture: try again
        if askedThisRun { return .reopen }
        return Self.reopenedForPermission ? .reset : .ask
    }

    /// Auto was just turned on: asks macOS once per run (its dialog appears only if the question was
    /// never answered), otherwise opens the Screen Recording settings.
    func requestPermission() {
        declined = false
        guard !isGranted else { kick(after: 0.1); return }
        guard !askedThisRun else { Self.openSystemSettings(); return }
        askedThisRun = true
        if Self.reopenedForPermission { Self.resetThenAsk() } else { Self.ask() }
    }

    /// The menu opened: a grant that has taken effect since the last attempt starts sampling right away.
    func refresh() {
        if status == .needsPermission, hasAccess { kick(after: 0) }
    }

    /// The menu's permission row: takes the step `permissionStep` describes.
    func continuePermission() {
        if permissionStep == .reopen {
            NSApp.relaunch(arguments: [Self.reopenedForPermissionFlag])
        } else {
            requestPermission()
        }
    }

    private static func ask() {
        if !CGRequestScreenCaptureAccess() { openSystemSettings() }
    }

    /// Removes Overlyric's own Screen Recording record, so macOS asks afresh and stores a grant that
    /// matches this build.
    private static func resetThenAsk() {
        guard let id = Bundle.main.bundleIdentifier else { ask(); return }
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "ScreenCapture", id]
        reset.terminationHandler = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { ask() } }
        }
        do {
            try reset.run()
        } catch {
            Log.ui.error("tccutil reset failed: \(error.localizedDescription, privacy: .public)")
            ask()
        }
    }

    private static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Sampling

    private func sample() {
        guard enabled, !suspended, let window, window.isVisible else { return }
        guard !inFlight else { sampleAgain = true; return }
        // Never let a capture attempt be the thing that pops a permission dialog.
        guard hasAccess else {
            status = .needsPermission
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastSampleAt) >= Self.minGap else { kick(after: Self.minGap); return }
        inFlight = true
        lastSampleAt = now
        let gen = generation
        let frame = window.frame
        let windowNumber = CGWindowID(window.windowNumber)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if gen == self.generation {
                    self.inFlight = false
                    if self.sampleAgain {
                        self.sampleAgain = false
                        self.kick(after: 0.1)
                    }
                }
            }
            do {
                let (rect, displayID) = try self.displayRect(for: frame)
                var content = try await self.shareableContent()
                guard gen == self.generation else { return }
                if content.displays.isEmpty { self.content = nil; return }      // display asleep
                var me = content.windows.filter { $0.windowID == windowNumber }
                if me.isEmpty {                                                   // stale list → refetch once
                    content = try await self.shareableContent(force: true)
                    me = content.windows.filter { $0.windowID == windowNumber }
                    guard !me.isEmpty else {                                      // never sample our own text
                        self.listingRetries += 1                                  // just shown: listed shortly
                        self.sampleAgain = self.listingRetries <= 3
                        return
                    }
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
                self.listingRetries = 0
                self.status = .sampling
                self.lastStats = stats
                self.apply(stats)
            } catch {
                guard gen == self.generation else { return }
                self.content = nil
                let ns = error as NSError
                if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.userDeclined.rawValue {
                    self.granted = false                                          // re-check: revoked, or just refused once
                    self.declined = true
                    self.sampleAgain = false
                    self.status = .needsPermission
                    return
                }
                if error is SamplerError { return }                               // off-screen etc.: just skip
                self.consecutiveFailures += 1
                Log.ui.error("background sample failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(ns.localizedDescription, privacy: .public)")
                if self.consecutiveFailures >= 3 { self.status = .failed(ns.localizedDescription) }
            }
        }
    }

    private enum SamplerError: Error {
        case offScreen
    }

    /// The window's frame converted to ScreenCaptureKit's display space: points, origin at the top-left
    /// of the display that contains the window's centre.
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

    private struct Stats {
        let mean: RGB
        /// Median per-pixel luminance: what the text sits on for most of its area (a bright minority
        /// such as text glyphs or a window edge cannot drag it up the way a linear mean would).
        let luminance: Double
    }

    nonisolated private static func statistics(_ image: CGImage) -> Stats? {
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
}
