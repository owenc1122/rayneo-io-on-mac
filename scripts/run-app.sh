#!/bin/sh
# Opens the built app the same way Finder does.
set -eu
cd "$(dirname "$0")/.."
open 'build/RayNeo io on Mac.app'
