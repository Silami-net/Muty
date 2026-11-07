import AppKit
import CoreGraphics

/// The key the user holds to talk (or to cough).
struct Hotkey: Codable, Equatable {
    enum Kind: String, Codable {
        /// A single modifier key on its own, such as Fn or Right ⌥.
        case modifierOnly
        /// A regular key, optionally with modifiers, such as F13 or ⌃⌥Space.
        case key
    }

    var kind: Kind
    var keyCode: UInt16
    /// For `.key`: the ⌘⌥⌃⇧ flags that must be held (CGEventFlags raw values).
    var modifiers: UInt64 = 0
    var displayName: String

    // MARK: Presets

    static let fn = Hotkey(kind: .modifierOnly, keyCode: 63, displayName: "Fn / 🌐")
    static let rightOption = Hotkey(kind: .modifierOnly, keyCode: 61, displayName: "Right ⌥ Option")
    static let rightCommand = Hotkey(kind: .modifierOnly, keyCode: 54, displayName: "Right ⌘ Command")
    static let rightShift = Hotkey(kind: .modifierOnly, keyCode: 60, displayName: "Right ⇧ Shift")
    static let presets: [Hotkey] = [.fn, .rightOption, .rightCommand, .rightShift]

    var isPreset: Bool { Hotkey.presets.contains(self) }
    var isFn: Bool { kind == .modifierOnly && keyCode == 63 }
    var isCapsLock: Bool { kind == .modifierOnly && keyCode == 57 }

    // MARK: Modifier keys

    static let commandMask = CGEventFlags.maskCommand.rawValue
    static let optionMask = CGEventFlags.maskAlternate.rawValue
    static let controlMask = CGEventFlags.maskControl.rawValue
    static let shiftMask = CGEventFlags.maskShift.rawValue
    static let comboModifierMask = commandMask | optionMask | controlMask | shiftMask

    private struct ModifierInfo {
        let name: String
        /// Device-specific bit (tells left from right).
        let deviceBit: UInt64
        /// Both device bits for this modifier family (left + right).
        let familyBits: UInt64
        /// Generic flag for the family, used when a keyboard doesn't report device bits.
        let genericFlag: UInt64
    }

    private static let modifierInfo: [UInt16: ModifierInfo] = [
        63: ModifierInfo(name: "Fn / 🌐", deviceBit: CGEventFlags.maskSecondaryFn.rawValue, familyBits: 0, genericFlag: CGEventFlags.maskSecondaryFn.rawValue),
        57: ModifierInfo(name: "⇪ Caps Lock", deviceBit: CGEventFlags.maskAlphaShift.rawValue, familyBits: 0, genericFlag: CGEventFlags.maskAlphaShift.rawValue),
        55: ModifierInfo(name: "Left ⌘ Command", deviceBit: 0x08, familyBits: 0x18, genericFlag: commandMask),
        54: ModifierInfo(name: "Right ⌘ Command", deviceBit: 0x10, familyBits: 0x18, genericFlag: commandMask),
        56: ModifierInfo(name: "Left ⇧ Shift", deviceBit: 0x02, familyBits: 0x06, genericFlag: shiftMask),
        60: ModifierInfo(name: "Right ⇧ Shift", deviceBit: 0x04, familyBits: 0x06, genericFlag: shiftMask),
        58: ModifierInfo(name: "Left ⌥ Option", deviceBit: 0x20, familyBits: 0x60, genericFlag: optionMask),
        61: ModifierInfo(name: "Right ⌥ Option", deviceBit: 0x40, familyBits: 0x60, genericFlag: optionMask),
        59: ModifierInfo(name: "Left ⌃ Control", deviceBit: 0x01, familyBits: 0x2001, genericFlag: controlMask),
        62: ModifierInfo(name: "Right ⌃ Control", deviceBit: 0x2000, familyBits: 0x2001, genericFlag: controlMask),
    ]

    static func isModifierKey(_ keyCode: UInt16) -> Bool { modifierInfo[keyCode] != nil }
    static func modifierName(_ keyCode: UInt16) -> String? { modifierInfo[keyCode]?.name }

    /// Whether the given modifier key is down according to a set of event flags.
    static func isModifierDown(_ keyCode: UInt16, flags: UInt64) -> Bool {
        guard let info = modifierInfo[keyCode] else { return false }
        if info.familyBits == 0 { return flags & info.deviceBit != 0 }
        if flags & info.familyBits == 0 {
            // Some keyboards don't report left/right bits; fall back to the generic flag.
            return flags & info.genericFlag != 0
        }
        return flags & info.deviceBit != 0
    }

    // MARK: Names for regular keys

    private static let specialKeyNames: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        49: "Space", 36: "↩ Return", 76: "⌤ Enter", 48: "⇥ Tab", 51: "⌫ Delete", 117: "⌦ Forward Delete",
        53: "⎋ Esc", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖ Home", 119: "↘ End", 116: "⇞ Page Up", 121: "⇟ Page Down", 114: "Help",
    ]

    /// Keys that don't type a character, so holding them is harmless.
    static func isNonTypingKey(_ keyCode: UInt16) -> Bool {
        guard let name = specialKeyNames[keyCode] else { return false }
        return name.hasPrefix("F") || ["←", "→", "↓", "↑", "↖ Home", "↘ End", "⇞ Page Up", "⇟ Page Down", "Help"].contains(name)
    }

    static func modifierSymbols(_ modifiers: UInt64) -> String {
        var s = ""
        if modifiers & controlMask != 0 { s += "⌃" }
        if modifiers & optionMask != 0 { s += "⌥" }
        if modifiers & shiftMask != 0 { s += "⇧" }
        if modifiers & commandMask != 0 { s += "⌘" }
        return s
    }

    static func keyName(keyCode: UInt16, characters: String?) -> String {
        if let special = specialKeyNames[keyCode] { return special }
        if let c = characters?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { return c.uppercased() }
        return "Key \(keyCode)"
    }

    // MARK: Warnings

    private static let systemCombos: [(UInt16, UInt64, String)] = [
        (49, commandMask, "Spotlight"),
        (49, controlMask, "switching input sources"),
        (49, controlMask | optionMask, "switching input sources"),
        (48, commandMask, "the app switcher"),
        (12, commandMask, "Quit"),
        (13, commandMask, "closing windows"),
    ]

    /// A short warning to show under the hotkey picker, if any.
    var warning: String? {
        if isCapsLock {
            return "macOS doesn't report when Caps Lock is released, so it works as an on/off switch instead of a hold. Each press toggles, and it also switches capital letters."
        }
        guard kind == .key else { return nil }
        if let match = Hotkey.systemCombos.first(where: { $0.0 == keyCode && $0.1 == modifiers }) {
            return "macOS also uses this combination for \(match.2). Both will happen when you press it."
        }
        if modifiers == 0 && !Hotkey.isNonTypingKey(keyCode) {
            return "This key types or does something in the app you're using. Holding it will still do that while it controls your mic."
        }
        return nil
    }
}
