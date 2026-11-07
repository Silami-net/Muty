import AppKit
import CoreGraphics
import os

private let log = Logger(subsystem: "com.ambassadors.Muty", category: "hotkey")

/// Watches the keyboard system-wide (listen-only, nothing is blocked) and
/// reports when the hotkey is held down and released.
///
/// Needs the Input Monitoring permission. Until that is granted the monitor
/// stays inactive and retries every two seconds.
@MainActor
final class HotkeyMonitor {
    var hotkey: Hotkey = .fn {
        didSet { if hotkey != oldValue { forceRelease() } }
    }

    /// While suspended (for example while recording a new hotkey) key
    /// presses are ignored.
    var isSuspended = false {
        didSet { if isSuspended { forceRelease() } }
    }

    var onHeldChange: ((Bool) -> Void)?
    var onActiveChange: ((Bool) -> Void)?

    private(set) var isHeld = false
    private(set) var isActive = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?
    private var stuckKeyTimer: Timer?

    func start() {
        installTap()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installTap() }
        }
    }

    /// Treats the hotkey as released, for example on sleep or screen lock.
    func forceRelease() {
        setHeld(false)
    }

    private func installTap() {
        guard tap == nil else { return }
        guard CGPreflightListenEventAccess() else {
            setActive(false)
            return
        }

        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: refcon
        ) else {
            setActive(false)
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        tap = newTap
        runLoopSource = source
        retryTimer?.invalidate()
        retryTimer = nil
        setActive(true)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard !isSuspended else { return }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue

        switch hotkey.kind {
        case .modifierOnly:
            if type == .flagsChanged && keyCode == hotkey.keyCode {
                setHeld(Hotkey.isModifierDown(keyCode, flags: flags))
            } else if type == .keyDown && isHeld && !hotkey.isCapsLock {
                // Another key pressed together with the hotkey (like Fn+F5 or
                // Fn+←) is a shortcut, not a hold: release straight away.
                setHeld(false)
            }

        case .key:
            guard keyCode == hotkey.keyCode else { return }
            if type == .keyDown {
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
                if flags & Hotkey.comboModifierMask == hotkey.modifiers {
                    setHeld(true)
                }
            } else if type == .keyUp {
                setHeld(false)
            }
        }
    }

    private func setHeld(_ held: Bool) {
        guard held != isHeld else { return }
        isHeld = held
        if held { startStuckKeyCheck() } else { stopStuckKeyCheck() }
        onHeldChange?(held)
    }

    private func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        log.notice("Hotkey monitor \(active ? "active (Input Monitoring allowed)" : "inactive (no Input Monitoring permission)", privacy: .public)")
        onActiveChange?(active)
    }

    /// If the release event is ever missed, the mic could stay in the wrong
    /// state. While held, check once a second that the key really is still
    /// down. Both the key state and the modifier flags must say "up" before
    /// Muty releases, so a quirk in one of them can't cut you off mid-sentence.
    private func startStuckKeyCheck() {
        stopStuckKeyCheck()
        guard !hotkey.isCapsLock else { return }
        stuckKeyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isHeld else { return }
                let keyDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(self.hotkey.keyCode))
                var flagsSayDown = false
                if self.hotkey.kind == .modifierOnly {
                    let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
                    flagsSayDown = Hotkey.isModifierDown(self.hotkey.keyCode, flags: flags)
                }
                if !keyDown && !flagsSayDown { self.setHeld(false) }
            }
        }
    }

    private func stopStuckKeyCheck() {
        stuckKeyTimer?.invalidate()
        stuckKeyTimer = nil
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
    }
    return Unmanaged.passUnretained(event)
}
