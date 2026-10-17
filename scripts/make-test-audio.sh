#!/bin/sh
# Test utterances for the audio scenarios (macOS voices, 16 kHz mono WAV) in .local/test-audio:
#   wake-xiaolei.wav  2 s silence, 「小雷小雷，今天天气怎么样」, 6 s silence
#   confusables.wav   「小李小李」「今天天气怎么样」「晓蕾在哪里」「小米小米」 with pauses (must not wake)
set -eu
cd "$(dirname "$0")/.."
out=.local/test-audio; mkdir -p "$out"; tmp=$(mktemp -d)
voice='Flo (中文（台湾）)'
say_wav() { say -v "$voice" -o "$tmp/a.aiff" "$1"; afconvert -f WAVE -d LEI16@16000 -c 1 "$tmp/a.aiff" "$tmp/$2.wav"; }
say_wav '小雷小雷，今天天气怎么样' w; say_wav '小李小李' n1; say_wav '今天天气怎么样' n2; say_wav '晓蕾在哪里' n3; say_wav '小米小米' n4
python3 - "$tmp" "$out" <<'PY'
import sys, wave
tmp, out = sys.argv[1:]
def pcm(n):
    w = wave.open(f'{tmp}/{n}.wav'); return w.readframes(w.getnframes())
def write(name, parts):
    w = wave.open(f'{out}/{name}', 'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(b''.join(parts)); w.close()
z = lambda s: b'\0' * int(32000 * s)
write('wake-xiaolei.wav', [z(2), pcm('w'), z(6)])
write('confusables.wav', [z(2), pcm('n1'), z(2), pcm('n2'), z(2), pcm('n3'), z(2), pcm('n4'), z(4)])
PY
rm -rf "$tmp"; ls "$out"
