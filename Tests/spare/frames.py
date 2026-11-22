#!/usr/bin/env python3
"""生成连拍场景：frames.py <持续秒数> <间隔秒> [前缀] [--press-at s ...]
场景在 emulate.sh 的开机时长之后执行；每隔 <间隔> 存一帧 @OUT/<前缀>-<毫秒>.pgm（毫秒 = 场景内时间）。
--press <s>:<动作> 在场景内 s 秒做表冠动作：click / double / long / up / down。"""
import sys
args = sys.argv[1:]
press = []
while '--press' in args:
    i = args.index('--press'); press.append(args[i + 1]); del args[i:i + 2]
dur, step = float(args[0]), float(args[1]); pre = args[2] if len(args) > 2 else 'f'
acts = {'click': ['gpio0 Pulse 1 false 120'], 'long': ['gpio0 Pulse 1 false 2500'],
        'double': ['gpio0 Pulse 1 false 80', 'emulation RunFor "0.12"', 'gpio0 Pulse 1 false 80'],
        'up': ['i2c0.ots Rotate 400'], 'down': ['i2c0.ots Rotate -400']}
ev = [(float(p.split(':')[0]), p.split(':')[1]) for p in press]
t = 0.0; out = []
n = int(round(dur / step))
for k in range(n + 1):
    tk = round(k * step, 3)
    out.append('lcdc SaveFrame @OUT/%s-%06d.pgm' % (pre, int(tk * 1000)))
    due = [e for e in ev if tk <= e[0] < tk + step]
    for (pt, a) in due:
        if pt > tk: out.append('emulation RunFor "%.3f"' % (pt - tk))
        out += acts[a]
        out.append('emulation RunFor "%.3f"' % (tk + step - pt))
    if not due and k < n:
        out.append('emulation RunFor "%.3f"' % step)
print('\n'.join(out))
