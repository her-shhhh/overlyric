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
    private let lockItem = NSMenuItem(title: "Lock Position (click-through)", action: #selector(toggleLock), keyEquivalent: "")
    private let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

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

        let colorItem = NSMenuItem(title: "Lyrics Colour", action: nil, keyEquivalent: "")
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
        let bigger = NSMenuItem(title: "Bigger", action: #selector(zoomIn), keyEquivalent: "")
        let smaller = NSMenuItem(title: "Smaller", action: #selector(zoomOut), keyEquivalent: "")
        let reset = NSMenuItem(title: "Reset Size", action: #selector(zoomReset), keyEquivalent: "")
        let hint = NSMenuItem(title: "Tip: pinch on the lyrics to zoom", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        for it in [bigger, smaller, reset] { it.target = self; sizeMenu.addItem(it) }
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
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Overlyric", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.toolTip = "Overlyric — Spotify lyrics overlay"
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
        toggleItem.state = settings.enabled ? .on : .off
        lockItem.state = settings.clickThrough ? .on : .off
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let status = controller.statusText
        statusTitleItem.title = status.title
        statusDetailItem.title = status.detail
        statusDetailItem.isHidden = status.detail.isEmpty
        let current = settings.color.usingColorSpace(.sRGB)
        for it in colorMenu.items where it.tag < ColorPreset.all.count && !it.isSeparatorItem && it.action == #selector(pickPreset(_:)) {
            let preset = ColorPreset.all[it.tag].color.usingColorSpace(.sRGB)
            it.state = (current != nil && preset != nil && Self.close(current!, preset!)) ? .on : .off
        }
    }

    private static func close(_ a: NSColor, _ b: NSColor) -> Bool {
        abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01 && abs(a.blueComponent - b.blueComponent) < 0.01
    }

    // MARK: Actions

    @objc private func toggleEnabled() { settings.enabled.toggle() }
    @objc private func toggleLock() { settings.clickThrough.toggle() }

    @objc private func pickPreset(_ sender: NSMenuItem) {
        guard ColorPreset.all.indices.contains(sender.tag) else { return }
        settings.color = ColorPreset.all[sender.tag].color
    }

    @objc private func customColor() {
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
        settings.windowCenter = nil
        controller.panel.moveCenter(to: nil)
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
