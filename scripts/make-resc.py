#!/usr/bin/env python3
"""Emit the Renode script for one run: make-resc.py <root> <out-dir> <seconds|0> [extra.resc]
seconds=0 means run until the process is killed (used by the Mac app)."""
import sys
from pathlib import Path
root, out, seconds = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
extra = sys.argv[4] if len(sys.argv) > 4 else ''
lines = []
for name in (root / 'platform/peripherals.list').read_text().split():
    lines.append(f'include @{root}/platform/peripherals/{name}.cs')
printf = (root / 'platform/hooks/printf.py').read_text()
syslog_hook = printf + '''
bus = machine.SystemBus
ap = bus.ReadDoubleWord(self.GetRegister(2).RawValue)
for _l in fw_format(bus, self.GetRegister(1).RawValue, ap).split('\\n'):
    if _l.strip(): print('[AP] ' + _l.rstrip())
'''
out_hook = '''
buf = self.GetRegister(0).RawValue
n = int(self.GetRegister(1).RawValue)
if 0 < n < 4096:
    data = machine.SystemBus.ReadBytes(buf, n)
    text = ''.join([chr(x) if (x == 10 or 32 <= x < 127) else '.' for x in data])
    for line in text.split('\\n'):
        if line.strip(): print('[AP:out] ' + line.rstrip())
'''
lines += [
    'mach create "RayNeo"',
    f'machine LoadPlatformDescription @{root}/platform/best1700.repl',
    f'sysbus LoadBinary @{out}/flash/flash0.bin 0x10000000',
    f'sysbus LoadBinary @{out}/flash/flash1.bin 0x28000000',
    f'lcdc FrameImagePath "{out}/frame.pgm"',
    'logLevel 3 nvic',
    'logLevel 3 bthNvic',
    'cpu PerformanceInMips 200',
    'btc PerformanceInMips 100',
    'bth PerformanceInMips 100',
    # Same entry the AP image's own Boot_Loader uses (0x10190010); SP from its vector.
    'cpu SP 0x202fffe0',
    'cpu PC 0x10190010',
    # AP trace hooks; addresses are from the 1.0.4.12 symbol table.
    'cpu AddHook 0x10b734 """' + out_hook + '"""',
    'cpu AddHook 0x105ca280 """' + syslog_hook + '"""',
]
if extra:
    lines.append(f'include @{extra}')
if seconds != '0':
    lines += [f'emulation RunFor "{seconds}"',
              'console_log `cpu PC`', 'console_log `cpu LR`', 'console_log `bth PC`', 'console_log `btc PC`', 'quit']
else:
    lines.append('start')
print('\n'.join(lines))
