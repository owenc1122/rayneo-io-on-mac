#!/usr/bin/env python3
"""Build a raw SPI-NAND data image (littlefs partitions) from an original StrixOS OTA file set.

Static evidence (AP image base 0x10190000, see resfs.md):
  * bes_board_nand_initialize 0x10879858 registers /dev/<name> MTD partitions from the table at 0x182e6354
    (5 entries x 0x74 bytes: name[0x68], first u32, nblocks u32; units = MTD blocksize = 2048-byte page):
        nand_font        first    64  n 10240   -> /mnt/nand_font (mounted "ro"; LVGL drive N:)
        nand_resource_a  first 10304  n  5120   -> /mnt/nand_resource (active slot) or /mnt/nand_resource_backup
        nand_ota         first 15424  n  9216   -> /mnt/nand_ota
        nand_resource_b  first 24640  n  5120   -> the other resource slot
        nand_data        first 29760  n 34496   -> /mnt/nand_data (force-formatted on mount failure)
  * nandflash_mount_all_partitions 0x108f7b5c mounts every partition as "littlefs".
  * littlefs_bind 0x1086ed60: read_size = 4*blocksize, prog_size = blocksize, block_size = erasesize,
    block_count = neraseblocks, block_cycles = 200, cache_size = 4*blocksize,
    lookahead = min(((n+63)>>3)&~7, cache).  lfs_format 0x10872f38 writes disk version 0x00020001.
  * bes_nand_ioctl 0x108c68e8 MTDIOC_GEOMETRY: blocksize = 1<<page_shift, erasesize = 1<<block_shift.
    With the GD C8 81 profile in BES1700_NAND.cs: 2048-byte pages, 64 pages (128 KiB) per erase block.
  * Active resource slot: flag sector NOR flash0+0x188000 (ota_nand_resource_get_active_slot 0x10196580:
    word +0x44 == 0x5a5a5a5a -> slot B, otherwise slot A).  An erased flag sector selects slot A; this script
    writes the same resource set into both A and B so the choice does not matter.
  * BurnMode 3 files (OtaFileInfo.json, BurnAddr "M") go to /mnt/nand_resource/<BurnPath>
    (ResourcePool.cpp opens /mnt/nand_resource/images.bin, lotties.bin; cb_fw_venus.bin, *.dll, fac_test_img.bin,
    ota/ota_installer_progress.bin likewise).

Not in the OTA set: the nand_font contents (N:/nand_font/*.ttf). They ship pre-installed on the glasses.
Pass --fonts DIR to add .ttf files found there under their own names. --substitute adds documented
stand-ins for two of the missing files (see SUBSTITUTES); these are NOT the factory files.
Requires: pip install littlefs-python (scripts/setup-tools.sh creates .local/venv with it).
Output: <out>/nand-data.bin = 65536 pages x 2048 bytes (spare area not included; erased = 0xFF), plus a
        sparse page list <out>/nand-pages.txt for a loader.  No byte of any input file is modified.
Usage: make_nand_image.py <firmware-dir> <out-dir> [--fonts DIR]
"""
import hashlib, json, sys
from pathlib import Path

PAGE, PAGES_PER_BLOCK, TOTAL_PAGES = 2048, 64, 65536
PARTS = [('nand_font', 64, 10240), ('nand_resource_a', 10304, 5120), ('nand_ota', 15424, 9216),
         ('nand_resource_b', 24640, 5120), ('nand_data', 29760, 34496)]

def lfs_for(npages):
    from littlefs import LittleFS
    nblocks = npages // PAGES_PER_BLOCK
    cache = 4 * PAGE
    look = min(((nblocks + 63) >> 3) & ~7, cache) or 8
    return LittleFS(block_size=PAGE * PAGES_PER_BLOCK, block_count=nblocks, read_size=4 * PAGE, prog_size=PAGE,
                    cache_size=cache, lookahead_size=look, block_cycles=200, name_max=255, disk_version=0x00020001)

def put(fs, path, data):
    parent = '/'.join(path.split('/')[:-1])
    if parent:
        acc = ''
        for part in parent.split('/'):
            acc += '/' + part
            try: fs.mkdir(acc)
            except Exception: pass
    with fs.open('/' + path, 'wb') as f:
        f.write(data)

# Missing factory font -> same-family file the user may have (e.g. from the RayNeo phone app).
SUBSTITUTES = {
    'sh_sans_cn_reg_sub.ttf': 'SourceHanSansCN_Regular.ttf',        # subset of Source Han Sans CN Regular
    'roboto_condensed_reg_en_sub.ttf': 'RobotoCondensed-Regular.ttf',  # subset of Roboto Condensed Regular
}

def main():
    args = sys.argv[1:]
    fonts = None
    substitute = '--substitute' in args
    if substitute: args.remove('--substitute')
    if '--fonts' in args:
        i = args.index('--fonts'); fonts = Path(args[i + 1]); del args[i:i + 2]
    if len(args) != 2: raise SystemExit(__doc__)
    src, out = Path(args[0]), Path(args[1]); out.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((src / 'OtaFileInfo.json').read_text())
    images = {}
    for name, first, n in PARTS:
        images[name] = lfs_for(n)
    for item in manifest:
        if item['BurnMode'] != 3: continue
        data = (src / item['Name']).read_bytes()
        if len(data) != item['Size'] or hashlib.md5(data).hexdigest() != item['Md5'].lower():
            raise SystemExit(f"{item['Name']}: size/MD5 mismatch")
        if item['BurnAddr'] != 'M': raise SystemExit(f"{item['Name']}: unexpected BurnAddr {item['BurnAddr']}")
        for slot in ('nand_resource_a', 'nand_resource_b'):
            put(images[slot], item['BurnPath'], data)
    if fonts:
        names = set()
        for f in sorted(fonts.glob('*.tt[fc]')):
            put(images['nand_font'], f.name, f.read_bytes()); names.add(f.name)
            print(f'font {f.name}')
        if substitute:
            for want, have in SUBSTITUTES.items():
                if want not in names and (fonts / have).exists():
                    put(images['nand_font'], want, (fonts / have).read_bytes())
                    print(f'font {want} <- substitute {have}')
    raw = bytearray(b'\xff' * (PAGE * TOTAL_PAGES))
    pages = []
    for name, first, n in PARTS:
        buf = bytes(images[name].context.buffer)
        assert len(buf) == n * PAGE, (name, len(buf))
        raw[first * PAGE:(first + n) * PAGE] = buf
        for p in range(n):
            if buf[p * PAGE:(p + 1) * PAGE].count(0xff) != PAGE: pages.append(first + p)
    (out / 'nand-data.bin').write_bytes(raw)
    (out / 'nand-pages.txt').write_text('\n'.join(map(str, pages)) + '\n')
    print(f'{len(pages)} non-erased pages; partitions: ' + ', '.join(f'{n}@page{f}' for n, f, _ in PARTS))

if __name__ == '__main__':
    main()
