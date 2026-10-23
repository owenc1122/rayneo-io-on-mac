#!/bin/sh
# Builds "RayNeo io on Mac.app". The firmware is never bundled: the app asks for the
# user's own StrixOS OTA folder on first launch.
#   BUNDLE_RENODE=1 sh scripts/build-app.sh   also copies Renode (MIT) into the app: .local/renode-build/Renode.app
#   from scripts/build-renode.sh if present, else the downloaded .local/renode/Renode.app.
set -eu
cd "$(dirname "$0")/.."
swift build -c release
bin_dir=$(swift build -c release --show-bin-path)
app='build/RayNeo io on Mac.app'
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/RayNeoSimulator" "$app/Contents/MacOS/RayNeoSimulator"
# Emulator description and helper scripts (no firmware-derived data).
mkdir -p "$app/Contents/Resources/platform" "$app/Contents/Resources/scripts"
cp -R platform/. "$app/Contents/Resources/platform/"
cp scripts/emulate.sh scripts/make-resc.py scripts/make-flash-image.py scripts/make-nand-image.py scripts/make-user-data.py \
   scripts/set-preference.py scripts/make-kws-templates.sh scripts/prepare-fonts.sh scripts/setup-tools.sh \
   scripts/ble-peer.py scripts/rnlink.py scripts/bredr.py scripts/ssp.py "$app/Contents/Resources/scripts/"
# Real-phone Bluetooth bridge (experimental): the Python bridge plus its CoreBluetooth helper app.
sh tools/ble-bridge/build.sh > /dev/null
mkdir -p "$app/Contents/Resources/tools/ble-bridge"
cp tools/ble-bridge/ble-bridge.py "$app/Contents/Resources/tools/ble-bridge/"
cp -R "tools/ble-bridge/.build/RayNeo Phone Bridge.app" "$app/Contents/Resources/tools/ble-bridge/"
# The source build from scripts/build-renode.sh (faster) wins over the downloaded one.
renode_app=.local/renode-build/Renode.app
[ -d "$renode_app" ] || renode_app=.local/renode/Renode.app
if [ "${BUNDLE_RENODE:-0}" = 1 ] && [ -d "$renode_app" ]; then
    mkdir -p "$app/Contents/Resources/renode"
    cp -R "$renode_app" "$app/Contents/Resources/renode/"
fi
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>RayNeo io on Mac</string>
<key>CFBundleDisplayName</key><string>RayNeo io on Mac</string>
<key>CFBundleExecutable</key><string>RayNeoSimulator</string>
<key>CFBundleIdentifier</key><string>cool.spare.rayneo-io-simulator</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSpeechRecognitionUsageDescription</key><string>在本机识别唤醒词「小雷小雷」/"OK RayNeo"，代替眼镜音频 DSP 的唤醒词算法。只用设备端识别，声音不上传。</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>「真机经 Mac 蓝牙连接眼镜」时，让手机通过 Mac 的蓝牙连接模拟器里的眼镜。</string>
<key>NSMicrophoneUsageDescription</key><string>把 Mac 麦克风的声音交给模拟眼镜的原固件（录音、语音助手）。声音只在本机处理。</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app"
printf '%s\n' "Built: $PWD/$app"
