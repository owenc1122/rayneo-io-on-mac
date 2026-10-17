#!/usr/bin/env python3
"""Check the audio a run exchanged with the stock firmware through the HiFi4 stand-in.
  scripts/check-audio.py <run-dir> [mic.wav]
Decodes every tap file the stand-in wrote (<stream>.opus = u16 length + raw Opus packet per frame,
<stream>.pcm = s16le) to <stream>.wav with macOS afconvert, prints level statistics and, when the
microphone input is given, the best normalised correlation against it. speaker.raw (s16le, what the
AP played, decoded by the stand-in to 48 kHz stereo) is wrapped as speaker.wav."""
import re, struct, subprocess, sys, wave
from pathlib import Path

def varint(n):
    out = [n & 0x7f]; n >>= 7
    while n: out.append(0x80 | (n & 0x7f)); n >>= 7
    return bytes(reversed(out))

def opus_to_caf(packets, rate, frame_samples, path):
    desc = struct.pack('>dIIIIII', float(rate), 0x6f707573, 0, 0, frame_samples, 1, 0)
    kuki = struct.pack('>IIIiIII', 0x800, rate, frame_samples, -1000, 1, 0, 0)
    table = b''.join(varint(len(p)) for p in packets)
    pakt = struct.pack('>qqii', len(packets), len(packets) * frame_samples, 0, 0) + table
    data = struct.pack('>I', 1) + b''.join(packets)
    chunks = [(b'desc', desc), (b'kuki', kuki), (b'pakt', pakt), (b'data', data)]
    with open(path, 'wb') as f:
        f.write(b'caff' + struct.pack('>HH', 1, 0))
        for t, body in chunks: f.write(t + struct.pack('>q', len(body)) + body)

def read_wav(path):
    with wave.open(str(path)) as w:
        n = w.getnframes(); ch = w.getnchannels(); rate = w.getframerate()
        s = struct.unpack('<%dh' % (n * ch), w.readframes(n))
    return [s[i] for i in range(0, len(s), ch)], rate

def write_wav(path, samples_bytes, rate, ch):
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(ch); w.setsampwidth(2); w.setframerate(rate); w.writeframes(samples_bytes)

def stats(x):
    if not x: return 'empty'
    peak = max(abs(v) for v in x); rms = (sum(v * v for v in x) / len(x)) ** 0.5
    return '%d samples, peak %d, rms %.0f' % (len(x), peak, rms)

def best_corr(a, b, maxlag):
    # Envelope-free normalised cross-correlation on a 4x decimated copy (fast enough in pure Python).
    # Both directions: a recording can start before (MIC timeline restarted, then the capture opens later)
    # or after the matching part of the reference. Positive lag = recording delayed against the reference.
    a = a[::4]; b = b[::4]; m = maxlag // 4; n = min(len(a), len(b)) - m
    if n < 200: n = min(len(a), len(b)) // 2
    if n < 200: return 0.0, 0
    best = (0.0, 0)
    for lag in range(-m, m, 2):
        if lag >= 0: xs = a[lag:lag + n]; ys = b[:n]
        else: xs = a[:n]; ys = b[-lag:-lag + n]
        if len(xs) < n or len(ys) < n: continue
        sxy = sum(x * y for x, y in zip(xs, ys)); sxx = sum(x * x for x in xs); syy = sum(y * y for y in ys)
        if sxx and syy:
            c = sxy / (sxx * syy) ** 0.5
            if abs(c) > abs(best[0]): best = (c, lag * 4)
    return best

def main():
    run = Path(sys.argv[1]); mic = sys.argv[2] if len(sys.argv) > 2 else None
    ref = read_wav(mic)[0] if mic else None
    log = (run / 'boot.log').read_text(errors='replace') if (run / 'boot.log').exists() else ''
    for tap in sorted(run.glob('*.opus')) + sorted(run.glob('*.pcm')):
        raw = tap.read_bytes(); out = tap.with_suffix('.wav')
        if tap.suffix == '.opus':
            packets, o = [], 0
            while o + 2 <= len(raw):
                n = raw[o] | raw[o + 1] << 8; packets.append(raw[o + 2:o + 2 + n]); o += 2 + n
            caf = tap.with_suffix('.caf')
            opus_to_caf(packets, 16000, 960, caf)
            subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', str(caf), str(out)], check=True)
            print('%s: %d Opus packets (%d..%d bytes)' % (tap.name, len(packets), min(map(len, packets)), max(map(len, packets))))
        else:
            write_wav(out, raw, 16000, 1)
        x, rate = read_wav(out)
        print('  decoded %s: %s' % (out.name, stats(x)))
        if ref:
            c, lag = best_corr(x, ref, 32000)
            print('  correlation with %s: %.2f at lag %d samples' % (Path(mic).name, c, lag))
    spk = run / 'speaker.raw'
    if spk.exists() and spk.stat().st_size:
        rate, ch = 48000, 2
        write_wav(run / 'speaker.wav', spk.read_bytes(), rate, ch)
        print('speaker.raw -> speaker.wav (%d Hz, %d ch): %s' % (rate, ch, stats(read_wav(run / 'speaker.wav')[0])))

if __name__ == '__main__':
    main()
