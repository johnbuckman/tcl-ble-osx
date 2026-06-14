#!/bin/bash
# Build BLETest.app -- a launchable macOS app that runs test_ble.tcl against the
# ble package.  Useful when the host interpreter (e.g. undroidwish) can't be
# code-signed: launching a real .app lets the Bluetooth permission prompt appear.
#
# With standard Aqua wish you usually don't need this -- the helper owns its own
# Bluetooth (TCC) identity, so `wish examples/scan.tcl` works directly.
#
# Usage:  WISH=/path/to/wish ./build_testapp.sh   then:  open /tmp/BLETest.app
set -euo pipefail
cd "$(dirname "$0")/.."

WISH="${WISH:-/usr/local/bin/wish8.6}"
APP="${APP:-/tmp/BLETest.app}"

[ -x bin/ble_helper ] || ./build.sh
[ -x "$WISH" ] || { echo "wish not found at $WISH (set WISH=...)"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ble/bin"

cat > "$APP/Contents/MacOS/BLETest" <<'EOF'
#!/bin/bash
D="$(cd "$(dirname "$0")/.." && pwd)"
exec "$D/MacOS/wish" "$D/Resources/test_ble.tcl"
EOF
chmod +x "$APP/Contents/MacOS/BLETest"

cp "$WISH"            "$APP/Contents/MacOS/wish"
cp test/test_ble.tcl  "$APP/Contents/Resources/test_ble.tcl"
cp ble.tcl pkgIndex.tcl "$APP/Contents/Resources/ble/"
cp bin/ble_helper       "$APP/Contents/Resources/ble/bin/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>BLE Test</string>
  <key>CFBundleIdentifier</key><string>org.tcl.bletest</string>
  <key>CFBundleExecutable</key><string>BLETest</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>This test uses Bluetooth to talk to nearby BLE devices.</string>
</dict></plist>
EOF

codesign --force --sign - --identifier org.tcl.ble-helper \
    "$APP/Contents/Resources/ble/bin/ble_helper" 2>/dev/null || true

echo "built $APP"
echo "launch:  open $APP   (results in /tmp/ble_test_result.txt)"
