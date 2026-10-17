#!/usr/bin/env python3
"""Emit the Renode script for one run: make-resc.py <root> <out-dir> <seconds|0> [extra.resc]
seconds=0 means run until the process is killed (used by the Mac app)."""
import sys
from pathlib import Path
root, out, seconds = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
def at(path):
    # Renode @path tokens end at a space; escape spaces (e.g. ~/Library/Application Support).
    return '@' + str(path).replace(' ', '\\ ')
extra = sys.argv[4] if len(sys.argv) > 4 else ''
lines = []
for name in (root / 'platform/peripherals.list').read_text().split():
    lines.append(f'include {at(root / "platform/peripherals" / (name + ".cs"))}')
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
def c1_hook(mode):
    # 'i': hal_trace_printf_internal (only lines that do not continue into nx_vsyslog);
    # 'v': nx_vsyslog(prio, fmt, va_list *ap). M55C1 addresses are read in its own view.
    if mode == 'i':
        cond = 'bus.ReadByte(0x20002c70, self) <= 3 or ((bus.ReadByte(0x1b753fdc) >> (((int(self.GetRegister(0).RawValue) >> 4) & 7) + 1)) & 1) == 0'
        ap = 'self.GetRegister(2).RawValue'
    else:
        cond = 'True'
        ap = 'bus.ReadDoubleWord(self.GetRegister(2).RawValue, self)'
    return printf + '''
bus = machine.SystemBus
if %s:
    for _l in fw_format(bus, self.GetRegister(1).RawValue, %s, self).split('\\n'):
        if _l.strip(): print('[C1] ' + _l.rstrip())
''' % (cond, ap)
def delay_hook(unit):
    return '''
from Antmicro.Renode.Time import TimeInterval
from Antmicro.Renode.Peripherals.CPU import RegisterValue
from System import Action
n = int(self.GetRegister(0).RawValue)
us = n if '%s' == 'us' else n // 1000
if us > 0:
    cpu = self
    ret = cpu.GetRegister(14).RawValue
    def wake(t):
        cpu.PC = RegisterValue.Create(ret, 32)
        cpu.IsHalted = False
    cpu.IsHalted = True
    machine.ScheduleAction(TimeInterval.FromMicroseconds(us), Action[TimeInterval](wake))
''' % unit
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
    f'machine LoadPlatformDescription {at(root / "platform/best1700.repl")}',
    f'sysbus LoadBinary {at(out / "flash/flash0.bin")} 0x10000000',
    f'sysbus LoadBinary {at(out / "flash/flash1.bin")} 0x28000000',
    f'lcdc FrameImagePath "{out}/frame.pgm"',
    # HiFi4 stand-in host audio: played streams are appended to speaker.raw (s16le, format in the log);
    # MIC=<wav or raw s16le 16 kHz mono> feeds the record streams (silence otherwise).
    f'hifi4 SpeakerFile "{out}/speaker.raw"',
    f'hifi4 TapDirectory "{out}"',
] + ([f'hifi4 MicFile "{__import__("os").environ["MIC"]}"'] if __import__('os').environ.get('MIC') else []) + (
    ['hifi4 MicLive true'] if __import__('os').environ.get('MIC_LIVE') else []) + (
    ['hifi4 MicLoop false'] if __import__('os').environ.get('MIC_LOOP') == '0' else []) + (
    # Wake-word enrolment recordings (scripts/make-kws-templates.sh); KWS=<dir> overrides.
    [f'hifi4 KwsTemplates "{__import__("os").environ.get("KWS") or root / ".local/kws"}"'] if (__import__('os').environ.get('KWS') or (root / '.local/kws').exists()) else []) + [
] + ([f'nand LoadImage {at(out / "nand/nand-data.bin")}'] if (out / 'nand/nand-data.bin').exists() else []) + (
    [f'nand LoadState {at(Path(state, "nand-state.bin"))}'] if (state := __import__('os').environ.get('STATE')) and Path(state, 'nand-state.bin').exists() else []) + ([] if not __import__('os').environ.get('APIRQDBG') else [
    'cpu AddHook 0x1008bc """\nn=self.GetRegister(0).RawValue\nif n>=100 and n<=115: print(\'[APIRQ] %d sp=0x%x\' % (n, self.GetRegister(13).RawValue))\n"""',
    'cpu AddHook 0x105dbb14 """\nbus=machine.SystemBus\nc=self.GetRegister(1).RawValue\nprint(\'[APFAULT] ctx=0x%x \' % c + \' \'.join([\'%08x\' % bus.ReadDoubleWord(c+4*i) for i in range(24)]))\n"""',
    'cpu AddHook 0x1008f0 """\nr=self.GetRegister(5).RawValue\nif (r & 1)==0: print(\'[APIRQ] even handler 0x%x irq %d\' % (r, self.GetRegister(4).RawValue))\n"""',
]) + [
    'logLevel 3 nvic',
    'logLevel 3 bthNvic',
    # All cores on one emulation thread (SERIAL=0 to run them in parallel). With parallel CPU threads,
    # guest spinlocks shared by the AP/M55C1/BTH occasionally livelock inside tlib, and peripheral models
    # shared by several cores race. Needs Renode >= 1.17.0+20261016 (the 20260906 build stalled in WFI).
] + ([] if __import__('os').environ.get('SERIAL') == '0' else ['emulation SetGlobalSerialExecution true']) + (
    # QUANTUM=<seconds>: cores synchronise every quantum (Renode default 0.0001).
    [f'emulation SetGlobalQuantum "{__import__("os").environ["QUANTUM"]}"'] if __import__('os').environ.get('QUANTUM') else []) + [
    'cpu PerformanceInMips 200',
    'btc PerformanceInMips 100',
    'bth PerformanceInMips 100',
    'c1 PerformanceInMips 100',
    # Same entry the AP image's own Boot_Loader uses (0x10190010); SP from its vector.
    # ARMv8-M: privileged accesses to the PPB (0xE0000000-0xE00FFFFF) always use the
    # default memory map and are never checked against MPU regions. Renode 1.17's
    # PMSAv8 model does check them, so the stock BTH code (MPU on, PRIVDEFENA=0)
    # faults reading SCB->VTOR. Model the architectural rule with an extra,
    # firmware-invisible privileged-RW/XN region 16 covering exactly the PPB.
    'bth PmsaV8Rnr 16', 'bth PmsaV8Rbar 0xe0000001', 'bth PmsaV8Rlar 0xe00fffe1', 'bth PmsaV8Rnr 0',
    'c1 PmsaV8Rnr 16', 'c1 PmsaV8Rbar 0xe0000001', 'c1 PmsaV8Rlar 0xe00fffe1', 'c1 PmsaV8Rnr 0',
    # M55C1 idle: in PM state IDLE its hal_sleep_proc(light) returns at 0x103cb8 without sleeping when
    # no sleep lock is held, so the idle loop spins at the core's full speed until the governor allows
    # deep sleep (seconds after any activity). Send it down the firmware's own light-sleep path instead
    # (0x103b5c: WFI with SLEEPDEEP clear, then the normal return). The PM state only changes in code
    # that an interrupt runs, and every interrupt ends the WFI. IDLE_SPIN=1 keeps the spinning.
] + ([] if __import__('os').environ.get('IDLE_SPIN') == '1' else [
    'c1 AddHook 0x00103cb8 "self.PC = Antmicro.Renode.Peripherals.CPU.RegisterValue.Create(0x103b5d, 32)"',
    # AP busy-wait delays on the 6 MHz counter (sysCmu +0x288): hal_sys_timer_delay_us(us) and
    # hal_sys_timer_delay_ns(ns) are 4-instruction loops reading the counter ~50 times per emulated
    # microsecond, each read a model call. The hook halts the core for exactly the requested time and
    # resumes it at the caller (interrupts arriving meanwhile are taken afterwards). DELAY_SPIN=1 keeps them.
]) + ([] if __import__('os').environ.get('DELAY_SPIN') == '1' else [
    'cpu AddHook 0x0011492c """' + delay_hook('us') + '"""',
    'cpu AddHook 0x0012f450 """' + delay_hook('ns') + '"""',
]) + [
] + (['dma BlockCopy false'] if __import__('os').environ.get('DMA_BLOCK') == '0' else []) + (['aonCmu PollHalt false'] if __import__('os').environ.get('AON_POLL') == '0' else []) + [
    'cpu SP 0x202fffe0',
    'cpu PC 0x10190010',
] + ([] if __import__('os').environ.get('HOOKS') == '0' else [
    # AP trace hooks (HOOKS=0 leaves them out); addresses are from the 1.0.4.12 symbol table.
    'cpu AddHook 0x10b734 """' + out_hook + '"""',
    'cpu AddHook 0x105ca280 """' + syslog_hook + '"""',
    # BTH hal_trace_printf_internal(attr, fmt, va_list): flash 0x0c003550, copied (by -0x590) to and
    # executed from SRAM alias 0x03002fc0 by the BTH reset code.
    'bth AddHook 0x03002fc0 """' + bth_hook('i') + '"""',
    # BTH vsyslog(prio, fmt, va_list) 0x0c04a3c8 and nx_vsyslog 0x0c040678.
    'bth AddHook 0x0c04a3c8 """' + bth_hook('s') + '"""',
    'bth AddHook 0x0c040678 """' + bth_hook('v') + '"""',
    # M55C1 hal_trace_printf_internal: flash 0x10c135c0, copied to its ITCM at 0x00102adc.
    'c1 AddHook 0x00102adc """' + c1_hook('i') + '"""',
    # M55C1 nx_vsyslog at 0x10d0a008 (veneer target from its trace path).
    'c1 AddHook 0x10d0a008 """' + c1_hook('v') + '"""',
]) + ([] if not __import__('os').environ.get('C1DBG') else [
    'c1 AddHook 0x10cfed54 """\nbus=machine.SystemBus\nr0=self.GetRegister(0).RawValue\nprint(\'[C1DBG] rx_by_chan r0=0x%x cfg=0x%x lr=0x%x\' % (r0, bus.ReadDoubleWord(r0), self.GetRegister(14).RawValue))\n"""',
    'c1 AddHook 0x10cff780 """\nbus=machine.SystemBus\nr0=self.GetRegister(0).RawValue\nprint(\'[C1DBG] rx_irq cfg=0x%x name=0x%x inst=0x%x lr=0x%x\' % (r0, bus.ReadDoubleWord(r0), bus.ReadDoubleWord(r0+0x10), self.GetRegister(14).RawValue))\n"""',
]) + [
]
if extra:
    lines.append(f'include {at(extra)}')
if seconds != '0':
    # REALTIME=1: pace a command-line run to the host clock like the app does.
    if __import__('os').environ.get('REALTIME') == '1':
        lines.append('aonCmu RealTime true')
    lines.append(f'emulation RunFor "{seconds}"')
    # SCENARIO=<file>: monitor commands run after the boot period (input tests, frame captures).
    scenario = __import__('os').environ.get('SCENARIO')
    if scenario:
        lines += [l.replace('@OUT/', at(out) + '/') for l in Path(scenario).read_text().splitlines() if l.strip() and not l.startswith('#')]
    lines += [
              'console_log `cpu PC`', 'console_log `cpu LR`', 'console_log `bth PC`', 'console_log `c1 PC`', 'console_log `btc PC`', 'quit']
else:
    # Mac app: keep virtual time from running ahead of the host (REALTIME=0 to run flat out).
    if __import__('os').environ.get('REALTIME') != '0':
        lines.append('aonCmu RealTime true')
    lines.append('start')
print('\n'.join(lines))
