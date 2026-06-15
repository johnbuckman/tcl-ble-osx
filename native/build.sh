#!/bin/bash
# Build the native (in-process) CoreBluetooth Tcl extension lib/libtclble.dylib.
#
# This is the loadable-extension backend the `ble` package prefers (see ble.tcl);
# it works where the interpreter itself can hold Bluetooth (TCC) permission --
# i.e. iWish/iOS or a signed .app -- and the package falls back to bin/ble_helper
# everywhere else.  Building needs Tcl's dev headers + stubs library.
#
# Usage:  ./build.sh                 (auto-detects the Tcl framework)
#         TCLFW=/path ./build.sh     (point at a specific Tcl install)
set -uo pipefail
cd "$(dirname "$0")"

# Locate Tcl headers + stub lib.
TCLFW="${TCLFW:-}"
if [ -z "$TCLFW" ]; then
    for d in /Library/Frameworks/Tcl.framework/Versions/8.6 \
             /System/Library/Frameworks/Tcl.framework/Versions/8.6 \
             /usr/local/opt/tcl-tk /usr/local /opt/homebrew/opt/tcl-tk; do
        if [ -f "$d/Headers/tcl.h" ] || [ -f "$d/include/tcl.h" ]; then TCLFW="$d"; break; fi
    done
fi
if [ -z "$TCLFW" ]; then echo "Tcl dev headers not found; set TCLFW=... (skipping native extension)"; exit 0; fi

INC="$TCLFW/Headers"; [ -d "$INC" ] || INC="$TCLFW/include"
STUB="$(ls "$TCLFW"/libtclstub8.6.a "$TCLFW"/lib/libtclstub8.6.a 2>/dev/null | head -1)"
if [ -z "$STUB" ] || [ ! -f "$INC/tcl.h" ]; then
    echo "Tcl stub lib / tcl.h not found under $TCLFW (skipping native extension)"; exit 0
fi

# Match the stub lib's architecture(s).
ARCHS=""
for a in x86_64 arm64; do
    if lipo -info "$STUB" 2>/dev/null | grep -q "$a"; then ARCHS="$ARCHS -arch $a"; fi
done
[ -z "$ARCHS" ] && ARCHS="-arch $(uname -m)"

mkdir -p ../lib
echo "building libtclble.dylib ($ARCHS) against $TCLFW ..."
clang -dynamiclib -DUSE_TCL_STUBS -fobjc-arc $ARCHS \
    -I"$INC" -framework Foundation -framework CoreBluetooth \
    -o ../lib/libtclble.dylib tclble.m "$STUB" 2>&1 | grep -vE "no platform load command" || true

if [ -f ../lib/libtclble.dylib ]; then
    codesign --force --sign - ../lib/libtclble.dylib 2>/dev/null || true
    echo "done: $(lipo -info ../lib/libtclble.dylib 2>/dev/null)"
else
    echo "native extension build failed (the package will use bin/ble_helper)"
fi
