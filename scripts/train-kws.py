#!/usr/bin/env python3
"""Trains the 「小雷小雷」 keyword classifier used by the HiFi4 stand-in's wakeup stage (BES1700_HiFi4Kws.cs).

  scripts/train-kws.py [out]        (default platform/kws/xiaolei.model)

A small neural keyword spotter of the kind DSP wake-word libraries use: MFCC frames (the C# front end,
reproduced exactly below) over a 1.3 s window, normalised per window, 2:1 time pooling, one hidden layer
(ReLU) and a sigmoid output. Training data are spoken by the macOS Chinese voices (`say`), with noise added
(white, pink, pink + mains hum, babble) at 20/10/5/0 dB:
  positives  「小雷小雷」 alone and followed by a command, windows ending 0-150 ms after the keyword;
  negatives  other phrases (similar names and syllables, other assistants' wake words, commands), the
             first 「小雷」 of the keyword alone, the keyword's tail, noise and silence.
The voices Flo, Reed and Meijia, the sentences, confusables and noise of scripts/make-test-audio.sh are
not used here: the regression tests run on unseen speakers and recordings. Needs numpy.
"""
import hashlib, math, os, subprocess, sys, tempfile, wave
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'platform/kws/xiaolei.model')
CACHE = os.path.join(ROOT, '.local/kws-train')
VOICES = ['Eddy (中文（中国大陆）)', 'Eddy (中文（台湾）)', 'Grandma (中文（中国大陆）)', 'Grandma (中文（台湾）)',
          'Grandpa (中文（中国大陆）)', 'Grandpa (中文（台湾）)', 'Rocko (中文（中国大陆）)', 'Rocko (中文（台湾）)',
          'Sandy (中文（中国大陆）)', 'Sandy (中文（台湾）)', 'Shelley (中文（中国大陆）)', 'Shelley (中文（台湾）)',
          'Sinji (中文（香港）)']
VALIDATION = ['Tingting (中文（中国大陆）)']   # held out (Mandarin) for checking the threshold
RATES = [150, 175, 0, 210, 235]   # 0 = the voice's default
KEYWORD = '小雷小雷'
COMMANDS = ['几点了', '放首歌', '明天天气', '给妈妈打电话', '音量大一点', '翻译一下']
NEGATIVES = ['小丽小丽', '小飞小飞', '小白小白', '小贝小贝', '小来小来', '小乐小乐', '小内小内', '小黑小黑', '小狗小狗',
             '小妹小妹', '小蕊小蕊', '小雷子', '雷小小', '小雷公', '小李子', '笑一笑', '小心打雷', '雷声很大',
             '小姐你好', '你好小艾', '小爱同学', '天猫精灵', '明天会下雨吗', '播放音乐', '现在几点了', '我想听歌',
             '导航去公司', '音量调大一点', '你叫什么名字', '小朋友们好', '老师再见', '谢谢小雨',
             '小雷你好', '找小雷', '小雷在吗', '打雷打雷', '春雷阵阵', '小小小小', '小梅小梅', '小眉小眉', '小妹妹'] + [
             f'小{c}小{c}' for c in '丽力礼雨玉来乐内黎梨立妮尼伟维威贝北飞菲黑白红明强刚东龙云文兰林玲宁娜雅艾安欧泥你理例']

SR, WIN, HOP, NFFT, NMEL, NCEP = 16000, 400, 160, 512, 26, 13
WINDOW, POOL = 130, 2   # frames in the classifier window (1.3 s), time pooling
THRESHOLD, GATE, TALK = 0.97, 0.7, 0.1   # decision threshold; speech: >= 10 % of frames 0.7 above the window's 10th percentile

