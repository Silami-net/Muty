# Muty

A macOS menu bar utility that turns a key into a **talk button** or a **cough button** for calls.

- **Left-click** the menu bar icon: turn Muty on or off (off = faded icon).
- **⌥-click** the icon: switch between Cough and Talk mode.
- **Right-click** the icon: Settings…, current hotkey and mode, Quit Muty.
- **Talk mode:** mic muted, hold the hotkey to speak.
- **Cough mode:** mic live, hold the hotkey to mute (default).
- **Hotkey:** Fn / 🌐 by default; presets Right ⌥, Right ⌘, Right ⇧; anything else via Custom….
- **Microphone:** all inputs, the current default input, or one specific device.
- **Start at login.**

## Build

Needs only the Xcode Command Line Tools (macOS 13 or later to run).

```bash
./build.sh
```

The app is written to `build/Muty.app` (universal: Apple Silicon + Intel, ad-hoc signed).

## Install

```bash
cp -R build/Muty.app /Applications/
open /Applications/Muty.app
```

On first launch, allow Muty under **System Settings → Privacy & Security → Input Monitoring**.
Until then Muty leaves the mic alone.

`build.sh` signs with a local "Muty Local Signing" certificate from your login keychain
when it exists, so macOS keeps the permission across rebuilds. Without it the build is
ad-hoc signed and the permission must be granted again after each rebuild.

## How muting works

Muty sets the device's input mute switch through CoreAudio, or its input volume to 0 if
the device has no mute switch. The original values are saved first and put back when you
release the key, turn Muty off, or quit. If Muty is force-quit while muted, the next launch
restores the mic. Devices without either control (for example an iPhone's Continuity mic)
are marked "can't be muted" in Settings.

## Layout

```
Sources/App        entry point, app delegate (sleep / lock handling)
Sources/MenuBar    status item: icon states, left/right click, menu
Sources/Hotkey     Hotkey model, global key monitor (CGEventTap), recorder
Sources/Audio      device list + change listeners, mute/restore
Sources/Core       settings, MicController state machine
Sources/Settings   SwiftUI settings window
Sources/Support    login item, System Settings links, relaunch
Tools/MakeIcon     draws the app icon (.icns)
```
