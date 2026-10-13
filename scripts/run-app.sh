#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
exec './build/RayNeo io on Mac.app/Contents/MacOS/RayNeoSimulator'
