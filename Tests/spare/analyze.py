#!/usr/bin/env python3
"""连拍分析：analyze.py <输出目录> [前缀 f] [--t0 毫秒] [--at 0,500,1000,1500,3000]
找卡片出现的第一帧（左眼画面相对首帧变化）为 t0，取 t0 + 各偏移的帧：OCR（本机 Vision）+ 拼一张对照图 sheet-<前缀>.png。
输出 ocr-<前缀>.txt：每帧「偏移 ms / 帧名 / 识别出的各行」。"""
import sys, glob, os, re, subprocess, argparse
from PIL import Image, ImageChops, ImageStat, ImageDraw
ap = argparse.ArgumentParser(); ap.add_argument('dir'); ap.add_argument('pre', nargs='?', default='f')
ap.add_argument('--t0', type=int); ap.add_argument('--at', default='0,500,1000,1500,3000'); ap.add_argument('--all', action='store_true')
a = ap.parse_args()
OCR = os.path.expanduser('~/Documents/RayNeo-io-on-Mac/.local/spare-ocr')
fr = {}
for p in glob.glob(os.path.join(a.dir, a.pre + '-*.p*m')) + glob.glob(os.path.join(a.dir, a.pre + '-*.png')):
    m = re.search(r'-(\d+)\.p', p)
    if m: fr.setdefault(int(m.group(1)), p)
ts = sorted(fr)
left = lambda t: Image.open(fr[t]).convert('L').crop((0, 0, 540, 280))
if a.t0 is None:
    base = left(ts[0]); a.t0 = ts[0]
    for t in ts[1:]:
        if ImageStat.Stat(ImageChops.difference(left(t), base)).mean[0] > 3: a.t0 = t; break
offs = [int(x) for x in a.at.split(',')] if not a.all else [t - a.t0 for t in ts if t >= a.t0]
rows, lines = [], ['t0 = %d ms（场景时间）' % a.t0]
for o in offs:
    t = min(ts, key=lambda x: abs(x - (a.t0 + o)))
    im = left(t); tmp = fr[t] if fr[t].endswith('.png') else None
    if not tmp:
        tmp = os.path.join(a.dir, '_tmp_ocr.png'); im.save(tmp)
    out = subprocess.run([OCR, tmp, '0', '0', '540', '280'], capture_output=True, text=True).stdout.strip()
    lines.append('+%d ms  %s\n  %s' % (t - a.t0, os.path.basename(fr[t]), out.replace('\n', '\n  ')))
    rows.append((t - a.t0, im))
sheet = Image.new('L', (540, 300 * len(rows)), 0); d = ImageDraw.Draw(sheet)
for i, (o, im) in enumerate(rows):
    sheet.paste(im, (0, 300 * i + 20)); d.text((4, 300 * i + 4), '+%d ms' % o, fill=200)
sheet.save(os.path.join(a.dir, 'sheet-%s.png' % a.pre))
open(os.path.join(a.dir, 'ocr-%s.txt' % a.pre), 'w').write('\n'.join(lines) + '\n')
print('\n'.join(lines))
