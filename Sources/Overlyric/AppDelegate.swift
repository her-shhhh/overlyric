import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: LyricsController?
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Got it as a download and opened it straight from there? Offer to move it to Applications first.
        if Onboarding.offerMoveToApplicationsIfNeeded() { return }
        let controller = LyricsController()
        self.controller = controller
        statusMenu = StatusMenuController(controller: controller)
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
