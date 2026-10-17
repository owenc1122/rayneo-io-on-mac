#!/usr/bin/env python3
"""Set stock-firmware preferences in a flash0 image, as the RayNeo phone app's settings would.

    set-preference.py <flash0.bin> voice_wakeup=1 [wakeup_word=1] [0x15=1 ...]

The AP keeps preferences in the NOR "user data" record (stock 1.0.4.12: preference_init/read
0x107d6980/0x107d6c90, save_to_user_data, user_data_init): two 0x2000-byte copies at 0x30ff0000 (A)
and 0x30fee000 (B), the newer counter wins. Blob at copy offset 0:
  +0x00 header: u16 0x07e9, u16 4 (version), u16 total entries, u16 strings*16, u16 int entries, u16 string entries
  +0x0c + 8*key: u8 valid(1), u8 0, u16 key, u32 value     (string pool from +0xfac, kept as is)
Named keys: voice_wakeup = PREF_AI_VOICE_WAKEUP 0x15 (1 = 「小雷小雷」 voice wake on; factory default off),
wakeup_word = PREF_AI_WAKEUP_WORD 0x3c (1 Chinese 小雷小雷, 2 English), ai_state = PREF_AI_STATE 0x37.
"""
import struct
import sys
from pathlib import Path

FLASH_BASE = 0x30000000
COPIES = (0x30ff0000, 0x30fee000)
SIZE = 0x2000
VERSION = 0x013500c2
NAMES = {'voice_wakeup': 0x15, 'wakeup_word': 0x3c, 'ai_state': 0x37}


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    path = Path(argv[0])
    img = bytearray(path.read_bytes())
    copies = [bytearray(img[b - FLASH_BASE:b - FLASH_BASE + SIZE]) for b in COPIES]
    valid = [struct.unpack_from('<I', c, 0x1ef4)[0] == VERSION for c in copies]
    ver = [struct.unpack_from('<I', c, 0x1eec)[0] for c in copies]
    pick = 0 if valid[0] and (not valid[1] or ver[0] >= ver[1]) else 1 if valid[1] else 0
    blob = copies[pick]
    if struct.unpack_from('<HH', blob, 0) != (0x07e9, 4):
        blob[0:0xfac] = bytes(0xfac)
        struct.pack_into('<HH', blob, 0, 0x07e9, 4)
    for item in argv[1:]:
        k, v = item.split('=')
        key = NAMES.get(k, None)
        key = int(k, 0) if key is None else key
        struct.pack_into('<BBHI', blob, 0x0c + 8 * key, 1, 0, key, int(v, 0))
    ints = sum(1 for key in range(0x12c) if blob[0x0c + 8 * key] == 1 and struct.unpack_from('<H', blob, 0x0e + 8 * key)[0] == key)
    strings = struct.unpack_from('<H', blob, 0x0a)[0]
    struct.pack_into('<HHHH', blob, 4, ints + strings, strings * 16, ints, strings)
    struct.pack_into('<III', blob, 0x1eec, max(ver) + 1 if any(valid) else 1, 0, VERSION)
    for base in COPIES:
        img[base - FLASH_BASE:base - FLASH_BASE + SIZE] = blob
    path.write_bytes(img)
    print('preferences:', ' '.join(argv[1:]), '->', [hex(c) for c in COPIES])


if __name__ == '__main__':
    main(sys.argv[1:])
