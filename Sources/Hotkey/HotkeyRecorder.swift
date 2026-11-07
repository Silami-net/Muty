import AppKit

/// Records a custom hotkey from the Settings window.
///
/// - Press and release a modifier on its own (Right ⌃, Caps Lock, …) to
///   record a modifier-only hotkey.
/// - Press a key, with or without ⌘⌥⌃⇧, to record that key or combination.
/// - Esc cancels.
@MainActor
final class HotkeyRecorder: ObservableObject {
    @Published private(set) var isRecording = false

    var onRecord: ((Hotkey) -> Void)?
    var onCancel: (() -> Void)?

    private var eventMonitor: Any?
    private var pendingModifier: UInt16?

    func start() {
        guard !isRecording else { return }
        isRecording = true
        pendingModifier = nil
        MicController.shared.monitor.isSuspended = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event)
            return nil // swallow the key while recording
        }
    }

    func cancel() {
        guard isRecording else { return }
        stop()
        onCancel?()
    }

    private func stop() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        isRecording = false
        pendingModifier = nil
        MicController.shared.monitor.isSuspended = false
    }

    private func finish(_ hotkey: Hotkey) {
        stop()
        onRecord?(hotkey)
    }

    private func handle(_ event: NSEvent) {
        let flags = UInt64(event.modifierFlags.rawValue)

        switch event.type {
        case .flagsChanged:
            let code = event.keyCode
            guard Hotkey.isModifierKey(code), let name = Hotkey.modifierName(code) else { return }
            if code == 57 { // Caps Lock only reports presses
                finish(Hotkey(kind: .modifierOnly, keyCode: code, displayName: name))
                return
            }
            if Hotkey.isModifierDown(code, flags: flags) {
                pendingModifier = code
            } else if pendingModifier == code {
                finish(Hotkey(kind: .modifierOnly, keyCode: code, displayName: name))
            }

        case .keyDown:
            pendingModifier = nil
            let modifiers = flags & Hotkey.comboModifierMask
            if event.keyCode == 53 && modifiers == 0 { // Esc
                cancel()
                return
            }
            let name = Hotkey.modifierSymbols(modifiers)
                + Hotkey.keyName(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
            finish(Hotkey(kind: .key, keyCode: event.keyCode, modifiers: modifiers, displayName: name))

        default:
            break
        }
    }
}
