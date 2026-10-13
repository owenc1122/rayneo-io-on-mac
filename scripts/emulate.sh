#!/bin/sh
# Headless run of the original firmware.
#   scripts/emulate.sh <firmware-dir> [simulated-seconds] [output-dir] [extra.resc]
# <firmware-dir> is an extracted StrixOS OTA "files" set (OtaFileInfo.json,
# nuttx_ap.bin, nuttx_bth.bin, ...). Installed flash images are generated from
# it with scripts/make-flash-image.py; the firmware files themselves are never
# modified.
set -eu
cd "$(dirname "$0")/.."
root=$PWD
fwdir=${1:?firmware directory}
duration=${2:-15}
out=${3:-$root/.local/runs/cli-$(date +%Y%m%d-%H%M%S)}
extra=${4:-}
case "$duration" in ''|*[!0-9.]*) echo 'Invalid simulated duration' >&2; exit 1;; esac
[ -f "$fwdir/OtaFileInfo.json" ] || { echo "No OtaFileInfo.json in $fwdir" >&2; exit 1; }
renode=${RENODE:-$root/.local/renode/Renode.app/Contents/MacOS/renode}
mkdir -p "$out"
out=$(cd "$out" && pwd)
python3 scripts/make-flash-image.py "$fwdir" "$out/flash" > "$out/flash-layout.log"
# NAND resource partitions (littlefs). Optional fonts: FONTS=<dir with .ttf> (factory fonts are not in the OTA set).
if [ -x .local/venv/bin/python ]; then
    .local/venv/bin/python scripts/make-nand-image.py "$fwdir" "$out/nand" ${FONTS:+--fonts "$FONTS" --substitute} > "$out/nand-layout.log"
else
    echo 'note: run scripts/setup-tools.sh to build the NAND resource image' >&2
fi
python3 scripts/make-resc.py "$root" "$out" "$duration" "$extra" > "$out/boot.resc"
"$renode" --disable-gui --console --plain -e "include @$out/boot.resc" > "$out/boot.log" 2>&1 < /dev/null || true
grep -E '^\[AP|^\[BTH|^\[C1|M55C1 released|BTH released|BTC released|Scanout' "$out/boot.log" | tail -40
echo "log: $out/boot.log"
