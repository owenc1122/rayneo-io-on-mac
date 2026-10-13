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
def bth_hook(mode):
    # mode 'v': nx_vsyslog(prio, fmt, va_list *ap) - everything that reaches syslog.
    # mode 's': vsyslog(prio, fmt, ap) - only lines the level mask (0x2300faec) drops.
    # mode 'i': hal_trace_printf_internal(attr, fmt, ap) - only lines that do not
    #           continue into nx_vsyslog (early boot, or masked).
    cond = {'v': 'True',
            's': '((bus.ReadByte(0x2300faec) >> int(self.GetRegister(0).RawValue)) & 1) == 0',
            'i': 'bus.ReadByte(0x23005d00) <= 3 or ((bus.ReadByte(0x2300faec) >> (((int(self.GetRegister(0).RawValue) >> 4) & 7) + 1)) & 1) == 0'}[mode]
    ap = 'bus.ReadDoubleWord(self.GetRegister(2).RawValue)' if mode == 'v' else 'self.GetRegister(2).RawValue'
    return printf + '''
bus = machine.SystemBus
if %s:
    for _l in fw_format(bus, self.GetRegister(1).RawValue, %s).split('\\n'):
        if _l.strip(): print('[BTH] ' + _l.rstrip())
''' % (cond, ap)
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
    # ARMv8-M: privileged accesses to the PPB (0xE0000000-0xE00FFFFF) always use the
    # default memory map and are never checked against MPU regions. Renode 1.17's
    # PMSAv8 model does check them, so the stock BTH code (MPU on, PRIVDEFENA=0)
    # faults reading SCB->VTOR. Model the architectural rule with an extra,
    # firmware-invisible privileged-RW/XN region 16 covering exactly the PPB.
    'bth PmsaV8Rnr 16', 'bth PmsaV8Rbar 0xe0000001', 'bth PmsaV8Rlar 0xe00fffe1', 'bth PmsaV8Rnr 0',
    'cpu SP 0x202fffe0',
    'cpu PC 0x10190010',
    # AP trace hooks; addresses are from the 1.0.4.12 symbol table.
    'cpu AddHook 0x10b734 """' + out_hook + '"""',
    'cpu AddHook 0x105ca280 """' + syslog_hook + '"""',
    # BTH hal_trace_printf_internal(attr, fmt, va_list): flash 0x0c003550, copied (by -0x590) to and
    # executed from SRAM alias 0x03002fc0 by the BTH reset code.
    'bth AddHook 0x03002fc0 """' + bth_hook('i') + '"""',
    # BTH vsyslog(prio, fmt, va_list) 0x0c04a3c8 and nx_vsyslog 0x0c040678.
    'bth AddHook 0x0c04a3c8 """' + bth_hook('s') + '"""',
    'bth AddHook 0x0c040678 """' + bth_hook('v') + '"""',
]
if extra:
    lines.append(f'include @{extra}')
if seconds != '0':
    lines += [f'emulation RunFor "{seconds}"',
              'console_log `cpu PC`', 'console_log `cpu LR`', 'console_log `bth PC`', 'console_log `btc PC`', 'quit']
else:
    lines.append('start')
print('\n'.join(lines))
