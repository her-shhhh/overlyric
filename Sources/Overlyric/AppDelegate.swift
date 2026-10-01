import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: LyricsController?
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Got it as a download and opened it straight from there? Offer to move it to Applications first.
        if Onboarding.offerMoveToApplicationsIfNeeded() { return }
        // A second copy was opened: show the running one's menu instead of a second overlay.
        if Onboarding.handOffToRunningInstance() { return }
        let controller = LyricsController()
        self.controller = controller
        statusMenu = StatusMenuController(controller: controller)
        controller.start()
    }

    /// Opened again while running (Finder, Spotlight, Launchpad): there's no window, so show the menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DispatchQueue.main.async { self.statusMenu?.showMenu() }   // after the reopen event has been answered
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

extension NSApplication {
    /// Quits (with `others`), then opens `bundle` — this app by default — once every one of those processes
    /// has exited, so two copies never run side by side. Returns false, and quits nothing, if the helper
    /// that reopens the app can't be started.
    @discardableResult
    func relaunch(_ bundle: URL = Bundle.main.bundleURL, arguments: [String] = [], quitting others: [NSRunningApplication] = []) -> Bool {
        let pids = ([getpid()] + others.map(\.processIdentifier)).map(String.init).joined(separator: " ")
        let args = arguments.isEmpty ? "" : " --args " + arguments.joined(separator: " ")
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits for each process (at most ~10 s each), then opens the bundle, which is passed as $0.
        helper.arguments = ["-c", """
            for p in \(pids); do n=0; while /bin/kill -0 $p 2>/dev/null && [ $n -lt 100 ]; do \
            /bin/sleep 0.1; n=$((n+1)); done; done; /usr/bin/open "$0"\(args)
            """, bundle.path]
        do {
            try helper.run()
        } catch {
            Log.ui.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        others.forEach { $0.terminate() }
        terminate(nil)
        return true
    }
}
