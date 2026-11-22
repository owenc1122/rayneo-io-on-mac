#!/usr/bin/env python3
"""生成 SGN1 SCENE 文件（spare-io docs/PROTOCOL.md「SGN1 导航」）：
  sgn1.py <输出文件> [--sid N] [--seq N] [--man M] [--remain M] [--time S] [--icon N] [--imperial] [--units-raw B]
            [--road 文字] [--instr 文字] [--eta 14:35]
--imperial = SCENE 第 35 字节（载荷偏移 35）bit0；--units-raw 直接写该字节（测非法值）。"""
import argparse, struct, zlib
ap = argparse.ArgumentParser()
ap.add_argument('out'); ap.add_argument('--sid', type=int, default=0x5a17)
ap.add_argument('--seq', type=int, default=1); ap.add_argument('--man', type=int, default=152)
ap.add_argument('--remain', type=int, default=640); ap.add_argument('--time', type=int, default=420)
ap.add_argument('--icon', type=int, default=3); ap.add_argument('--imperial', action='store_true')
ap.add_argument('--units-raw', type=int); ap.add_argument('--road', default='Main St')
ap.add_argument('--instr', default='Turn right'); ap.add_argument('--eta', default='14:35')
ap.add_argument('--walk', action='store_true')
a = ap.parse_args()
units = a.units_raw if a.units_raw is not None else (1 if a.imperial else 0)
road, instr, eta = a.road.encode(), a.instr.encode(), a.eta.encode()
man_y = a.man * 2
p = struct.pack('<IhhHHHBBIIIhhBBBB', 1000, 0, 0, 0, 500, 1500, 8 if a.walk else 0, a.icon,
                a.man, a.remain, a.time, 0, man_y, len(road), len(instr), len(eta), units)
assert len(p) == 36 and p[35] == units
p += road + instr + eta
route = [(0, 0), (0, man_y), (200, man_y), (400, man_y)]
p += struct.pack('<H', len(route)) + b''.join(struct.pack('<hh', *xy) for xy in route)
roads = [(2, [(-400, man_y), (800, man_y)]), (1, [(0, -400), (0, 800)])]
p += struct.pack('<H', len(roads))
for c, pts in roads:
    p += struct.pack('<BB', c, len(pts)) + b''.join(struct.pack('<hh', *xy) for xy in pts)
hdr = b'SGN1' + struct.pack('<BBHIIII', 1, 1, 0, a.sid, a.seq, len(p), zlib.crc32(p) & 0xffffffff) + bytes(8)
open(a.out, 'wb').write(hdr + p)
print(a.out, len(hdr + p), 'units byte', units)
