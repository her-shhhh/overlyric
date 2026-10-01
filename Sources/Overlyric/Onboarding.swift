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

        let destination = URL(fileURLWithPath: "/Applications/Overlyric.app")
        do {
            try install(at: destination)
        } catch {
            let failed = NSAlert()
            failed.messageText = "Couldn't move Overlyric"
            failed.informativeText = "Drag Overlyric into your Applications folder in Finder, then open it from there.\n\n(\(error.localizedDescription))"
            failed.runModal()
            return false
        }
        // Started from a disk image: eject it once this copy has quit.
        let volume = Bundle.main.bundlePath.hasPrefix("/Volumes/")
            ? "/Volumes/" + (Bundle.main.bundlePath.dropFirst("/Volumes/".count).split(separator: "/").first.map(String.init) ?? "")
            : nil
        // An older copy may still be running: it quits too, so the moved copy starts as the only one.
        return NSApp.relaunch(destination, quitting: otherInstances, thenEject: volume)
    }

    /// Puts this version at `destination` (skipping the copy when the same version is already there) and
    /// clears the "downloaded from the internet" flag on it. That flag is what makes macOS run a copied
    /// app from a temporary location or block it again; the user has already approved this app by
    /// opening it, so the installed copy shouldn't carry the flag.
    private static func install(at destination: URL) throws {
        let fm = FileManager.default
        if !isSameVersion(at: destination) {
            if fm.fileExists(atPath: destination.path) {
                try fm.trashItem(at: destination, resultingItemURL: nil)
            }
            try fm.copyItem(at: Bundle.main.bundleURL, to: destination)
        }
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", destination.path]
        try xattr.run()
        xattr.waitUntilExit()
    }

    private static func isSameVersion(at url: URL) -> Bool {
        guard let other = Bundle(url: url)?.infoDictionary, let mine = Bundle.main.infoDictionary else { return false }
        return other["CFBundleShortVersionString"] as? String == mine["CFBundleShortVersionString"] as? String
            && other["CFBundleVersion"] as? String == mine["CFBundleVersion"] as? String
    }

    /// If a copy launched earlier is running, opens that one (which shows its menu) and quits this one.
    static func handOffToRunningInstance() -> Bool {
        let me = NSRunningApplication.current
        let myLaunch = (me.launchDate ?? .distantPast, me.processIdentifier)
        guard let other = otherInstances.first(where: { ($0.launchDate ?? .distantPast, $0.processIdentifier) < myLaunch }),
              let url = other.bundleURL else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    private static var otherInstances: [NSRunningApplication] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me && !$0.isTerminated }
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
