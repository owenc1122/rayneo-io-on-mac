#!/usr/bin/env python3
"""Count the pixel rows that differ between two LCDC frames (binary PGM from `lcdc SaveFrame`).

    scripts/check-frames.py <a.pgm> <b.pgm> [min-rows]

Prints the count; exit status 0 if at least min-rows (default 1) rows differ. A static screen
differs only in its clock/status row (~14 rows); scrolling or highlighted text moves many more.
"""
import sys


def read_pgm(path):
    data = open(path, 'rb').read()
    magic, dims, maxval, pixels = data.split(b'\n', 3)
    w, h = map(int, dims.split())
    return w, h, pixels[:w * h]


w, h, a = read_pgm(sys.argv[1])
w2, h2, b = read_pgm(sys.argv[2])
if (w, h) != (w2, h2):
    sys.exit('frame sizes differ')
rows = sum(a[y * w:(y + 1) * w] != b[y * w:(y + 1) * w] for y in range(h))
print(rows)
sys.exit(0 if rows >= (int(sys.argv[3]) if len(sys.argv) > 3 else 1) else 1)
