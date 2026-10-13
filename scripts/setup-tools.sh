#!/bin/sh
# One-time: Python venv with littlefs-python (used by make-nand-image.py).
set -eu
cd "$(dirname "$0")/.."
python3 -m venv .local/venv
.local/venv/bin/pip install -q littlefs-python
echo "ok: .local/venv"
