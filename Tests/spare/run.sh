#!/bin/sh
# Spare 固件验证台：一次运行 = 虚拟手机（BLE，安卓身份）+ Renode 全系统仿真 + 场景截图。
#   Tests/spare/run.sh <固件目录(解开的整包)> <输出目录> <模拟秒数> <场景.txt|-> [虚拟手机环境变量 VAR=val ...]
# 环境变量（给 emulate.sh）：VOICE_WAKE、MIC、HOOKS_EXTRA_RESC（额外 .resc，比如内存探针）等照常透传。
# 输出：<输出目录>/boot.log（[AP]/[BTH]/[C1] 固件日志）、peer.log（虚拟手机，BENCH t= 行）、截图 *.pgm。
set -u
cd "$(dirname "$0")/../.."
root=$PWD
fw=$(cd "${1:?固件目录}" && pwd); out=${2:?输出目录}; secs=${3:?秒数}; scen=${4:--}; shift 4
mkdir -p "$out"; out=$(cd "$out" && pwd)
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
mon=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
env "$@" python3 scripts/ble-peer.py --port "$port" --log "$out/peer.log" > "$out/peer.stdout" 2>&1 &
peer=$!
{ sed "s/PeerPort [0-9]*/PeerPort $port/" Tests/scenarios/ble-peer.resc; [ -n "${HOOKS_EXTRA_RESC:-}" ] && cat "$HOOKS_EXTRA_RESC"; } > "$out/peer.resc"
sleep 1
[ "$scen" = - ] && scen_env= || scen_env="SCENARIO=$(cd "$(dirname "$scen")" && pwd)/$(basename "$scen")"
env $scen_env FONTS="${FONTS:-$root/.local/fonts-factory}" BOND_ADDR=c0:c0:ff:ee:00:01 BOND_OS=android \
    RENODE_BATCH_PORT=$mon sh scripts/emulate.sh "$fw" "$secs" "$out" "$out/peer.resc" > "$out/emulate.stdout" 2>&1
kill $peer 2>/dev/null
# 截图转 PNG（便于看）
python3 - "$out" <<'PY'
import sys, glob, os
try:
    from PIL import Image
except ImportError:
    sys.exit(0)
for p in sorted(glob.glob(os.path.join(sys.argv[1], '*.pgm'))):
    if os.path.basename(p) == 'frame.pgm': continue
    try: Image.open(p).save(p[:-4] + ".png"); os.remove(p)
    except Exception as e: print('png', p, e)
PY
echo "done: $out"
