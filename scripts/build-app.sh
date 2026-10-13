#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
bin_dir=$(swift build -c release --show-bin-path)
app='build/RayNeo io on Mac.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/RayNeoSimulator" "$app/Contents/MacOS/RayNeoSimulator"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>RayNeo io on Mac</string>
<key>CFBundleDisplayName</key><string>RayNeo io on Mac</string>
<key>CFBundleExecutable</key><string>RayNeoSimulator</string>
<key>CFBundleIdentifier</key><string>cool.spare.rayneo-io-simulator</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
printf '%s\n' "Built: $PWD/$app"
