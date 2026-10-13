#!/usr/bin/env python3
"""Build installed NOR flash images from an original StrixOS OTA "files" set.

The OTA package ships every BurnMode=1 image with its first word erased
(0xffffffff).  The running firmware, however, expects the *installed* image to
start with the BES boot magic 0xBE57EC1C:

  * AP  norflash_calib_magic_word_valid / norflash_sample_delay_calib reads
    0x30190000 (its own image start) and compares with 0xBE57EC1C.
  * AP  subsys_check_boot_struct(0x28000000) (from bt_host_open) and
    subsys_check_boot_struct(0x30C10000) (from cp_subsys_open) require the same
    magic and then jump to image+0x10.

Every BurnMode=1 image ends with a build-info trailer <0xBE57341D><flash addr>.
That address is where the image is installed: AP 0x30190000 (flash0 +0x190000),
APC1 0x30C10000 (flash0 +0xC10000), BTH 0x28000000 (flash1 +0).  The AP's
hal_norflash_addr_to_id table maps 0x10000000/0x30000000 to flash id 0 and
0x08000000/0x28000000 to flash id 1.  BurnMode=2 entries carry explicit
addresses in OtaFileInfo.json (smf.json at 0x30FD0000 and 0x282FB000,
pil_algo_vad_demo.dll at 0x2830B000).

The installer that runs on the glasses after reboot is not part of the OTA set;
the "write the magic word last" step is the BES convention inferred from the
checks above.  No other byte of any image is changed.  BurnMode=3 entries
(NAND files) are handled by make-nand-image.py, not here.

Usage: make-flash-image.py <firmware-dir> <out-dir>
"""
import hashlib, json, struct, sys
from pathlib import Path

BOOT_MAGIC = 0xBE57EC1C
BUILD_INFO_MAGIC = 0xBE57341D
FLASHES = {  # id: (AP-view uncached base, size)
    0: (0x30000000, 0x2000000),
    1: (0x28000000, 0x1000000),
}

# Images whose trailer names a RAM load address.  dsp_open (AP 0x1059da14)
# memcpy()s 4 MiB from NOR 0x30E10000 to 0x1BC00000 and parses the HiFi4
# binary_struct there; it does not look at word 0.
RAM_LOADED = {0x1BC00000: 0x30E10000}

def flash_of(addr):
    for fid, (base, size) in FLASHES.items():
        for b in (base, base - 0x20000000):
            if b <= addr < b + size:
                return fid, addr - b
    raise SystemExit(f'address {addr:#x} is not in a known NOR flash')

def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    manifest = json.loads((src / 'OtaFileInfo.json').read_text())
    images = {fid: bytearray(b'\xff' * size) for fid, (_, size) in FLASHES.items()}
    report = []
    for item in manifest:
        name, mode = item['Name'], item['BurnMode']
        data = (src / name).read_bytes()
        if len(data) != item['Size'] or hashlib.md5(data).hexdigest() != item['Md5'].lower():
            raise SystemExit(f'{name}: size/MD5 does not match OtaFileInfo.json')
        if mode == 1:
            if data[-8:-4] != struct.pack('<I', BUILD_INFO_MAGIC):
                raise SystemExit(f'{name}: no build-info trailer')
            addr = struct.unpack('<I', data[-4:])[0]
            first = struct.unpack('<I', data[:4])[0]
            if first != 0xFFFFFFFF:
                raise SystemExit(f'{name}: first word {first:#x}, expected erased OTA header')
            if addr in RAM_LOADED:
                # Not executed in place: the AP copies it from NOR into RAM.
                fid, off = flash_of(RAM_LOADED[addr])
                blob = data  # header word is never read by the loader; keep as shipped
            else:
                fid, off = flash_of(addr)
                blob = struct.pack('<I', BOOT_MAGIC) + data[4:]
            targets = [(fid, off, blob)]
        elif mode == 2:
            targets = []
            for a in item['BurnAddr'].split(','):
                fid, off = flash_of(int(a, 16))
                targets.append((fid, off, data))
        else:
            continue
        for fid, off, blob in targets:
            img = images[fid]
            if off + len(blob) > len(img):
                raise SystemExit(f'{name}: does not fit flash{fid}')
            if any(x != 0xff for x in img[off:off + len(blob)]):
                raise SystemExit(f'{name}: overlaps an earlier image in flash{fid}')
            img[off:off + len(blob)] = blob
            report.append(f'flash{fid}+{off:#09x}  {len(blob):8d}  {name}')
    out.mkdir(parents=True, exist_ok=True)
    for fid, img in images.items():
        (out / f'flash{fid}.bin').write_bytes(img)
    (out / 'flash-layout.txt').write_text('\n'.join(report) + '\n')
    print('\n'.join(report))

if __name__ == '__main__':
    main()
