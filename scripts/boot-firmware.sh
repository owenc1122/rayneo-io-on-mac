#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
root=$PWD
firmware=${1:-$root/.local/firmware.bin}
duration=${2:-15}
case "$duration" in ''|*[!0-9.]*) echo 'Invalid simulated duration' >&2; exit 1;; esac
[ -f "$firmware" ] || { echo 'Firmware file not found; pass its path as the first argument' >&2; exit 1; }
staging=$(mktemp -d /tmp/rayneo-cli.XXXXXX)
trap 'rm -f "$staging"/*; rmdir "$staging"' EXIT
: > "$staging/boot.resc"
while IFS= read -r name; do
    ln -s "$root/platform/peripherals/$name.cs" "$staging/$name.cs"
    printf 'include @%s/%s.cs\n' "$staging" "$name" >> "$staging/boot.resc"
done < platform/peripherals.list
ln -s "$root/platform/best1700.repl" "$staging/board.repl"
ln -s "$firmware" "$staging/firmware.bin"
mkdir -p .local/runs/cli
ln -s "$root/.local/runs/cli" "$staging/output"
cat >> "$staging/boot.resc" <<RESC
mach create "RayNeo-AP"
machine LoadPlatformDescription @$staging/board.repl
sysbus LoadBinary @$staging/firmware.bin 0x10190000
lcdc FrameImagePath "$staging/output/frame.pgm"
logLevel 3 nvic
cpu PerformanceInMips 200
btc PerformanceInMips 100
cpu SP 0x202fffe0
cpu PC 0x10190010
emulation RunFor "$duration"
console_log \`cpu PC\`
console_log \`cpu SP\`
console_log \`cpu LR\`
console_log \`btc PC\`
quit
RESC
.local/renode/Renode.app/Contents/MacOS/renode --disable-gui --console --plain -e "include @$staging/boot.resc" > .local/runs/last-cli-boot.log 2>&1
cat .local/runs/last-cli-boot.log
