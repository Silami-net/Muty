import Combine
import Foundation

/// The one place that decides whether the mic should be muted.
///
///     off                     → leave the mic alone (restore it)
///     cough mode              → muted while the hotkey is held
///     talk mode               → muted unless the hotkey is held
///
/// Without Input Monitoring permission Muty can't see the hotkey, so it
/// never mutes. Otherwise talk mode would leave you muted with no way to speak.
@MainActor
final class MicController: ObservableObject {
    static let shared = MicController()

    @Published private(set) var isKeyHeld = false
    @Published private(set) var hasPermission = false
    @Published private(set) var isMuted = false
    /// Names of the devices currently being controlled.
    @Published private(set) var targetDeviceNames: [String] = []

    let settings = AppSettings.shared
    let monitor = HotkeyMonitor()
    let devices = AudioDeviceStore()
    let muter = MicMuter()

    /// Called whenever the menu bar icon should be redrawn.
    var onStateChange: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        // Undo anything left over from a previous run that didn't quit cleanly.
        muter.restoreAllNow(devices: devices.inputDevices)

        monitor.hotkey = settings.hotkey
        monitor.onHeldChange = { [weak self] held in
            self?.isKeyHeld = held
            self?.update()
        }
        monitor.onActiveChange = { [weak self] active in
            self?.hasPermission = active
            self?.update()
        }
        devices.onDevicesChanged = { [weak self] in self?.update() }
        devices.onLevelChanged = { [weak self] in
            guard let self, self.isMuted, self.settings.keepMuted else { return }
            self.update()
        }

        // @Published fires before the new value is stored, so apply on the next turn.
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.monitor.hotkey = self.settings.hotkey
                self.update()
            }
            .store(in: &cancellables)

        monitor.start()
        hasPermission = monitor.isActive
        update()
    }

    func update() {
        let targets = targetDevices()
        let wantMuted = settings.enabled
            && hasPermission
            && (settings.mode == .cough ? isKeyHeld : !isKeyHeld)
            && !targets.isEmpty

        muter.sync(muteUIDs: wantMuted ? Set(targets.map(\.uid)) : [], devices: devices.inputDevices)

        if isMuted != wantMuted { isMuted = wantMuted }
        let names = targets.map(\.name)
        if targetDeviceNames != names { targetDeviceNames = names }
        onStateChange?()
    }

    /// Restores every device. Called when Muty quits.
    func shutdown() {
        muter.restoreAllNow(devices: devices.inputDevices)
    }

    func targetDevices() -> [AudioInputDevice] {
        switch settings.deviceSelection {
        case DeviceSelection.all:
            return devices.inputDevices
        case DeviceSelection.systemDefault:
            guard let uid = devices.defaultInputUID, let device = devices.device(uid: uid) else { return [] }
            return [device]
        default:
            guard let device = devices.device(uid: settings.deviceSelection) else { return [] }
            return [device]
        }
    }
}
