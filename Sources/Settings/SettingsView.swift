import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Muty Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        guard let window else { return }

        // Center each time it opens (unless it's already on screen), after
        // SwiftUI has sized the content, on the screen the mouse is on.
        if !window.isVisible {
            if let content = window.contentViewController?.view {
                content.layoutSubtreeIfNeeded()
                window.setContentSize(content.fittingSize)
            }
            centerOnActiveScreen(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func centerOnActiveScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(),
                                      y: (area.midY - size.height / 2).rounded()))
    }
}

/// View state kept in an object instead of @State, so the app builds with
/// the Command Line Tools alone (they don't include SwiftUI's macro plugin).
@MainActor
final class SettingsViewState: ObservableObject {
    /// True while "Custom…" is picked but nothing has been recorded yet.
    @Published var customPicked = false
    @Published var launchAtLogin = LoginItem.isEnabled
    @Published var loginNeedsApproval = LoginItem.needsApproval
    @Published var loginError: String?
}

private enum HotkeyChoice: Hashable {
    case preset(Int)
    case custom
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var controller = MicController.shared
    @ObservedObject private var devices = MicController.shared.devices
    @StateObject private var recorder = HotkeyRecorder()

    @StateObject private var state = SettingsViewState()

    var body: some View {
        Form {
            if !controller.hasPermission {
                permissionSection
            }
            hotkeySection
            modeSection
            deviceSection
            generalSection
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            recorder.onRecord = { hotkey in
                settings.hotkey = hotkey
                state.customPicked = false
            }
            recorder.onCancel = { state.customPicked = false }
            refreshLoginState()
        }
        .onDisappear { recorder.cancel() }
    }

    // MARK: Permission

    private var permissionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Muty needs Input Monitoring permission", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)
                Text("This lets Muty see when you hold the hotkey, from any app. Muty only watches the hotkey and never records what you type. Until it's allowed, Muty leaves your mic alone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Input Monitoring Settings") {
                        _ = CGRequestListenEventAccess()
                        SystemSettingsLinks.openInputMonitoring()
                    }
                    Button("Relaunch Muty") { AppRelauncher.relaunch() }
                }
                Text("Turn on Muty in the list, then come back. If nothing changes after a few seconds, click Relaunch Muty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Hotkey

    private var hotkeyChoice: Binding<HotkeyChoice> {
        Binding(
            get: {
                if state.customPicked { return .custom }
                if let index = Hotkey.presets.firstIndex(of: settings.hotkey) { return .preset(index) }
                return .custom
            },
            set: { choice in
                switch choice {
                case .preset(let index):
                    recorder.cancel()
                    state.customPicked = false
                    settings.hotkey = Hotkey.presets[index]
                case .custom:
                    state.customPicked = true
                    recorder.start()
                }
            }
        )
    }

    private var isCustom: Bool { state.customPicked || !settings.hotkey.isPreset }

    private var hotkeySection: some View {
        Section("Hotkey") {
            HStack {
                Picker("Hold to activate", selection: hotkeyChoice) {
                    ForEach(Array(Hotkey.presets.enumerated()), id: \.offset) { index, preset in
                        Text(preset.displayName).tag(HotkeyChoice.preset(index))
                    }
                    Divider()
                    Text("Custom…").tag(HotkeyChoice.custom)
                }
                Circle()
                    .fill(controller.isKeyHeld ? Color.green : Color.secondary.opacity(0.25))
                    .frame(width: 10, height: 10)
                    .help("Lights up while you hold the hotkey")
            }

            if isCustom {
                HStack {
                    Text("Custom hotkey")
                    Spacer()
                    Button {
                        recorder.isRecording ? recorder.cancel() : recorder.start()
                    } label: {
                        Text(recorder.isRecording ? "Press a key… (Esc to cancel)" : settings.hotkey.displayName)
                            .frame(minWidth: 160)
                    }
                }
                Text("Press and release a single modifier (like Right ⌃ or Caps Lock), or press a key or combination (like F13 or ⌃⌥Space). On a Mac keyboard, hold Fn while pressing F1–F12, or turn on “Use F1, F2, etc. keys as standard function keys” in Keyboard settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let warning = settings.hotkey.warning, !recorder.isRecording {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if settings.hotkey.isFn && !state.customPicked {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tip: in Keyboard settings, set “Press 🌐 key to” to “Do Nothing”. Otherwise holding Fn also opens the emoji picker or starts dictation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Keyboard Settings") { SystemSettingsLinks.openKeyboard() }
                        .controlSize(.small)
                }
            }

            if settings.hotkey != .fn || state.customPicked {
                Button("Reset to Fn") {
                    recorder.cancel()
                    state.customPicked = false
                    settings.hotkey = .fn
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: Mode

    private var modeSection: some View {
        Section("Mode") {
            Picker("Mode", selection: $settings.mode) {
                Text("Talk (hold to speak)").tag(MicMode.talk)
                Text("Cough (hold to mute)").tag(MicMode.cough)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(settings.mode == .talk
                 ? "Your mic stays muted. Hold the hotkey to speak."
                 : "Your mic stays live. Hold the hotkey to mute it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Devices

    private var deviceSelection: Binding<String> {
        Binding(
            get: { settings.deviceSelection },
            set: { uid in
                settings.deviceSelection = uid
                settings.deviceSelectionName = devices.device(uid: uid)?.name ?? ""
            }
        )
    }

    private var defaultInputName: String {
        guard let uid = devices.defaultInputUID, let device = devices.device(uid: uid) else { return "none" }
        return device.name
    }

    private var selectedDeviceMissing: Bool {
        let selection = settings.deviceSelection
        return selection != DeviceSelection.all
            && selection != DeviceSelection.systemDefault
            && devices.device(uid: selection) == nil
    }

    private var deviceSection: some View {
        Section("Microphone") {
            Picker("Control", selection: deviceSelection) {
                Text("All inputs").tag(DeviceSelection.all)
                Text("Current default input (\(defaultInputName))").tag(DeviceSelection.systemDefault)
                Divider()
                ForEach(devices.inputDevices) { device in
                    let controllable = MicMuter.controls(for: device.id) != nil
                    Text(controllable ? device.name : "\(device.name) — can't be muted")
                        .tag(device.uid)
                }
                if selectedDeviceMissing {
                    Text("\(settings.deviceSelectionName.isEmpty ? "Device" : settings.deviceSelectionName) (not connected)")
                        .tag(settings.deviceSelection)
                }
            }
            Toggle("Keep muted if another app unmutes the mic", isOn: $settings.keepMuted)
        }
    }

    // MARK: General

    private var generalSection: some View {
        Section("General") {
            Toggle("Start Muty at login", isOn: Binding(
                get: { state.launchAtLogin },
                set: { newValue in
                    do {
                        try LoginItem.set(newValue)
                        state.loginError = nil
                    } catch {
                        state.loginError = "Couldn't change this: \(error.localizedDescription)"
                    }
                    refreshLoginState()
                }
            ))
            if state.loginNeedsApproval {
                HStack {
                    Text("Allow Muty in Login Items to finish.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items") { SystemSettingsLinks.openLoginItems() }
                        .controlSize(.small)
                }
            }
            if let loginError = state.loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
            Toggle("Muty is on", isOn: $settings.enabled)
        }
    }

    private func refreshLoginState() {
        state.launchAtLogin = LoginItem.isEnabled || LoginItem.needsApproval
        state.loginNeedsApproval = LoginItem.needsApproval
    }
}
