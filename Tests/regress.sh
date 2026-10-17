#!/bin/sh
# Full regression: every scenario in parallel, then the pass/fail checks.
#   Tests/regress.sh <firmware-dir> [out-root]     (default out-root .local/regress/<timestamp>)
# Needs .local/fonts-factory (scripts/prepare-fonts.sh) and .local/test-audio (scripts/make-test-audio.sh,
# scripts/make-kws-templates.sh). Exit status 0 only if every check passes.
set -u
cd "$(dirname "$0")/.."
root=$PWD
fw=${1:?firmware directory}
out=${2:-$root/.local/regress/$(date +%Y%m%d-%H%M%S)}
mkdir -p "$out"; out=$(cd "$out" && pwd)
ta=$root/.local/test-audio
export FONTS=${FONTS:-$root/.local/fonts-factory}
base=${PORT_BASE:-24000}
peer_base=${PEER_BASE:-24100}

run() {  # run <name> <seconds> <scenario> [env...]
    name=$1 secs=$2 scen=$3; shift 3
    (env "$@" SCENARIO="$root/Tests/scenarios/$scen" RENODE_BATCH_PORT=$((base + $(echo "$name" | cksum | cut -c1-3) % 90)) \
        sh scripts/emulate.sh "$fw" "$secs" "$out/$name" "${EXTRA:-}" > /dev/null 2>&1) &
    jobs_pids="${jobs_pids:-} $!"
}
phone() {  # phone <name> <seconds> <scenario>: with the virtual BLE phone
    name=$1; port=$((peer_base + $(echo "$name" | cksum | cut -c1-3) % 90))
    mkdir -p "$out/$name"
    python3 scripts/ble-peer.py --port "$port" --log "$out/$name/peer.log" > /dev/null 2>&1 &
    peer_pids="${peer_pids:-} $!"
    sed "s/PeerPort [0-9]*/PeerPort $port/" Tests/scenarios/ble-peer.resc > "$out/$name.peer.resc"
    sleep 1
    EXTRA="$out/$name.peer.resc" run "$@" BOND_ADDR=c0:c0:ff:ee:00:01 BOND_OS=android
}

if [ -z "${SKIP_RUN:-}" ]; then
run crown 20 crown.txt
run rotate 16 rotate.txt
run bt 15 bt-reconnect.txt
run record 16 record.txt MIC="$ta/wake-xiaolei.wav"
run speaker 16 speaker.txt
run wake 16 wake.txt VOICE_WAKE=1 MIC="$ta/wake-xiaolei.wav" MIC_LOOP=0
run wakeneg 16 wake-negative.txt VOICE_WAKE=1 MIC="$ta/confusables.wav" MIC_LOOP=0
phone weather 30 bt-weather.txt
phone subtitle 30 bt-subtitle.txt
phone notification 30 bt-notification.txt
phone assistant 30 bt-assistant.txt
for p in $jobs_pids; do wait "$p"; done
kill $peer_pids 2>/dev/null
fi

fail=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
n() { c=$(grep -ac "$2" "$out/$1/boot.log" 2>/dev/null); echo "${c:-0}"; }
shots() { ls "$out/$1" 2>/dev/null | grep -c '^shot-'; }
for r in crown rotate bt record speaker wake wakeneg weather subtitle notification assistant; do
    check "$r: no firmware assert" "[ \$(n $r 'dump_assert_info: Assert') -eq 0 ]"
done
check "crown: 10 screenshots" "[ \$(shots crown) -eq 10 ]"
check "rotate: 8 screenshots" "[ \$(shots rotate) -eq 8 ]"
check "bt: page timeout from the controller" "[ \$(n bt 'CT:page end:link=1, status=4') -gt 0 ]"
corr=$(python3 scripts/check-audio.py "$out/record" "$ta/wake-xiaolei.wav" 2>&1 | sed -n 's/.*correlation with [^:]*: \([0-9.]*\).*/\1/p' | tail -1)
check "record: correlation ${corr:-none} >= 0.85" "python3 -c 'import sys; sys.exit(0 if float(\"${corr:-0}\") >= 0.85 else 1)'"
check "speaker: tone captured" "python3 scripts/check-audio.py '$out/speaker' 2>&1 | grep -q 'peak 32768'"
check "wake: 小雷小雷 confirmed" "[ \$(n wake 'wake word confirmed') -gt 0 ]"
check "wake-negative: no wake" "[ \$(n wakeneg 'wake word confirmed') -eq 0 ]"
for r in weather subtitle notification assistant; do
    check "$r: rnlink auth" "[ \$(n $r 'auth success') -gt 0 ]"
done
echo "results in $out"
exit $fail
