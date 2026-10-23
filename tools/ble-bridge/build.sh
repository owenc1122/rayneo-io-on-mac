#!/bin/sh
# Builds "tools/ble-bridge/.build/RayNeo Phone Bridge.app" (CoreBluetooth helper, see ble-bridge.py).
# It must be an app bundle launched through LaunchServices (open -n -a … --args): macOS attributes Bluetooth
# access to the responsible process, so a bare tool started from a terminal/IDE that has no
# NSBluetoothAlwaysUsageDescription is killed. As its own app it asks for Bluetooth permission once.
set -eu
cd "$(dirname "$0")"
app=".build/RayNeo Phone Bridge.app"
rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
swiftc -O -o "$app/Contents/MacOS/BLEBridgeHelper" BLEBridgeHelper.swift
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>cool.spare.rayneo-io-phone-bridge</string>
<key>CFBundleName</key><string>RayNeo Phone Bridge</string>
<key>CFBundleExecutable</key><string>BLEBridgeHelper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSBackgroundOnly</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>让手机通过 Mac 的蓝牙连接模拟器里的眼镜。</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
echo "built: $PWD/$app"
