#!/usr/bin/env python3
"""Noise-suppression check for a record run: how close the audio the AP recorded (arec2.wav, written by
scripts/check-audio.py) is to the clean speech that was mixed into the noisy microphone input.

  scripts/check-ns.py <run-dir> <clean.wav> [min-correlation]

Aligns the clean file to the recording sample-exactly, then prints the correlation, the SNR of the
recording against the clean speech, and the residual level in speech pauses and during speech. Exit status 1
when the correlation is below min-correlation (default 0, report only). Needs numpy.
"""
import sys, wave
import numpy as np

def read(path):
    w = wave.open(path)
    return np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(float)

def segment(x, y, lag):
    a = x[max(0, lag):max(0, lag) + len(y)] if lag >= 0 else x[:len(y) + lag]
    b = y[:len(a)] if lag >= 0 else y[-lag:-lag + len(a)]
    return a, b

def corr(a, b): return np.dot(a, b) / np.sqrt(np.dot(a, a) * np.dot(b, b) + 1e-9)

run, clean = sys.argv[1], sys.argv[2]
minimum = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
x, y = read(clean), read(f'{run}/arec2.wav')
coarse = max((corr(*segment(x, y, lag)), lag) for lag in range(-len(y) + 16000, len(x) - 16000, 20))
c, lag = max((corr(*segment(x, y, l)), l) for l in range(coarse[1] - 25, coarse[1] + 26))
a, b = segment(x, y, lag)
g = np.dot(a, b) / np.dot(a, a); r = b - g * a; speech = np.abs(a) > 300
db = lambda v: 10 * np.log10(v + 1e-9)
print(f'recording vs clean speech: correlation {c:.3f}, SNR {db(np.sum((g * a) ** 2) / np.sum(r ** 2)):.1f} dB, '
      f'residual {db(np.mean(r[~speech] ** 2)):.1f} dB in pauses / {db(np.mean(r[speech] ** 2)):.1f} dB during speech')
sys.exit(0 if c >= minimum else 1)
