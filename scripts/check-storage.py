#!/usr/bin/env python3
"""Exercise controller data paths without a vendor firmware image."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
runtime = root / '.local/renode/Renode.app/Contents/MacOS/renode'
with tempfile.TemporaryDirectory(prefix='rayneo-storage-') as temporary:
    staging = Path(temporary)
    commands = []
    sources = sorted((root / 'platform/peripherals').glob('*.cs'), key=lambda p: ({'BES1700_RegisterBank.cs': 0, 'BES1700_ClockControl.cs': 1}.get(p.name, 2), p.name))
    for source in sources:
        link = staging / source.name
        link.symlink_to(source)
        commands.append(f'include @{link}')
    (staging / 'board.repl').symlink_to(root / 'platform/best1700.repl')
    commands += ['mach create "StorageCheck"',
                 f'machine LoadPlatformDescription @{staging / "board.repl"}',
                 (root / 'Tests/Hardware/storage.resc').read_text()]
    script = staging / 'check.resc'
    script.write_text('\n'.join(commands))
    result = subprocess.run([str(runtime), '--disable-gui', '--console', '--plain',
                             '-e', f'include @{script}'], capture_output=True,
                            text=True, timeout=45)
    output = result.stdout + result.stderr
    numbers = [int(line.strip()) for line in output.splitlines() if line.strip().isdigit()]
    expected = [0xffffffff, 0x78563412, 0x3e08, 0x78563412, 1, 0x78563412, 0xffffffff]
    if result.returncode or numbers != expected:
        raise SystemExit(f'Storage checks failed: {numbers!r}\n{output}')
    print('PASS: NOR erase and streamed program; NAND page program, DMA read and erase.')
