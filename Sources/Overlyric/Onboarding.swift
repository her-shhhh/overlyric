import AppKit

/// First-run experience for people who got the app as a file: makes sure it lives in /Applications
/// (so Launch at Login works and macOS stops running it from a temporary read-only location) and tells
/// them where to find it, since a menu-bar app has no Dock icon and no window.
@MainActor
enum Onboarding {
    private static let welcomedKey = "overlyric.welcomed"

    /// True when macOS is running us from a disk image or from App Translocation (a random read-only
    /// copy used for quarantined apps that were never moved).
    static var isRunningFromTemporaryLocation: Bool {
        let path = Bundle.main.bundlePath
        return path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/")
    }

    /// Offers to move the app into /Applications. Returns true if the app is relaunching from there.
    static func offerMoveToApplicationsIfNeeded() -> Bool {
        guard isRunningFromTemporaryLocation else { return false }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move Overlyric to Applications?"
        alert.informativeText = "Overlyric is running from a temporary location. Moving it to your Applications folder lets it start at login and keeps it working after you eject the download."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let fm = FileManager.default
        let destination = URL(fileURLWithPath: "/Applications/Overlyric.app")
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.trashItem(at: destination, resultingItemURL: nil)
            }
            try fm.copyItem(at: Bundle.main.bundleURL, to: destination)
        } catch {
            let failed = NSAlert()
            failed.messageText = "Couldn't move Overlyric"
            failed.informativeText = "Drag Overlyric into your Applications folder in Finder, then open it from there.\n\n(\(error.localizedDescription))"
            failed.runModal()
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    /// The very first launch shows a short hello in the overlay (only once, ever).
    static func takeWelcome() -> Bool {
        let d = UserDefaults.standard
        guard !d.bool(forKey: welcomedKey) else { return false }
        d.set(true, forKey: welcomedKey)
        return true
    }

    static let welcomeText = "Overlyric is on 🎤  Play a song on Spotify — the mic in your menu bar has all the settings"
}
