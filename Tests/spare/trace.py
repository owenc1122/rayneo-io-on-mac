#!/usr/bin/env python3
"""解虚拟手机收到的 Spare 诊断记录（spare_trace_v1，SGT1 24 字节：code step t_ms a b c）：
  trace.py <peer.log> [code ...]   例：trace.py peer.log 116"""
import re, sys, struct
want = {int(x) for x in sys.argv[2:]}
for l in open(sys.argv[1], errors='replace'):
    m = re.search(r'"cmd":"spare_trace_v1".*"data":"([0-9a-f]+)"', l)
    if not m: continue
    d = bytes.fromhex(m.group(1))
    if d[:4] != b'SGT1' or len(d) < 24: continue
    code, step = d[5], d[6]
    t, a, b, c = struct.unpack_from('<IIII', d, 8)
    if want and code not in want: continue
    print('%s code %d step %d t=%.1fs a=0x%x b=0x%x c=0x%x' % (l[:8], code, step, t / 1000, a, b, c))
