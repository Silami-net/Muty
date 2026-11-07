import AppKit
import os

private let log = Logger(subsystem: "com.ambassadors.Muty", category: "menubar")

/// The menu bar icon.
///
/// - Left-click turns Muty on or off (off shows a faded icon).
/// - ⌥-click switches between Cough and Talk mode. (⌘-click is kept by
///   macOS for rearranging menu bar icons and never reaches the app.)
/// - Right-click (or Control-click) opens the menu.
@MainActor
final class StatusItemController: NSObject {
    private let controller: MicController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init(controller: MicController) {
        self.controller = controller
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refresh()
    }

    private func toggleMode() {
        let settings = controller.settings
        settings.mode = settings.mode == .cough ? .talk : .cough
        log.notice("Mode switched to \(settings.mode.rawValue, privacy: .public)")
    }

    func refresh() {
        guard let button = statusItem.button else { return }
        let settings = controller.settings

        let symbol: String
        let description: String
        var faded = false

        if !controller.hasPermission {
            symbol = "mic.badge.xmark"
            description = "Muty needs Input Monitoring permission. Right-click → Settings…"
        } else if !settings.enabled {
            symbol = "mic"
            faded = true
            description = "Muty is off. Click to turn on."
        } else if controller.isMuted {
            symbol = "mic.slash.fill"
            description = "Muted · \(settings.mode.title) mode · hold \(settings.hotkey.displayName) to \(settings.mode == .talk ? "talk" : "stay muted")"
        } else {
            symbol = "mic.fill"
            let action = settings.mode == .cough ? "mute" : "talk"
            description = "Live · \(settings.mode.title) mode · hold \(settings.hotkey.displayName) to \(action)"
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Muty")
            ?? NSImage(systemSymbolName: "mic", accessibilityDescription: "Muty")
        image?.isTemplate = true
        button.image = image
        // One fade only: appearsDisabled on top of a lower alpha made the
        // off icon almost invisible.
        button.appearsDisabled = false
        button.alphaValue = faded ? 0.55 : 1
        button.toolTip = description
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        // On recent macOS, menu bar clicks reach the app as a system action
        // and the event's modifier flags can come through empty. Also ask the
        // keyboard directly which modifiers are held right now.
        let flags = event.modifierFlags
            .union(NSEvent.modifierFlags)
            .union(NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue)))
            .intersection(.deviceIndependentFlagsMask)
        log.notice("Icon click: type=\(event.type.rawValue, privacy: .public) eventFlags=\(event.modifierFlags.rawValue, privacy: .public) liveFlags=\(flags.rawValue, privacy: .public)")

        if event.type == .rightMouseUp || event.type == .rightMouseDown || flags.contains(.control) {
            showMenu()
        } else if flags.contains(.command) || flags.contains(.option) {
            // ⌥-click switches between Cough and Talk mode.
            toggleMode()
        } else {
            controller.settings.enabled.toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let hotkeyItem = NSMenuItem(title: "Hotkey: \(controller.settings.hotkey.displayName)", action: nil, keyEquivalent: "")
        hotkeyItem.isEnabled = false
        menu.addItem(hotkeyItem)

        let mode = controller.settings.mode
        let modeItem = NSMenuItem(
            title: "Mode: \(mode == .talk ? "Talk (hold to speak)" : "Cough (hold to mute)") · ⌥-click icon to switch",
            action: nil, keyEquivalent: "")
        modeItem.isEnabled = false
        menu.addItem(modeItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Muty", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
