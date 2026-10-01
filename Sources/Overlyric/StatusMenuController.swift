import AppKit
import ServiceManagement

/// The menu-bar item (top-right) with the on/off toggle, colour, size, lock and quit.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private unowned let controller: LyricsController
    private let settings = Settings.shared

    private let toggleItem = NSMenuItem(title: "Show Lyrics", action: #selector(toggleEnabled), keyEquivalent: "")
    private let statusTitleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let statusDetailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let colorMenu = NSMenu(title: "Lyrics Colour")
    private let autoItem = NSMenuItem(title: "Auto — contrast with what's behind", action: #selector(toggleAuto), keyEquivalent: "")
    private let artworkItem = NSMenuItem(title: "Match album artwork", action: #selector(toggleArtwork), keyEquivalent: "")
    private let autoStatusItem = NSMenuItem(title: "", action: #selector(autoStatusClicked), keyEquivalent: "")
    private let lockItem = NSMenuItem(title: "Lock Position (click-through)", action: #selector(toggleLock), keyEquivalent: "")
    private let sizeSlider = NSSlider(value: Double(Settings.defaultFontSize), minValue: Double(Settings.minFontSize),
                                      maxValue: Double(Settings.maxFontSize), target: nil, action: nil)
    private let sizeValueLabel = NSTextField(labelWithString: "")
    private let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let styleMenu = NSMenu(title: "Lyrics Style")
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

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        statusTitleItem.isEnabled = false
        statusDetailItem.isEnabled = false
        menu.addItem(statusTitleItem)
        menu.addItem(statusDetailItem)
        menu.addItem(.separator())

        let styleItem = NSMenuItem(title: "Lyrics Style", action: nil, keyEquivalent: "")
        styleMenu.autoenablesItems = false
        for (i, style) in LyricsStyle.allCases.enumerated() {
            let it = NSMenuItem(title: style.title, action: #selector(pickStyle(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            it.toolTip = style.subtitle
            // Title + a quiet description underneath.
            let title = NSMutableAttributedString(string: style.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            title.append(NSAttributedString(string: "\n" + style.subtitle, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            it.attributedTitle = title
            styleMenu.addItem(it)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let colorItem = NSMenuItem(title: "Lyrics Colour", action: nil, keyEquivalent: "")
        colorMenu.autoenablesItems = false
        autoItem.target = self
        colorMenu.addItem(autoItem)
        autoStatusItem.target = self
        autoStatusItem.indentationLevel = 1
        colorMenu.addItem(autoStatusItem)
        artworkItem.target = self
        colorMenu.addItem(artworkItem)
        colorMenu.addItem(.separator())
        for (i, preset) in ColorPreset.all.enumerated() {
            let it = NSMenuItem(title: preset.name, action: #selector(pickPreset(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            it.image = Self.swatch(preset.color)
            colorMenu.addItem(it)
        }
        colorMenu.addItem(.separator())
        let custom = NSMenuItem(title: "Custom…", action: #selector(customColor), keyEquivalent: "")
        custom.target = self
        colorMenu.addItem(custom)
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        let sizeItem = NSMenuItem(title: "Text Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu(title: "Text Size")
        sizeMenu.autoenablesItems = false
        sizeMenu.addItem(makeSliderItem())
        sizeMenu.addItem(.separator())
        let bigger = NSMenuItem(title: "Bigger", action: #selector(zoomIn), keyEquivalent: "")
        let smaller = NSMenuItem(title: "Smaller", action: #selector(zoomOut), keyEquivalent: "")
        let reset = NSMenuItem(title: "Reset Size", action: #selector(zoomReset), keyEquivalent: "")
        let hint = NSMenuItem(title: "Tip: hold ⌘ and scroll on the lyrics", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        for it in [bigger, smaller, reset] { it.target = self; it.isEnabled = true; sizeMenu.addItem(it) }
        sizeMenu.addItem(.separator())
        sizeMenu.addItem(hint)
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        lockItem.target = self
        menu.addItem(lockItem)
        let resetPos = NSMenuItem(title: "Reset Position", action: #selector(resetPosition), keyEquivalent: "")
        resetPos.target = self
        menu.addItem(resetPos)
        menu.addItem(.separator())

        launchItem.target = self
        menu.addItem(launchItem)
        eggsItem.target = self
        menu.addItem(eggsItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Overlyric", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.toolTip = "Overlyric — Spotify lyrics overlay"
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
        item.isEnabled = true
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
        let style = settings.style
        for it in styleMenu.items { it.state = LyricsStyle.allCases.indices.contains(it.tag) && LyricsStyle.allCases[it.tag] == style ? .on : .off }
        // The easter-egg switch is itself a little secret: it only shows while ⌥ is held.
        eggsItem.isHidden = !NSEvent.modifierFlags.contains(.option)
        eggsItem.state = settings.easterEggs ? .on : .off
        sizeSlider.doubleValue = Double(settings.fontSize)
        sizeValueLabel.stringValue = "\(Int(settings.fontSize.rounded())) pt"
        toggleItem.state = settings.enabled ? .on : .off
        lockItem.state = settings.clickThrough ? .on : .off
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let status = controller.statusText
        statusTitleItem.title = status.title
        statusDetailItem.title = status.detail
        statusDetailItem.isHidden = status.detail.isEmpty
        let current = settings.color.usingColorSpace(.sRGB)
        let mode = settings.colorMode
        let auto = mode == .autoContrast
        autoItem.state = auto ? .on : .off
        artworkItem.state = mode == .artwork ? .on : .off
        for it in colorMenu.items where it.tag < ColorPreset.all.count && !it.isSeparatorItem && it.action == #selector(pickPreset(_:)) {
            let preset = ColorPreset.all[it.tag].color.usingColorSpace(.sRGB)
            it.state = (mode == .manual && current != nil && preset != nil && Self.close(current!, preset!)) ? .on : .off
        }
        let autoStatus: (String, Bool)
        switch (auto, controller.sampler.status) {
        case (false, _): autoStatus = ("", false)
        case (true, .needsPermission): autoStatus = ("Needs Screen Recording — click to open Settings", true)
        case (true, .failed(let msg)): autoStatus = ("Can't read the screen (\(msg))", false)
        case (true, .sampling): autoStatus = ("Picking readable colours from your screen", false)
        case (true, .off): autoStatus = ("Starts when lyrics are showing", false)
        }
        autoStatusItem.title = autoStatus.0
        autoStatusItem.isHidden = autoStatus.0.isEmpty
        autoStatusItem.isEnabled = autoStatus.1
    }

    private static func close(_ a: NSColor, _ b: NSColor) -> Bool {
        abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01 && abs(a.blueComponent - b.blueComponent) < 0.01
    }

    // MARK: Actions

    @objc private func toggleEnabled() { settings.enabled.toggle() }
    @objc private func toggleEggs() { settings.easterEggs.toggle() }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard LyricsStyle.allCases.indices.contains(sender.tag) else { return }
        settings.style = LyricsStyle.allCases[sender.tag]
    }
    @objc private func toggleLock() { settings.clickThrough.toggle() }

    @objc private func toggleAuto() {
        let turningOn = settings.colorMode != .autoContrast
        settings.colorMode = turningOn ? .autoContrast : .manual
        // The Screen Recording prompt is shown only here, when the user explicitly turns Auto on —
        // never at launch.
        if turningOn { controller.sampler.requestPermission() }
    }

    @objc private func toggleArtwork() {
        settings.colorMode = settings.colorMode == .artwork ? .manual : .artwork
    }

    @objc private func autoStatusClicked() {
        controller.sampler.requestPermission()
        BackgroundSampler.openSystemSettings()
    }

    @objc private func pickPreset(_ sender: NSMenuItem) {
        guard ColorPreset.all.indices.contains(sender.tag) else { return }
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
        NotificationCenter.default.addObserver(self, selector: #selector(colorPanelClosed(_:)),
                                               name: NSWindow.willCloseNotification, object: panel)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    @objc private func colorPanelClosed(_ note: Notification) {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: panel)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        settings.color = sender.color
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
                try service.register()
            }
        } catch {
            Log.ui.error("launch-at-login change failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

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
