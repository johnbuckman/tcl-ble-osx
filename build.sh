#!/bin/bash
# Build the CoreBluetooth helper for the macOS "ble" Tcl package.
#
# Produces a universal (arm64 + x86_64) binary at bin/ble_helper with the
# Bluetooth-usage Info.plist embedded so macOS can grant Bluetooth permission.
#
# Usage: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

SRC=ble_helper.swift
PLIST=Info.plist
OUT=bin/ble_helper
mkdir -p bin

MIN=11.0
COMMON=(-O -framework CoreBluetooth -swift-version 5
        -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST")

echo "building arm64 slice..."
swiftc "${COMMON[@]}" -target arm64-apple-macos${MIN}  "$SRC" -o bin/ble_helper.arm64

echo "building x86_64 slice..."
swiftc "${COMMON[@]}" -target x86_64-apple-macos${MIN} "$SRC" -o bin/ble_helper.x86_64

echo "lipo -> universal..."
lipo -create bin/ble_helper.arm64 bin/ble_helper.x86_64 -output "$OUT"
rm -f bin/ble_helper.arm64 bin/ble_helper.x86_64
chmod +x "$OUT"

# Developer ID sign (NOT ad-hoc): the helper travels in the de1app update
# manifest and gets copied to a fresh path on each user's machine.  An ad-hoc
# signature's TCC Bluetooth grant is keyed to the *path*, so the copied helper
# loses the grant ("broken pipe").  A Developer ID signature gives a stable,
# path-independent code identity, so the Bluetooth grant survives the copy.
#
# Deliberately NO hardened runtime (--options runtime): the host app
# (undroidwish, appended VFS) can't be notarized anyway, so it buys nothing --
# and under hardened runtime, the FIRST-time Bluetooth grant SIGABRT-crashes the
# helper ("...must contain NSBluetoothAlwaysUsageDescription...") instead of
# presenting the prompt, even though the key IS embedded.  Plain Developer ID
# lets TCC read the embedded usage description and prompt normally.
SIGN_ID="${BLE_SIGN_ID:-Developer ID Application: Vid Tadel (XLS3XF57J8)}"
codesign --force --timestamp \
    --sign "$SIGN_ID" \
    --identifier com.decentespresso.ble-helper "$OUT"

echo "done:"
file "$OUT"
lipo -info "$OUT"

# Best-effort: also build the native in-process Tcl extension (lib/libtclble.*)
# which the package prefers when in-process Bluetooth is available.  Skipped
# silently if Tcl dev headers aren't installed.
if [ -x native/build.sh ]; then
    echo ""
    ( cd native && ./build.sh ) || true
fi
