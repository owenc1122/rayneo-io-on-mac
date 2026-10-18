#!/bin/sh
# cl-run.sh <name> <secs> <scenario> [ENV=val...]  (classic run in the cbt worktree with the phone)
cd $(cd "$(dirname "$0")/.." && pwd)
name=$1 secs=$2 scen=$3; shift 3
export FONTS=/Users/owen/Documents/RayNeo-io-on-Mac/.local/fonts-factory
fw=/Users/owen/Documents/spare-glass/firmware/src/firmware-inspection/StrixOS-1.0.4.12
fp() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
out=$PWD/.local/runs/$name; rm -rf $out; mkdir -p $out
port=$(fp)
env "$@" python3 scripts/ble-peer.py --port $port --log $out/peer.log >/dev/null 2>&1 &
pp=$!
{ sed "s/PeerPort [0-9]*/PeerPort $port/" Tests/scenarios/ble-peer.resc; [ -n "${HOOKS:-}" ] && cat Tests/scenarios/$HOOKS; } > $out.peer.resc
sleep 1
env "$@" BOND_ADDR=c0:c0:ff:ee:00:01 BOND_OS=android SCENARIO=$PWD/Tests/scenarios/$scen RENODE_BATCH_PORT=$(fp) sh scripts/emulate.sh $fw $secs $out "$out.peer.resc" >/dev/null 2>&1
kill $pp 2>/dev/null
echo "done $out"
