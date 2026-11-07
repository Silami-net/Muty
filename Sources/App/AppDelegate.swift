import AppKit
import CoreGraphics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private let controller = MicController.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()

        let statusItem = StatusItemController(controller: controller)
        self.statusItem = statusItem
        controller.onStateChange = { [weak statusItem] in statusItem?.refresh() }
        statusItem.refresh()

        observeSystemEvents()

        if !controller.hasPermission {
            _ = CGRequestListenEventAccess()
            SettingsWindowController.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    /// Reopening Muty from Finder or Spotlight while it runs opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        let release: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.monitor.forceRelease() }
        }
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: release)
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: release)
        workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: release)
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: release)

        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controller.devices.reload()
                self?.controller.update()
            }
        }
    }
}
