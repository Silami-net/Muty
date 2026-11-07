import Foundation

enum MicMode: String, CaseIterable, Identifiable {
    /// Mic is muted; hold the hotkey to speak.
    case talk
    /// Mic is live; hold the hotkey to mute.
    case cough

    var id: String { rawValue }
    var title: String { self == .talk ? "Talk" : "Cough" }
}

/// Device selection values other than a device UID.
enum DeviceSelection {
    static let all = "all"
    static let systemDefault = "default"
}

/// User settings, saved in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "enabled") }
    }
    @Published var mode: MicMode {
        didSet { defaults.set(mode.rawValue, forKey: "mode") }
    }
    /// "all", "default", or the UID of one device.
    @Published var deviceSelection: String {
        didSet { defaults.set(deviceSelection, forKey: "deviceSelection") }
    }
    /// Name of the selected device, so it can be shown while it's unplugged.
    @Published var deviceSelectionName: String {
        didSet { defaults.set(deviceSelectionName, forKey: "deviceSelectionName") }
    }
    @Published var hotkey: Hotkey {
        didSet {
            if let data = try? JSONEncoder().encode(hotkey) { defaults.set(data, forKey: "hotkey") }
        }
    }
    /// Re-mute if another app unmutes a device while Muty has it muted.
    @Published var keepMuted: Bool {
        didSet { defaults.set(keepMuted, forKey: "keepMuted") }
    }

    private init() {
        defaults.register(defaults: [
            "enabled": true,
            "mode": MicMode.cough.rawValue,
            "deviceSelection": DeviceSelection.all,
            "deviceSelectionName": "",
            "keepMuted": true,
        ])
        enabled = defaults.bool(forKey: "enabled")
        mode = MicMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .cough
        deviceSelection = defaults.string(forKey: "deviceSelection") ?? DeviceSelection.all
        deviceSelectionName = defaults.string(forKey: "deviceSelectionName") ?? ""
        keepMuted = defaults.bool(forKey: "keepMuted")
        if let data = defaults.data(forKey: "hotkey"), let saved = try? JSONDecoder().decode(Hotkey.self, from: data) {
            hotkey = saved
        } else {
            hotkey = .fn
        }
    }
}
