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
# STATE=<dir>: persistent glasses (NOR flash0 + NAND pages saved by the app on quit, see
# FirmwareModel.saveState). A saved flash0 replaces the freshly installed one.
if [ -n "${STATE:-}" ] && [ -f "$STATE/flash0.bin" ]; then
    cp "$STATE/flash0.bin" "$out/flash/flash0.bin"
    echo "restored flash0 from $STATE" >> "$out/flash-layout.log"
else
    # Bonded phone record (BOND=0 keeps the factory-fresh BondView start).
    # BOND_ADDR=<aa:bb:..> and BOND_OS=android|ios override the seeded peer so it matches a virtual phone.
    [ "${BOND:-iPhone}" = 0 ] || python3 scripts/make-user-data.py "$out/flash/flash0.bin" \
        --name "${BOND:-iPhone}" ${BOND_ADDR:+--addr "$BOND_ADDR"} ${BOND_OS:+$([ "$BOND_OS" = android ] && echo --android)} \
        >> "$out/flash-layout.log"
fi
# Phone-app settings: VOICE_WAKE=1 turns on 「小雷小雷」 voice wake (factory default off), WAKE_WORD=1|2.
[ -z "${VOICE_WAKE:-}" ] || python3 scripts/set-preference.py "$out/flash/flash0.bin" voice_wakeup="$VOICE_WAKE" ${WAKE_WORD:+wakeup_word=$WAKE_WORD} >> "$out/flash-layout.log"
# NAND resource partitions (littlefs). Optional fonts: FONTS=<dir with .ttf> (factory fonts are not in the OTA set).
venv=${RAYNEO_VENV:-$root/.local/venv}
if [ -x "$venv/bin/python" ]; then
    "$venv/bin/python" scripts/make-nand-image.py "$fwdir" "$out/nand" ${FONTS:+--fonts "$FONTS" --substitute} > "$out/nand-layout.log"
else
    echo 'note: no littlefs venv (scripts/setup-tools.sh); NAND resources not prepared' >&2
fi
python3 scripts/make-resc.py "$root" "$out" "$duration" "$extra" > "$out/boot.resc"
resc=$(printf '%s' "$out/boot.resc" | sed 's/ /\\ /g')   # Renode @paths escape spaces
if [ -n "${RENODE_MONITOR_PORT:-}" ]; then
    # Interactive (Mac app): monitor on a local TCP port for input injection.
    exec "$renode" --disable-gui --plain -P "$RENODE_MONITOR_PORT" -e "include @$resc" > "$out/boot.log" 2>&1 < /dev/null
fi
# No --console: Renode 1.17 crashes (SemaphoreFullException in ConsoleIOSource) a few
# minutes after its console stdin hits EOF. The monitor listens on a local port instead.
"$renode" --disable-gui --plain -P "${RENODE_BATCH_PORT:-23457}" -e "include @$resc" > "$out/boot.log" 2>&1 < /dev/null || true
grep -E '^\[AP|^\[BTH|^\[C1|M55C1 released|BTH released|BTC released|Scanout' "$out/boot.log" | tail -40
echo "log: $out/boot.log"
