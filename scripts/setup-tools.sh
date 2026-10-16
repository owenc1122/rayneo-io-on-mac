#!/bin/sh
# One-time: Python venv with littlefs-python (used by make-nand-image.py).
# Usage: setup-tools.sh [venv-dir]   (default .local/venv)
set -eu
cd "$(dirname "$0")/.."
venv=${1:-.local/venv}
python3 -m venv "$venv"
"$venv/bin/pip" install -q littlefs-python
echo "ok: $venv"
