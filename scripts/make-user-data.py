#!/usr/bin/env python3
"""Seed the NOR "user data" record of an installed flash0 image with a bonded phone.

    make-user-data.py <flash0.bin> [--name iPhone] [--addr 11:22:33:44:55:66] [--android]

A factory-fresh pair of glasses has no bond and shows BondView until the RayNeo
phone app pairs with it. The simulator has no phone radio, so this writes the
same record the firmware itself stores after a successful pairing; the stock
launcher then starts on its normal home page.

Layout (stock 1.0.4.12 AP: user_data_init, rn_flash_update, init_bond_info_from_storage):
  copy A = app_flash part 0x1c @ 0x30ff0000, copy B = part 0x1d @ 0x30fee000, 0x2000 bytes each
  +0x1cec rnlink bond record (0x84 bytes, magic at +0, then:)
          +0x04 peer address (6 bytes)   +0x10 bond state (2 = BONDED)
          +0x11 device type (1 = iOS)    +0x12 peer name (C string)
  +0x1eec / +0x1ef0 update counters (newer copy wins), +0x1ef4 layout version 0x013500c2
"""
import struct
import sys
from pathlib import Path

FLASH_BASE = 0x30000000
COPIES = (0x30ff0000, 0x30fee000)
SIZE = 0x2000
BOND_OFF, BOND_LEN = 0x1cec, 0x84
BOND_MAGIC = bytes.fromhex('68891a8c')
VERSION = 0x013500c2


def record(name, addr, ios):
    r = bytearray(BOND_LEN)
    r[0:4] = BOND_MAGIC
    r[4:10] = addr
    r[0x10] = 2
    r[0x11] = 1 if ios else 2
    n = name.encode()[:BOND_LEN - 0x13]
    r[0x12:0x12 + len(n)] = n
    return bytes(r)


def main(argv):
    args = list(argv)
    def opt(flag, default):
        if flag in args:
            i = args.index(flag); v = args[i + 1]; del args[i:i + 2]; return v
        return default
    name = opt('--name', 'iPhone')
    addr = bytes(int(x, 16) for x in opt('--addr', '5a:a1:00:00:10:01').split(':'))
    ios = '--android' not in args
    if not ios: args.remove('--android')
    if len(args) != 1 or len(addr) != 6:
        sys.exit(__doc__)
    path = Path(args[0])
    img = bytearray(path.read_bytes())
    copy = bytearray(SIZE)
    copy[BOND_OFF:BOND_OFF + BOND_LEN] = record(name, addr, ios)
    struct.pack_into('<III', copy, 0x1eec, 1, 0, VERSION)
    for base in COPIES:
        off = base - FLASH_BASE
        if off + SIZE > len(img):
            sys.exit(f'{path}: too small for user data at {base:#x}')
        img[off:off + SIZE] = copy
    path.write_bytes(img)
    print(f'user data: bonded {"iOS" if ios else "Android"} "{name}" {addr.hex(":")} -> {[hex(c) for c in COPIES]}')


if __name__ == '__main__':
    main(sys.argv[1:])
