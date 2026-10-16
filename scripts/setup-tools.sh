#!/bin/sh
# One-time: Python venv with littlefs-python (make-nand-image.py) and fonttools (prepare-fonts.sh).
# Usage: setup-tools.sh [venv-dir]   (default .local/venv)
set -eu
cd "$(dirname "$0")/.."
venv=${1:-.local/venv}
python3 -m venv "$venv"
"$venv/bin/pip" install -q littlefs-python fonttools
echo "ok: $venv"
