#!/bin/sh
# Compile every peripheral model in platform/peripherals.list through Renode and print compiler errors.
# (Renode only reports these on its monitor, so the script talks to it over a local port.)
set -eu
cd "$(dirname "$0")/.."
renode=${RENODE:-$PWD/.local/renode/Renode.app/Contents/MacOS/renode}
port=${PORT:-23499}
tmp=$(mktemp -d)
for name in $(cat platform/peripherals.list); do echo "include @$PWD/platform/peripherals/$name.cs"; done > "$tmp/check.resc"
"$renode" --disable-gui --plain -P "$port" < /dev/null > "$tmp/renode.log" 2>&1 &
pid=$!
sleep 8
{ echo "include @$tmp/check.resc"; sleep 60; echo quit; } | nc 127.0.0.1 "$port" | strings | grep -E "error|Could not compile" || echo "all models compiled"
kill $pid 2>/dev/null || true
rm -rf "$tmp"
