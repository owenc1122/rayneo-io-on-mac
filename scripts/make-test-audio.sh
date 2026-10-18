#!/bin/sh
# Test utterances for the audio scenarios (macOS voices, 16 kHz mono WAV) in .local/test-audio:
#   wake-xiaolei.wav  2 s silence, 「小雷小雷，今天天气怎么样」, 6 s silence
#   confusables.wav   「小李小李」「今天天气怎么样」「晓蕾在哪里」「小米小米」 with pauses (must not wake)
#   wake-xiaolei-noise.wav  wake-xiaolei.wav in pink noise + 100 Hz hum at 5 dB SNR (must wake; noise tests)
#   wake-reed-noise.wav     male voice (Reed, faster) 「小雷小雷，打开导航」 at 10 dB SNR (must wake)
#   wake-meijia.wav         Meijia (Taiwan) 「小雷小雷，帮我拍张照片」 (must wake)
#   confusables2.wav        「小雷」 once, 「小美小美」, 「下雷雨了」, 「笑累了笑累了」 (must not wake)
#   noise-only.wav          10 s of loud pink noise + hum (must not wake)
set -eu
cd "$(dirname "$0")/.."
out=.local/test-audio; mkdir -p "$out"; tmp=$(mktemp -d)
voice='Flo (中文（台湾）)'
say_wav() { say -v "${3:-$voice}" ${4:+-r "$4"} -o "$tmp/a.aiff" "$1"; afconvert -f WAVE -d LEI16@16000 -c 1 "$tmp/a.aiff" "$tmp/$2.wav"; }
say_wav '小雷小雷，今天天气怎么样' w; say_wav '小李小李' n1; say_wav '今天天气怎么样' n2; say_wav '晓蕾在哪里' n3; say_wav '小米小米' n4
say_wav '小雷小雷，打开导航' r 'Reed (中文（中国大陆）)' 200; say_wav '小雷小雷，帮我拍张照片' m 'Meijia (中文（台湾）)' 170
say_wav '小雷' c1 'Reed (中文（中国大陆）)'; say_wav '小美小美' c2 'Meijia (中文（台湾）)'; say_wav '下雷雨了' c3; say_wav '笑累了笑累了' c4 'Eddy (中文（中国大陆）)'
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
write('wake-meijia.wav', [z(2), pcm('m'), z(6)])
write('confusables2.wav', [z(2), pcm('c1'), z(2), pcm('c2'), z(2), pcm('c3'), z(2), pcm('c4'), z(4)])
import array, math, random
def samples(b): a = array.array('h'); a.frombytes(b); return a
def noise(n, seed):
    # pink noise (Paul Kellet's filter) plus a 100 Hz hum, unit RMS
    rnd = random.Random(seed); b0 = b1 = b2 = 0.0; out = []
    for i in range(n):
        w = rnd.gauss(0, 1); b0 = 0.99765 * b0 + w * 0.0990460; b1 = 0.96300 * b1 + w * 0.2965164; b2 = 0.57000 * b2 + w * 1.0526913
        out.append(b0 + b1 + b2 + w * 0.1848 + 0.3 * math.sin(2 * math.pi * 100 * i / 16000))
    r = math.sqrt(sum(v * v for v in out) / n); return [v / r for v in out]
def mix(name, parts, snr, seed):
    x = samples(b''.join(parts)); speech = [v for v in x if abs(v) > 100]
    p = sum(v * v for v in speech) / len(speech); g = math.sqrt(p / 10 ** (snr / 10))
    y = array.array('h', (max(-32768, min(32767, int(v + g * u))) for v, u in zip(x, noise(len(x), seed))))
    write(name, [y.tobytes()])
mix('wake-xiaolei-noise.wav', [z(2), pcm('w'), z(6)], 5, 1)
mix('wake-reed-noise.wav', [z(2), pcm('r'), z(6)], 10, 2)
write('noise-only.wav', [array.array('h', (int(3000 * v) for v in noise(160000, 3))).tobytes()])
PY
rm -rf "$tmp"; ls "$out"
