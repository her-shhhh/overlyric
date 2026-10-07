import AppKit
import ServiceManagement

/// The menu-bar item (top-right): on/off, what's playing, style, font, colour, size, lock, position, login, quit.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private unowned let controller: LyricsController
    private let settings = Settings.shared

    private let toggleItem = NSMenuItem(title: "Show Lyrics", action: #selector(toggleEnabled), keyEquivalent: "")
    private let statusTitleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let statusDetailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let styleMenu = NSMenu(title: "Lyrics Style")
    private let fontMenu = NSMenu(title: "Lyrics Font")
    /// Shown in the font menu only while the Typewriter style (which keeps its own face) is on.
    private let typewriterNote = NSMenuItem(title: "Typewriter style keeps its own keys", action: nil, keyEquivalent: "")
    private let colorMenu = NSMenu(title: "Lyrics Colour")
    private let autoItem = NSMenuItem(title: "Auto", action: #selector(toggleAuto), keyEquivalent: "")
    private let autoStatusItem = NSMenuItem(title: "", action: #selector(autoStatusClicked), keyEquivalent: "")
    private let artworkItem = NSMenuItem(title: "Match album artwork", action: #selector(toggleArtwork), keyEquivalent: "")
    private var presetItems: [NSMenuItem] = []
    private let customItem = NSMenuItem(title: "Custom…", action: #selector(customColor), keyEquivalent: "")
    private let sizeSlider = NSSlider(value: Double(Settings.defaultFontSize), minValue: Double(Settings.minFontSize),
                                      maxValue: Double(Settings.maxFontSize), target: nil, action: nil)
    private let sizeValueLabel = NSTextField(labelWithString: "")
    /// Each menu's pending preview change (its own, so closing one never cancels the other's revert).
    /// Applied once the pointer rests on an item, so sweeping down the list doesn't rebuild the lyrics
    /// for every style it passes.
    private var previewWork: [ObjectIdentifier: DispatchWorkItem] = [:]
    private let lockItem = NSMenuItem(title: "Lock Position (click-through)", action: #selector(toggleLock), keyEquivalent: "")
    private let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    /// A little secret: holding ⌥ turns "Launch at Login" into this switch.
    private let eggsItem = NSMenuItem(title: "Easter Eggs", action: #selector(toggleEggs), keyEquivalent: "")

    init(controller: LyricsController) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        buildMenu()
        refreshIcon()
        NotificationCenter.default.addObserver(forName: .overlyricSettingsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIcon() }
        }
    }

    /// Opens the menu under the icon: the answer to "where did it go?" when the app is opened again.
    func showMenu() {
        statusItem.button?.performClick(nil)
    }

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        statusTitleItem.isEnabled = false
        statusDetailItem.target = self
        menu.addItem(statusTitleItem)
        menu.addItem(statusDetailItem)
        menu.addItem(.separator())

        styleMenu.autoenablesItems = false
        styleMenu.delegate = self
        for (i, style) in LyricsStyle.allCases.enumerated() {
            let it = NSMenuItem(title: style.title, action: #selector(pickStyle(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            Self.setTitle(it, style.title, subtitle: style.subtitle)
            styleMenu.addItem(it)
        }
        menu.addItem(Self.submenuItem(styleMenu))

        fontMenu.autoenablesItems = false
        fontMenu.delegate = self
        for (i, face) in LyricsFont.allCases.enumerated() {
            let it = NSMenuItem(title: face.title, action: #selector(pickFont(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            Self.setTitle(it, face.title, subtitle: face.subtitle)
            it.image = Self.fontSample(face)
            fontMenu.addItem(it)
        }
        typewriterNote.isEnabled = false
        fontMenu.addItem(typewriterNote)
        menu.addItem(Self.submenuItem(fontMenu))

        colorMenu.autoenablesItems = false
        colorMenu.delegate = self
        autoItem.target = self
        Self.setTitle(autoItem, "Auto", subtitle: "Vivid colours, readable on whatever is behind")
        colorMenu.addItem(autoItem)
        autoStatusItem.target = self
        autoStatusItem.indentationLevel = 1
        colorMenu.addItem(autoStatusItem)
        artworkItem.target = self
        Self.setTitle(artworkItem, "Match album artwork", subtitle: "The cover's colour, brightened")
        colorMenu.addItem(artworkItem)
        colorMenu.addItem(.separator())
        for (i, preset) in ColorPreset.all.enumerated() {
            let it = NSMenuItem(title: preset.name, action: #selector(pickPreset(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            it.image = Self.swatch(preset.color)
            colorMenu.addItem(it)
            presetItems.append(it)
        }
        colorMenu.addItem(.separator())
        customItem.target = self
        colorMenu.addItem(customItem)
        menu.addItem(Self.submenuItem(colorMenu))

        let sizeMenu = NSMenu(title: "Text Size")
        sizeMenu.autoenablesItems = false
        sizeMenu.addItem(makeSliderItem())
        sizeMenu.addItem(.separator())
        let bigger = NSMenuItem(title: "Bigger", action: #selector(zoomIn), keyEquivalent: "")
        let smaller = NSMenuItem(title: "Smaller", action: #selector(zoomOut), keyEquivalent: "")
        let reset = NSMenuItem(title: "Reset Size", action: #selector(zoomReset), keyEquivalent: "")
        for it in [bigger, smaller, reset] { it.target = self; sizeMenu.addItem(it) }
        sizeMenu.addItem(.separator())
        let hint = NSMenuItem(title: "Tip: hold ⌘ and scroll on the lyrics", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        sizeMenu.addItem(hint)
        menu.addItem(Self.submenuItem(sizeMenu))

        lockItem.target = self
        menu.addItem(lockItem)
        let resetPos = NSMenuItem(title: "Reset Position", action: #selector(resetPosition), keyEquivalent: "")
        resetPos.target = self
        menu.addItem(resetPos)
        menu.addItem(.separator())

        launchItem.target = self
        launchItem.keyEquivalentModifierMask = []
        menu.addItem(launchItem)
        eggsItem.target = self
        eggsItem.keyEquivalentModifierMask = .option
        eggsItem.isAlternate = true
        menu.addItem(eggsItem)
        menu.addItem(.separator())

        let guide = NSMenuItem(title: "Read This or Hum Forever…", action: #selector(openGuide), keyEquivalent: "")
        guide.target = self
        guide.image = NSImage(systemSymbolName: "book", accessibilityDescription: "Guide")
        guide.toolTip = "The story, the setup and every control"
        menu.addItem(guide)

        let quit = NSMenuItem(title: "Quit Overlyric", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        controller.panel.overlayView.contextMenu = menu
        statusItem.button?.toolTip = "Overlyric — Spotify lyrics overlay"
    }

    private static func submenuItem(_ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// A title with a quieter description underneath.
    private static func setTitle(_ item: NSMenuItem, _ title: String, subtitle: String) {
        if #available(macOS 14.4, *) {
            item.title = title
            item.subtitle = subtitle
        } else {
            let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            text.append(NSAttributedString(string: "\n" + subtitle, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            item.attributedTitle = text
        }
    }

    /// "Aa" in the font, as a template image (the menu tints it for light, dark and highlighted rows).
    private static func fontSample(_ face: LyricsFont) -> NSImage {
        let text = NSAttributedString(string: "Aa", attributes: [.font: face.font(15, .heavy), .foregroundColor: NSColor.black])
        let size = NSSize(width: 26, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let ink = text.size()
            text.draw(at: NSPoint(x: (rect.width - ink.width) / 2, y: (rect.height - ink.height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// A live slider inside the Text Size submenu: drag for fine control, the overlay follows instantly.
    private func makeSliderItem() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 262, height: 34))
        let small = NSTextField(labelWithString: "A")
        small.font = .systemFont(ofSize: 11, weight: .semibold)
        small.alignment = .center
        small.frame = NSRect(x: 12, y: 9, width: 16, height: 16)
        sizeSlider.frame = NSRect(x: 30, y: 7, width: 160, height: 20)
        sizeSlider.isContinuous = true
        sizeSlider.target = self
        sizeSlider.action = #selector(sliderChanged(_:))
        let big = NSTextField(labelWithString: "A")
        big.font = .systemFont(ofSize: 20, weight: .heavy)
        big.alignment = .center
        big.frame = NSRect(x: 192, y: 4, width: 22, height: 26)
        sizeValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeValueLabel.textColor = .secondaryLabelColor
        sizeValueLabel.alignment = .right
        sizeValueLabel.frame = NSRect(x: 214, y: 9, width: 40, height: 16)
        for v in [small, sizeSlider, big, sizeValueLabel] { container.addSubview(v) }
        let item = NSMenuItem()
        item.view = container
        return item
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let size = CGFloat(sender.doubleValue.rounded())
        sizeValueLabel.stringValue = "\(Int(size)) pt"
        if size != settings.fontSize { settings.fontSize = size }
    }

    private static let icon: NSImage? = {
        let image = NSImage(systemSymbolName: "music.mic", accessibilityDescription: "Overlyric")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        image?.isTemplate = true
        return image
    }()

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        if button.image == nil { button.image = Self.icon }
        button.appearsDisabled = !settings.enabled
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }      // the Style and Font menus only preview
        let style = settings.style
        for it in styleMenu.items { it.state = LyricsStyle.allCases[it.tag] == style ? .on : .off }
        let face = settings.font
        for it in fontMenu.items where it !== typewriterNote { it.state = LyricsFont.allCases[it.tag] == face ? .on : .off }
        typewriterNote.isHidden = style != .typewriter
        eggsItem.state = settings.easterEggs ? .on : .off
        sizeSlider.doubleValue = Double(settings.fontSize)
        sizeValueLabel.stringValue = "\(Int(settings.fontSize.rounded())) pt"
        toggleItem.state = settings.enabled ? .on : .off
        lockItem.state = settings.clickThrough ? .on : .off
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        let status = controller.statusText
        statusTitleItem.title = Self.clipped(status.title, to: 60)
        statusDetailItem.title = status.detail
        statusDetailItem.isHidden = status.detail.isEmpty
        // The detail is "allow Automation…" exactly when Spotify can't be read and nothing has been heard yet.
        let automationBlocked = controller.monitor.automation == .denied && controller.monitor.snapshot.track == nil
        statusDetailItem.action = automationBlocked ? #selector(openAutomationSettings) : nil
        statusDetailItem.isEnabled = automationBlocked

        let mode = settings.colorMode
        autoItem.state = mode == .autoContrast ? .on : .off
        artworkItem.state = mode == .artwork ? .on : .off
        let current = settings.color.usingColorSpace(.sRGB)
        var matchedPreset = false
        for it in presetItems {
            let on = mode == .manual && current.map { Self.close($0, ColorPreset.all[it.tag].color) } == true
            it.state = on ? .on : .off
            matchedPreset = matchedPreset || on
        }
        customItem.state = mode == .manual && !matchedPreset ? .on : .off
        updateAutoStatus(auto: mode == .autoContrast)
    }

    /// Hovering a style, font or preset colour tries it on the lyrics; clicking keeps it (the pick saves it
    /// as before). Auto, Match album artwork and Custom… just show the saved look while hovered.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        if menu === styleMenu {
            let style = item.map { LyricsStyle.allCases[$0.tag] }
            schedule(menu, after: 0.08) { $0.preview(style: style) }
        } else if menu === fontMenu {
            let face = item.flatMap { $0 === typewriterNote ? nil : LyricsFont.allCases[$0.tag] }
            schedule(menu, after: 0.08) { $0.preview(font: face) }
        } else if menu === colorMenu {
            let color = item.flatMap { presetItems.contains($0) ? ColorPreset.all[$0.tag].color : nil }
            schedule(menu, after: 0.08) { $0.preview(color: color) }
        }
    }

    /// Leaving without a pick puts the saved look back. A click's action arrives just after the menu
    /// closes, so the preview is dropped a moment later: by then the pick is saved and nothing flickers.
    /// Closing the whole menu does the same for both, in case a submenu wasn't told it closed.
    func menuDidClose(_ menu: NSMenu) {
        if menu === styleMenu || menu === self.menu { schedule(styleMenu, after: 0.15) { $0.preview(style: nil) } }
        if menu === fontMenu || menu === self.menu { schedule(fontMenu, after: 0.15) { $0.preview(font: nil) } }
        if menu === colorMenu || menu === self.menu { schedule(colorMenu, after: 0.15) { $0.preview(color: nil) } }
    }

    private func schedule(_ menu: NSMenu, after delay: TimeInterval, _ apply: @escaping (LyricsController) -> Void) {
        let key = ObjectIdentifier(menu)
        previewWork[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let controller = self?.controller else { return }
            apply(controller)
        }
        previewWork[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The line under Auto: what it is doing, or the one click that gets Screen Recording working.
    private func updateAutoStatus(auto: Bool) {
        let sampler = controller.sampler
        let row: (title: String, clickable: Bool)
        if !auto {
            row = ("", false)
        } else if !sampler.hasAccess {
            switch sampler.permissionStep {
            case .ask: row = ("Needs Screen Recording — click to allow", true)
            case .reopen: row = ("Allowed it? Click to reopen Overlyric", true)
            case .reset: row = ("Still not allowed — click to reset the permission and ask again", true)
            }
        } else {
            sampler.refresh()
            switch sampler.status {
            case .failed(let msg): row = ("Can't read the screen (\(msg))", false)
            case .off: row = ("Starts when lyrics are showing", false)
            case .sampling, .needsPermission: row = ("Picking readable colours from your screen", false)
            }
        }
        autoStatusItem.title = row.title
        autoStatusItem.isHidden = row.title.isEmpty
        autoStatusItem.isEnabled = row.clickable
    }

    private static func close(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }

    /// Keeps a long track or artist name from stretching the whole menu.
    private static func clipped(_ s: String, to n: Int) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }

    // MARK: Actions

    @objc private func toggleEnabled() { settings.enabled.toggle() }
    @objc private func toggleEggs() { settings.easterEggs.toggle() }
    @objc private func toggleLock() { settings.clickThrough.toggle() }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        settings.style = LyricsStyle.allCases[sender.tag]
    }

    @objc private func pickFont(_ sender: NSMenuItem) {
        settings.font = LyricsFont.allCases[sender.tag]
    }

    @objc private func toggleAuto() {
        let turningOn = settings.colorMode != .autoContrast
        settings.colorMode = turningOn ? .autoContrast : .manual
        // Screen Recording is asked for only here and from the status row — never at launch.
        if turningOn { controller.sampler.requestPermission() }
    }

    @objc private func autoStatusClicked() {
        controller.sampler.continuePermission()
    }

    @objc private func toggleArtwork() {
        settings.colorMode = settings.colorMode == .artwork ? .manual : .artwork
    }

    @objc private func pickPreset(_ sender: NSMenuItem) {
        if settings.colorMode != .manual { settings.colorMode = .manual }
        settings.color = ColorPreset.all[sender.tag].color
    }

    @objc private func customColor() {
        if settings.colorMode != .manual { settings.colorMode = .manual }
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = settings.color
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.willCloseNotification, object: panel)
        center.addObserver(self, selector: #selector(colorPanelClosed(_:)), name: NSWindow.willCloseNotification, object: panel)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        // Picking from the wheel means "this colour", even if Auto or Artwork was turned on meanwhile.
        if settings.colorMode != .manual { settings.colorMode = .manual }
        settings.color = sender.color
    }

    @objc private func colorPanelClosed(_ note: Notification) {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: panel)
        NSApp.deactivate()        // hand the keyboard back to the app that was in front
    }

    @objc private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func zoomIn() { settings.fontSize = settings.fontSize * 1.15 }
    @objc private func zoomOut() { settings.fontSize = settings.fontSize / 1.15 }
    @objc private func zoomReset() { settings.fontSize = Settings.defaultFontSize }

    @objc private func resetPosition() {
        settings.windowTop = nil
        controller.panel.moveTop(to: nil)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()   // the user disabled it in Login Items
            default:
                // A copy macOS runs from a temporary location can't be a login item; move it first.
                guard !Onboarding.isRunningFromTemporaryLocation else {
                    _ = Onboarding.offerMoveToApplicationsIfNeeded()
                    return
                }
                try service.register()
            }
        } catch {
            Log.ui.error("launch-at-login change failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
            NSApp.deactivate()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// Shows the guide (the story, the setup and every control) in its own window.
    @objc private func openGuide() { GuideWindow.shared.show() }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            color.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }
}
