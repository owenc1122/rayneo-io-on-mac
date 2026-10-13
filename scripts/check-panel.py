#!/usr/bin/env python3
"""Verify panel GPIO/SPI bit order, register roundtrip and CS transaction reset."""
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parent.parent
commands=[f'include @{root}/platform/peripherals/{name}.cs' for name in ['BES1700_RegisterBank','BES1700_GPIO','BES1700_PanelSPI','BES1700_LCDC','BES1700_I2CRegisters']]+['mach create "PanelCheck"']
with tempfile.TemporaryDirectory(prefix='rayneo-panel-') as temporary:
    p=Path(temporary)
    (p/'board.repl').write_text('gpio: GPIOPort.BES1700_GPIO @ sysbus 0x40089000\n    panelSPI: true\nspi: SPI.BES1700_PanelSPI @ sysbus 0x40009000\n    panel: gpio\nlcdc: Video.BES1700_LCDC @ sysbus 0x401c0000\n    panel: gpio\ni2c: I2C.DesignWare_APB_I2C @ sysbus 0x40075000\npower: Miscellaneous.BES1700_I2CRegisters @ i2c 0x70\n')
    board=p/'board.repl'
    board.write_text(board.read_text().replace('lcdc: Video.BES1700_LCDC @ sysbus 0x401c0000\n    panel: gpio',f'lcdc: Video.BES1700_LCDC @ sysbus 0x401c0000\n    panel: gpio\n    capturePath: "{p}/frame.bin"')+'ram: Memory.MappedMemory @ sysbus 0x20000000\n    size: 0x1000\n')
    commands += [f'machine LoadPlatformDescription @{p}/board.repl']
    def pin(bit,on): commands.append(f'gpio WriteDoubleWord {0 if on else 12} {1<<bit}')
    def byte(value,read=False):
        for bit in range(7,-1,-1):
            pin(18, bool(value & (1<<bit)));pin(17,True)
            if read: commands.append('console_log `gpio ReadDoubleWord 0x50`')
            pin(17,False)
    def transaction(values,read=False):
        pin(16,False)
        for value in values: byte(value)
        if read: byte(255,True)
        pin(16,True)
    transaction([0x19,0x34],True)
    transaction([0x18,0x22,0xa5]);transaction([0x19,0x22],True)
    pin(16,False);byte(0x19);pin(16,True)
    transaction([0x19,0x34],True)
    commands += ['lcdc WriteDoubleWord 0x284 0x18', 'lcdc WriteDoubleWord 0x288 0x22690000', 'lcdc WriteDoubleWord 0x280 0xf3']
    transaction([0x19,0x22],True)
    commands += ['console_log `lcdc ReadDoubleWord 0x1c4`','lcdc WriteDoubleWord 0x1c4 0','console_log `lcdc ReadDoubleWord 0x1c4`']
    pin(16,False)
    for value in [0x19,0x34,0xff]: commands.append(f'spi WriteDoubleWord 8 {value}')
    for _ in range(3): commands.append('console_log `spi ReadDoubleWord 8`')
    pin(16,True)
    # GPIO chip selection must take precedence over the LCDC mux setting.
    pin(23,False)
    commands += ['lcdc WriteDoubleWord 0x2a8 0x4701','lcdc WriteDoubleWord 0x284 0x18','lcdc WriteDoubleWord 0x288 0x22960000','lcdc WriteDoubleWord 0x280 0xf3']
    pin(23,True);pin(23,False)
    for value in [0x19,0x22,0xff]: commands.append(f'spi WriteDoubleWord 8 {value}')
    for _ in range(3): commands.append('console_log `spi ReadDoubleWord 8`')
    pin(23,True)
    commands += ['i2c WriteDoubleWord 4 0x70','i2c WriteDoubleWord 0x6c 1','i2c WriteDoubleWord 0x10 0x11','i2c WriteDoubleWord 0x10 0x25a','i2c WriteDoubleWord 0x10 0x11','i2c WriteDoubleWord 0x10 0x300','console_log `i2c ReadDoubleWord 0x10`']
    frame=bytes(range(16))
    for i,value in enumerate(frame): commands.append(f'sysbus WriteByte {0x20000000+i} {value}')
    commands += ['lcdc WriteDoubleWord 0x190 0x201','lcdc WriteDoubleWord 0xc0 0x20000000','lcdc WriteDoubleWord 0xe0 8','lcdc WriteDoubleWord 0xec 0x20002','lcdc WriteDoubleWord 0x1c4 0','lcdc WriteDoubleWord 0x224 1','console_log `lcdc CompletedFrames`','console_log `lcdc ReadDoubleWord 0x1c4`','lcdc WriteDoubleWord 0x1c4 0','console_log `lcdc ReadDoubleWord 0x1c4`']
    commands.append('quit')
    (p/'test.resc').write_text('\n'.join(commands))
    result=subprocess.run([str(root/'.local/renode/Renode.app/Contents/MacOS/renode'),'--disable-gui','--console','--plain','-e',f'include @{p}/test.resc'],capture_output=True,text=True,timeout=45)
    output=result.stdout+result.stderr
    numbers=[int(s.strip()) for s in output.splitlines() if s.strip().isdigit()]
    bits=[(value>>19)&1 for value in numbers[:32]]
    extras=numbers[32:]
    if len(extras)>8: extras[8]&=255
    expected=[(v>>i)&1 for v in [0x87,0xa5,0x87,0x69] for i in range(7,-1,-1)]
    if result.returncode or bits!=expected or extras!=[1<<18,0,0,0,0x87,0,0,0x96,0x5a,1,0x100400,0] or not (p/'frame.bin').exists() or (p/'frame.bin').read_bytes()!=frame: raise SystemExit(output)
    print('PASS: panel ID bits, register write/read, aborted transaction reset, dual-panel selection, hardware SPI, LCDC acknowledgement I2C power controls, scanout bytes and frame completion.')
