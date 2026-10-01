import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: LyricsController?
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
