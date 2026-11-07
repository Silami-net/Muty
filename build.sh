#!/bin/zsh
# Builds Muty.app (universal: Apple Silicon + Intel) into ./build.
# Needs only the Xcode Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
BUILD="$ROOT/build"
APP="$BUILD/Muty.app"
SDK="$(xcrun --show-sdk-path)"
MIN_OS="13.0"

export TMPDIR="${TMPDIR:-$BUILD/tmp}"
export CLANG_MODULE_CACHE_PATH="$BUILD/ModuleCache"
mkdir -p "$BUILD" "$CLANG_MODULE_CACHE_PATH"

SOURCES=("${(@f)$(find Sources -name '*.swift' | sort)}")

echo "→ Compiling"
for ARCH in arm64 x86_64; do
  xcrun swiftc \
    -O -swift-version 5 \
    -sdk "$SDK" \
    -target "$ARCH-apple-macos$MIN_OS" \
    -module-name Muty \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    "${SOURCES[@]}" \
    -o "$BUILD/Muty-$ARCH"
done

echo "→ Making icon"
if [[ ! -f "$BUILD/AppIcon.icns" || Tools/MakeIcon.swift -nt "$BUILD/AppIcon.icns" ]]; then
  xcrun swiftc -O -sdk "$SDK" -module-cache-path "$CLANG_MODULE_CACHE_PATH" Tools/MakeIcon.swift -o "$BUILD/MakeIcon"
  "$BUILD/MakeIcon" "$BUILD/AppIcon.icns"
fi

echo "→ Assembling Muty.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$BUILD/Muty-arm64" "$BUILD/Muty-x86_64" -output "$APP/Contents/MacOS/Muty"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sign with the local "Muty Local Signing" certificate when it exists. A stable
# certificate means macOS keeps the Input Monitoring permission across rebuilds.
# Without it, fall back to ad-hoc signing (permission must be re-granted each build).
IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk '/"Muty Local Signing"/ {print $2; exit}')"
if [[ -n "$IDENTITY" ]]; then
  echo "→ Signing with Muty Local Signing"
  codesign --force --deep --sign "$IDENTITY" --identifier com.ambassadors.Muty "$APP"
else
  echo "→ Signing (ad-hoc)"
  codesign --force --deep --sign - --identifier com.ambassadors.Muty "$APP"
fi
codesign --verify --verbose "$APP"

echo "✓ Built $APP"
