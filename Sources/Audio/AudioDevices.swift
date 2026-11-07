import CoreAudio
import Foundation

/// An audio device that has at least one input stream.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Small helpers around the CoreAudio HAL property API.
enum CoreAudioHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func isSettable(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector, element: UInt32) -> Bool {
        var addr = address(selector, kAudioObjectPropertyScopeInput, element)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    static func getUInt32(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector, element: UInt32) -> UInt32? {
        var addr = address(selector, kAudioObjectPropertyScopeInput, element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func getFloat32(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector, element: UInt32) -> Float32? {
        var addr = address(selector, kAudioObjectPropertyScopeInput, element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    static func setUInt32(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector, element: UInt32, _ value: UInt32) -> Bool {
        var addr = address(selector, kAudioObjectPropertyScopeInput, element)
        var v = value
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }

    @discardableResult
    static func setFloat32(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector, element: UInt32, _ value: Float32) -> Bool {
        var addr = address(selector, kAudioObjectPropertyScopeInput, element)
        var v = value
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? "Unknown device"
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Keeps an up-to-date list of input devices and reports changes:
/// devices plugged in or removed, the default input changing, and
/// mute or volume changes made on a device by something other than Muty.
@MainActor
final class AudioDeviceStore: ObservableObject {
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published private(set) var defaultInputUID: String?

    /// Called when the device list or default input changes.
    var onDevicesChanged: (() -> Void)?
    /// Called when a device's mute or input volume changes.
    var onLevelChanged: (() -> Void)?

    private var systemListener: AudioObjectPropertyListenerBlock?
    private var deviceListeners: [(AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        reload()
        installSystemListeners()
    }

    func reload() {
        inputDevices = CoreAudioHAL.inputDevices()
        if let id = CoreAudioHAL.defaultInputDeviceID() {
            defaultInputUID = CoreAudioHAL.string(id, kAudioDevicePropertyDeviceUID)
        } else {
            defaultInputUID = nil
        }
        reinstallDeviceListeners()
    }

    func device(uid: String) -> AudioInputDevice? {
        inputDevices.first { $0.uid == uid }
    }

    private func installSystemListeners() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reload()
                self.onDevicesChanged?()
            }
        }
        systemListener = block
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var addr = CoreAudioHAL.address(selector)
            AudioObjectAddPropertyListenerBlock(CoreAudioHAL.system, &addr, DispatchQueue.main, block)
        }
    }

    private func reinstallDeviceListeners() {
        for (id, addr, block) in deviceListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(id, &a, DispatchQueue.main, block)
        }
        deviceListeners.removeAll()

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onLevelChanged?() }
        }
        for device in inputDevices {
            let channels = CoreAudioHAL.inputChannelCount(device.id)
            for element in 0...UInt32(max(channels, 0)) {
                for selector in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
                    var addr = CoreAudioHAL.address(selector, kAudioObjectPropertyScopeInput, element)
                    guard AudioObjectHasProperty(device.id, &addr) else { continue }
                    if AudioObjectAddPropertyListenerBlock(device.id, &addr, DispatchQueue.main, block) == noErr {
                        deviceListeners.append((device.id, addr, block))
                    }
                }
            }
        }
    }
}
