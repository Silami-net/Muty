import CoreAudio
import Foundation

/// Mutes and restores input devices.
///
/// Before Muty changes a device it saves the device's original mute and
/// volume values to UserDefaults. Restoring puts those values back. If Muty
/// crashes or is force-quit while a mic is muted, the saved values are still
/// there and are restored the next time Muty starts.
///
/// All CoreAudio work runs on one serial queue so key presses never wait on
/// the main thread.
final class MicMuter: @unchecked Sendable {
    /// Which controls Muty uses to silence a device.
    struct Controls {
        enum Method { case mute, volume }
        let method: Method
        let elements: [UInt32]
    }

    private struct SavedState: Codable {
        var mute: [String: UInt32] = [:]
        var volume: [String: Float32] = [:]
    }

    private let queue = DispatchQueue(label: "com.ambassadors.Muty.audio", qos: .userInteractive)
    private let defaultsKey = "savedDeviceStates"
    private var saved: [String: SavedState] // only touched on `queue`

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: SavedState].self, from: data) {
            saved = decoded
        } else {
            saved = [:]
        }
    }

    /// Finds the best way to silence a device, or nil if it can't be silenced.
    static func controls(for id: AudioDeviceID) -> Controls? {
        let channels = CoreAudioHAL.inputChannelCount(id)
        let elements = [UInt32(0)] + (channels > 0 ? Array(1...UInt32(channels)) : [])

        for (method, selector) in [(Controls.Method.mute, kAudioDevicePropertyMute),
                                   (Controls.Method.volume, kAudioDevicePropertyVolumeScalar)] {
            if CoreAudioHAL.isSettable(id, selector, element: 0) {
                return Controls(method: method, elements: [0])
            }
            let perChannel = elements.dropFirst().filter { CoreAudioHAL.isSettable(id, selector, element: $0) }
            if !perChannel.isEmpty {
                return Controls(method: method, elements: Array(perChannel))
            }
        }
        return nil
    }

    /// Mutes every present device whose UID is in `muteUIDs` and restores
    /// every other present device that Muty muted earlier.
    func sync(muteUIDs: Set<String>, devices: [AudioInputDevice]) {
        queue.async { self.performSync(muteUIDs: muteUIDs, devices: devices) }
    }

    /// Restores every present device right away. Used at launch and quit.
    func restoreAllNow(devices: [AudioInputDevice]) {
        queue.sync { self.performSync(muteUIDs: [], devices: devices) }
    }

    private func performSync(muteUIDs: Set<String>, devices: [AudioInputDevice]) {
        for device in devices {
            if muteUIDs.contains(device.uid) {
                mute(device)
            } else if saved[device.uid] != nil {
                restore(device)
            }
        }
    }

    private func mute(_ device: AudioInputDevice) {
        guard let controls = Self.controls(for: device.id) else { return }
        let selector = controls.method == .mute ? kAudioDevicePropertyMute : kAudioDevicePropertyVolumeScalar

        if saved[device.uid] == nil {
            var state = SavedState()
            for element in controls.elements {
                switch controls.method {
                case .mute:
                    if let v = CoreAudioHAL.getUInt32(device.id, selector, element: element) { state.mute[String(element)] = v }
                case .volume:
                    if let v = CoreAudioHAL.getFloat32(device.id, selector, element: element) { state.volume[String(element)] = v }
                }
            }
            saved[device.uid] = state
            persist() // save before changing anything, so a crash can be undone
        }

        for element in controls.elements {
            switch controls.method {
            case .mute: CoreAudioHAL.setUInt32(device.id, selector, element: element, 1)
            case .volume: CoreAudioHAL.setFloat32(device.id, selector, element: element, 0)
            }
        }
    }

    private func restore(_ device: AudioInputDevice) {
        guard let state = saved[device.uid] else { return }
        for (key, value) in state.mute {
            if let element = UInt32(key) { CoreAudioHAL.setUInt32(device.id, kAudioDevicePropertyMute, element: element, value) }
        }
        for (key, value) in state.volume {
            if let element = UInt32(key) { CoreAudioHAL.setFloat32(device.id, kAudioDevicePropertyVolumeScalar, element: element, value) }
        }
        saved[device.uid] = nil
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
