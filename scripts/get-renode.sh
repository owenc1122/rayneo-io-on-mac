#!/bin/sh
# Downloads the Renode build this project is tested with into .local/renode/Renode.app (macOS arm64).
# 1.17.0+20261016 is required: the 1.17.0 release (20260906) stalls in serial execution on WFI.
set -eu
cd "$(dirname "$0")/.."
build=${RENODE_BUILD:-1.17.0+20261016gitd0c70ee3f}
url="https://builds.renode.io/renode-$(printf '%s' "$build" | sed 's/+/%2B/').osx-arm64-portable.dmg"
mkdir -p .local/downloads
dmg=.local/downloads/renode-$build.dmg
[ -s "$dmg" ] || curl -fL -o "$dmg" "$url"
mnt=$(mktemp -d)
hdiutil attach -nobrowse -quiet -mountpoint "$mnt" "$dmg"
rm -rf .local/renode && mkdir -p .local/renode
cp -R "$mnt"/Renode.app .local/renode/
hdiutil detach -quiet "$mnt"
.local/renode/Renode.app/Contents/MacOS/renode --version | tail -2
