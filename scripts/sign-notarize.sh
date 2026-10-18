#!/bin/sh
# Signs "RayNeo io on Mac.app" with the hardened runtime and, given an Apple account, notarizes and staples it.
#   sh scripts/sign-notarize.sh [app]                         ad-hoc signature: runs on this Mac only
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<profile> sh scripts/sign-notarize.sh [app]
# app defaults to build/RayNeo io on Mac.app (scripts/build-app.sh). NOTARY_PROFILE is a notarytool keychain profile:
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <TEAMID> --password <app-specific password>
# Every Mach-O file is signed inside-out (bundled Renode first, the app last), all with the hardened runtime:
#   - the app: microphone, network client/server (local Renode monitor port);
#   - Renode's .NET host: JIT, unsigned executable memory, no library validation (it loads its emulator
#     libraries from temporary copies).
set -eu
cd "$(dirname "$0")/.."
app=${1:-build/RayNeo io on Mac.app}
[ -d "$app" ] || { echo "No app at $app (run scripts/build-app.sh)" >&2; exit 1; }
identity=${SIGN_IDENTITY:--}
if [ "$identity" = - ]; then
    echo "SIGN_IDENTITY not set: ad-hoc signature (runs on this Mac only; not notarized)"
    timestamp=--timestamp=none
else
    timestamp=--timestamp
fi

ent=$(mktemp -d)
trap 'rm -rf "$ent"' EXIT
cat > "$ent/app.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.device.audio-input</key><true/>
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.network.server</key><true/>
</dict></plist>
PLIST
cat > "$ent/renode.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
<key>com.apple.security.cs.disable-library-validation</key><true/>
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.network.server</key><true/>
</dict></plist>
PLIST

sign() {  # sign <file> [entitlements]
    if [ -n "${2:-}" ]; then
        codesign --force --sign "$identity" --options runtime $timestamp --entitlements "$2" "$1"
    else
        codesign --force --sign "$identity" --options runtime $timestamp "$1"
    fi
}

# Nested code, deepest paths first: libraries plain, executables with the Renode entitlements.
count=0
find "$app/Contents/Resources" -type f | awk '{ print gsub("/", "/") "\t" $0 }' | sort -rn | cut -f2- |
while IFS= read -r f; do
    kind=$(file -b "$f")
    case "$kind" in
        Mach-O*executable*) sign "$f" "$ent/renode.plist" ;;
        Mach-O*) sign "$f" ;;
        *) continue ;;
    esac
    count=$((count + 1))
    [ $((count % 25)) -ne 0 ] || echo "  $count nested binaries signed"
done
sign "$app" "$ent/app.plist"
codesign --verify --strict --deep --verbose=1 "$app"

if [ "$identity" = - ] || [ -z "${NOTARY_PROFILE:-}" ]; then
    [ "$identity" = - ] || echo "NOTARY_PROFILE not set: signed, not notarized"
    exit 0
fi
zip="$ent/$(basename "$app" .app).zip"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