# ---- MFCC exactly as HiFi4KeywordSpotter.Frame (C#)
def _mel(f): return 2595 * math.log10(1 + f / 700)
def _imel(m): return 700 * (10 ** (m / 2595) - 1)
_bins = [int(math.floor((NFFT + 1) * _imel(_mel(60) + (_mel(7600) - _mel(60)) * i / (NMEL + 1)) / SR)) for i in range(NMEL + 2)]
MEL = np.zeros((NMEL, NFFT // 2 + 1))
for m in range(NMEL):
    a, b, c = _bins[m], _bins[m + 1], _bins[m + 2]
    for k in range(a, b): MEL[m, k] = (k - a) / max(1, b - a)
    for k in range(b, c): MEL[m, k] = (c - k) / max(1, c - b)
HAMMING = 0.54 - 0.46 * np.cos(2 * np.pi * np.arange(WIN) / (WIN - 1))
DCT = np.cos(np.pi * np.arange(NCEP)[:, None] * (np.arange(NMEL)[None, :] + 0.5) / NMEL)

def mel_matrix(warp):
    """Mel filter bank; warp != 1 moves the filters (vocal tract length perturbation, training only)."""
    if warp == 1: return MEL
    m = np.zeros_like(MEL)
    edges = [min(max(_imel(_mel(60) + (_mel(7600) - _mel(60)) * i / (NMEL + 1)) / warp, 30), 7900) for i in range(NMEL + 2)]
    b = [int(math.floor((NFFT + 1) * f / SR)) for f in edges]
    for j in range(NMEL):
        lo, mid, hi = b[j], max(b[j + 1], b[j] + 1), max(b[j + 2], b[j + 1] + 2)
        for k in range(lo, mid): m[j, k] = (k - lo) / max(1, mid - lo)
        for k in range(mid, min(hi, NFFT // 2 + 1)): m[j, k] = (hi - k) / max(1, hi - mid)
    return m

def speed(x, factor):
    """Speed perturbation (tempo and pitch together) by resampling; training only."""
    if factor == 1: return x
    return np.interp(np.arange(0, len(x) - 1, factor), np.arange(len(x)), x)

def mfcc(x, warp=1):
    """x: float samples in [-1, 1]. Returns (frames, NCEP) cepstra and per-frame log energy."""
    n = (len(x) - WIN) // HOP + 1
    if n <= 0: return np.zeros((0, NCEP)), np.zeros(0)
    idx = np.arange(WIN)[None, :] + HOP * np.arange(n)[:, None]
    fr = x[idx]
    pre = fr.copy(); pre[:, 1:] = fr[:, 1:] - 0.97 * fr[:, :-1]
    spec = np.fft.rfft(pre * HAMMING, NFFT)
    power = spec.real ** 2 + spec.imag ** 2
    energy = np.log(power.sum(axis=1) + 1e-8)
    logmel = np.log(power @ mel_matrix(warp).T + 1e-8)
    return logmel @ DCT.T, energy

def window_features(cep):
    """cep: (WINDOW, NCEP) -> normalised, pooled feature vector (as the C# classifier computes it)."""
    w = cep - cep.mean(axis=0)
    w = w / (w.std(axis=0) + 1e-3)
    return w.reshape(WINDOW // POOL, POOL, NCEP).mean(axis=1).reshape(-1)

# ---- training audio
def speak(text, voice, rate, tmp):
    key = f'{voice}|{rate}|{text}'
    path = os.path.join(CACHE, hashlib.md5(key.encode()).hexdigest()[:16] + '.raw')
    if not os.path.exists(path):
        args = ['say', '-v', voice] + (['-r', str(rate)] if rate else []) + ['-o', f'{tmp}/a.aiff', text]
        if subprocess.run(args, capture_output=True).returncode != 0: return None
        subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', f'{tmp}/a.aiff', f'{tmp}/a.wav'], check=True)
        w = wave.open(f'{tmp}/a.wav'); open(path, 'wb').write(w.readframes(w.getnframes()))
    return np.frombuffer(open(path, 'rb').read(), np.int16).astype(np.float64) / 32768

def speech_span(x):
    _, e = mfcc(x)
    on = np.where(e > e.max() - 8)[0]
    return on[0], on[-1]

rng = np.random.default_rng(7)
def noise(n, kind, babble):
    w = rng.standard_normal(n)
    if kind == 'white': return w
    f = np.fft.rfft(w); fr = np.fft.rfftfreq(n, 1 / SR); f /= np.sqrt(np.maximum(fr, 40)); p = np.fft.irfft(f, n); p /= p.std()
    if kind == 'pink': return p
    if kind == 'hum': return p + 0.4 * np.sin(2 * np.pi * rng.choice([50, 60, 100, 120]) * np.arange(n) / SR + rng.uniform(0, 6))
    b = np.zeros(n)
    for _ in range(4):
        s = babble[rng.integers(len(babble))]; s = np.tile(s, n // len(s) + 1)[:n]; b += np.roll(s, rng.integers(n))
    return b / (b.std() + 1e-9)

def add_noise(x, snr, kind, babble):
    if snr is None: return x
    sp = x[np.abs(x) > 0.003]
    p = np.mean(sp ** 2) if len(sp) else 1e-4
    n = noise(len(x), kind, babble)
    return x + np.sqrt(p / 10 ** (snr / 10)) * n

def pad(x, before, after): return np.concatenate([np.zeros(int(before * SR)), x, np.zeros(int(after * SR))])

def detect(x, model, threshold):
    """Streaming decision exactly as HiFi4KeywordNet.Push: returns hit times (s) and the highest score."""
    mu, sd, W1, b1, W2, b2 = model
    cep, e = mfcc(x)
    hits, above, refractory, top = [], 0, 0, 0.0
    for t in range(WINDOW, len(cep) + 1, 2):
        if refractory > 0: refractory -= 2; continue
        f = (window_features(cep[t - WINDOW:t]) - mu) / sd
        p = 1 / (1 + math.exp(-max(-30, min(30, float(np.maximum(f @ W1 + b1, 0) @ W2 + b2)))))
        top = max(top, p)
        ew = e[t - WINDOW:t]; talk = np.mean(ew > np.percentile(ew, 10) + GATE) if ew.max() >= -14 else 0
        above = above + 1 if p >= threshold and talk >= TALK else 0
        if above >= 2: hits.append(round((t * HOP + WIN) / SR, 2)); above = 0; refractory = 100
    return hits, top

def main():
    os.makedirs(CACHE, exist_ok=True); os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = tempfile.mkdtemp()
    pos_rec, neg_rec, cmd_rec, pos_val, neg_val = [], [], [], [], []
    for v in VOICES + VALIDATION:
        for r in RATES:
            k = speak(KEYWORD, v, r, tmp)
            if k is not None: (pos_val if v in VALIDATION else pos_rec).append(k)
        for t in NEGATIVES:
            for r in (0, 210) if hashlib.md5((t + v).encode()).digest()[0] % 2 else (0,):
                s = speak(t, v, r, tmp)
                if s is not None: (neg_val if v in VALIDATION else neg_rec).append(s)
        for t in COMMANDS:
            s = speak(t, v, 0, tmp)
            if s is not None: cmd_rec.append(s)
    print(f'{len(pos_rec)} keyword recordings, {len(neg_rec)} negative phrases, {len(cmd_rec)} commands', flush=True)
    babble = neg_rec + cmd_rec
    conditions = [(None, None), (20, 'white'), (10, 'pink'), (10, 'babble'), (5, 'hum'), (5, 'babble'), (0, 'pink')]
    X, Y = [], []
    def take(cep, end, label):
        if end >= WINDOW and end <= len(cep): X.append(window_features(cep[end - WINDOW:end])); Y.append(label)
    perturb = [(w, f) for w in (0.88, 1.0, 1.12) for f in (0.92, 1.0, 1.08)]
    for k0 in pos_rec:
      for warp, factor in perturb:
        k = speed(k0, factor)
        a, b = speech_span(k)
        follow = cmd_rec[rng.integers(len(cmd_rec))]
        for tail in (None, follow):
            sig = pad(k, 1.4, 0.0) if tail is None else np.concatenate([pad(k, 1.4, 0.0), np.zeros(int(0.12 * SR)), tail])
            sig = np.concatenate([sig, np.zeros(int(0.8 * SR))])
            kw_end = int(1.4 * SR / HOP) + b + 1   # frame index just after the keyword
            for snr, kind in conditions[rng.integers(len(conditions))], conditions[rng.integers(len(conditions))]:
                cep, _ = mfcc(add_noise(sig, snr, kind, babble), warp)
                for d in range(0, 16, 3): take(cep, kw_end + d, 1)
                # partial keyword (the first 小雷 only, or ending early) and the keyword's tail/after
                half = int(1.4 * SR / HOP) + a + (b - a) // 2
                for d in (-6, -2, 2, 6): take(cep, half + d, 0)
                for d in (-28, -20, 40, 60, 80): take(cep, kw_end + d, 0)
    for s0 in neg_rec:
        for _ in range(2):
            warp, factor = perturb[rng.integers(len(perturb))]
            sig = pad(speed(s0, factor), 1.4, 0.6)
            snr, kind = conditions[rng.integers(len(conditions))]
            cep, _ = mfcc(add_noise(sig, snr, kind, babble), warp)
            for end in range(WINDOW, len(cep) + 1, 8): take(cep, end, 0)
    for kind in ('white', 'pink', 'hum', 'babble'):
        for level in (0.003, 0.03, 0.1):
            cep, _ = mfcc(level * noise(6 * SR, kind, babble))
            for end in range(WINDOW, len(cep) + 1, 10): take(cep, end, 0)
    X = np.array(X, np.float32); Y = np.array(Y, np.float32)
    print(f'{int(Y.sum())} positive / {int(len(Y) - Y.sum())} negative windows, {X.shape[1]} inputs', flush=True)
    mu, sd = X.mean(axis=0), X.std(axis=0) + 1e-3
    Xn = (X - mu) / sd
    # one hidden layer, ReLU, sigmoid output; Adam, class-balanced binary cross-entropy, weight decay
    H = 32
    W1 = rng.standard_normal((X.shape[1], H)).astype(np.float32) * math.sqrt(2 / X.shape[1]); b1 = np.zeros(H, np.float32)
    W2 = rng.standard_normal(H).astype(np.float32) * math.sqrt(1 / H); b2 = np.float32(0)
    params = [W1, b1, W2, np.array([b2])]
    m = [np.zeros_like(p) for p in params]; v = [np.zeros_like(p) for p in params]
    wpos = math.sqrt((len(Y) - Y.sum()) / max(Y.sum(), 1))
    step = 0
    for epoch in range(30):
        order = rng.permutation(len(Y))
        for i in range(0, len(order), 256):
            j = order[i:i + 256]; x = Xn[j] + 0.3 * rng.standard_normal(Xn[j].shape).astype(np.float32); y = Y[j]
            h = np.maximum(x @ params[0] + params[1], 0)
            z = h @ params[2] + params[3][0]
            p = 1 / (1 + np.exp(-np.clip(z, -30, 30)))
            wgt = np.where(y > 0, wpos, 1.0)
            g = (p - y) * wgt / len(j)
            gW2 = h.T @ g; gb2 = np.array([g.sum()])
            gh = np.outer(g, params[2]) * (h > 0)
            gW1 = x.T @ gh; gb1 = gh.sum(axis=0)
            grads = [gW1 + 1e-3 * params[0], gb1, gW2 + 1e-3 * params[2], gb2]
            step += 1
            for q in range(4):
                m[q] = 0.9 * m[q] + 0.1 * grads[q]; v[q] = 0.999 * v[q] + 0.001 * grads[q] ** 2
                params[q] -= 2e-3 * (m[q] / (1 - 0.9 ** step)) / (np.sqrt(v[q] / (1 - 0.999 ** step)) + 1e-8)
        h = np.maximum(Xn @ params[0] + params[1], 0); p = 1 / (1 + np.exp(-np.clip(h @ params[2] + params[3][0], -30, 30)))
        if epoch % 5 == 4 or epoch == 29:
            print(f'epoch {epoch + 1}: positives missed {np.mean(p[Y > 0] < 0.5):.3f}, negatives accepted {np.mean(p[Y == 0] >= 0.5):.4f}', flush=True)
    model = (mu, sd, params[0], params[1], params[2], params[3][0])
    vsets = []
    for name, recs, want in (('keyword', pos_val, 1), ('other', neg_val, 0)):
        for snr, kind in ((None, None), (10, 'hum'), (5, 'babble')):
            for k in recs:
                sig = pad(np.concatenate([k, np.zeros(1900), cmd_rec[rng.integers(len(cmd_rec))]]) if want else k, 1.5, 1.0)
                vsets.append((want, add_noise(sig, snr, kind, neg_val)))
    for th in (0.5, 0.7, 0.8, 0.9, 0.95, 0.98, 0.99):
        tp = sum(1 for w, x in vsets if w and detect(x, model, th)[0]); fa = sum(1 for w, x in vsets if not w and detect(x, model, th)[0])
        print(f'threshold {th}: keyword found {tp}/{sum(w for w, _ in vsets)}, false wakes {fa}/{sum(1 - w for w, _ in vsets)}', flush=True)
    # validation: held-out voices, keyword + command / other phrases, clean and in noise
    vb = [s for s in neg_val]
    for name, recs, want in (('keyword', pos_val, 1), ('other phrases', neg_val, 0)):
        for snr, kind in ((None, None), (10, 'hum'), (5, 'babble')):
            ok = 0
            for k in recs:
                sig = pad(np.concatenate([k, np.zeros(1900), cmd_rec[rng.integers(len(cmd_rec))]]) if want else k, 1.5, 1.0)
                hits, _ = detect(add_noise(sig, snr, kind, vb), model, THRESHOLD)
                ok += (len(hits) > 0) == bool(want)
            print(f'validation {name:13s} {str(snr) + " dB " + kind if snr else "clean":12s}: {ok}/{len(recs)} correct', flush=True)
    test = os.path.join(ROOT, '.local/test-audio')
    if os.path.isdir(test):
        for f in sorted(os.listdir(test)):
            w = wave.open(os.path.join(test, f)); x = np.frombuffer(w.readframes(w.getnframes()), np.int16) / 32768
            hits, top = detect(x, model, THRESHOLD); print(f'test {f:24s} max {top:.3f} hits {hits}', flush=True)
    with open(OUT, 'w') as f:
        f.write(f'# 小雷小雷 keyword classifier (scripts/train-kws.py): window {WINDOW} frames, pool {POOL}, {NCEP} cepstra, hidden {H}\n')
        f.write(f'{WINDOW} {POOL} {NCEP} {H}\n')
        for arr in (mu, sd, params[0].T.reshape(-1), params[1], params[2], params[3]):
            f.write(' '.join(f'{float(a):.6g}' for a in arr) + '\n')
    print('wrote', OUT)

if __name__ == '__main__':
    main()
