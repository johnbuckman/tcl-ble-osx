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

# Ad-hoc sign so the embedded Info.plist / entitlements are honoured by TCC.
codesign --force --sign - --identifier com.decentespresso.ble-helper "$OUT" 2>/dev/null || true

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
