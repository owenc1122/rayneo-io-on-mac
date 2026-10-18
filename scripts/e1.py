"""Classic Bluetooth authentication E1 and its SAFER+ core (Core spec Vol 2 Part H 7.1-7.6).

After SSP the verifier sends AU_RAND and the claimant replies SRES = E1(K, AU_RAND, BD_ADDR)[0:4];
the remaining 12 bytes are the ACO. The virtual phone is master/verifier and also answers the
glasses' challenge, so it needs E1. All quantities here are big-endian byte strings (the LMP wire is
little-endian; bredr.py reverses au_rand/sres/addr on the wire).
"""

# SAFER+ exp/log S-boxes: g=45, exp[i]=45^i mod 257 (256->0). Verified byte-exact vs nuttx_ap.bin@0x8fcea4.
_EXP = [0] * 256
_x = 1
for _i in range(256):
    _EXP[_i] = _x & 0xff if _x != 256 else 0
    _x = (_x * 45) % 257
_LOG = [0] * 256
for _i in range(256):
    _LOG[_EXP[_i]] = _i

# Key-schedule bias B[i][j] for subkeys 2..17 (Core spec 7.6, computed from exp at runtime):
#   B[i][j] = EXP[ EXP[ (17*i + j + 1) mod 256 ] mod 256 ], i=2..17 (1-based), j=1..16.
_BIAS = []
for _i in range(2, 18):
    _row = []
    for _j in range(1, 17):
        _row.append(_EXP[_EXP[(17 * _i + _j) % 256]])
    _BIAS.append(_row)

# Byte positions that use XOR (then EXP) in the odd keying layer; the rest use ADD (then LOG).
_XP = (0, 3, 4, 7, 8, 11, 12, 15)


def _key_schedule(key16):
    # 17 subkeys of 16 bytes. Register = key||parity(17 B); each round rotate every byte left 3 bits,
    # select a length-16 window at offset i, add the bias.
    reg = list(key16)
    par = 0
    for b in reg:
        par ^= b
    reg.append(par)                       # 17-byte register
    sub = [list(key16)]                   # subkey 1 = key (no bias)
    for i in range(1, 17):
        reg = [((b << 3) | (b >> 5)) & 0xff for b in reg]   # rotate each byte left 3 bits
        sk = [(reg[(i + j) % 17] + _BIAS[i - 1][j]) % 256 for j in range(16)]
        sub.append(sk)
    return sub


def _pht(a):
    # SAFER+ invertible diffusion: 2-point PHT on pairs + the "Armenian shuffle" permutation, 3x.
    a = list(a)
    for _ in range(3):
        for j in range(0, 16, 2):
            x, y = a[j], a[j + 1]
            a[j] = (2 * x + y) & 0xff
            a[j + 1] = (x + y) & 0xff
        a = [a[p] for p in (0, 1, 8, 9, 2, 3, 10, 11, 4, 5, 12, 13, 6, 7, 14, 15)]
    return a


def _safer_plus(block16, key16, prime=False):
    sub = _key_schedule(key16)
    a = list(block16)
    r1_in = None
    for r in range(8):
        if prime and r == 2:
            a = [(a[j] + r1_in[j]) & 0xff for j in range(16)]   # Ar': round-1 input added to round-3 input
        if r == 0:
            r1_in = list(a)
        k1, k2 = sub[2 * r], sub[2 * r + 1]
        for j in range(16):                                      # odd keying layer (XOR/ADD)
            a[j] = (a[j] ^ k1[j]) if j in _XP else (a[j] + k1[j]) & 0xff
        for j in range(16):                                      # nonlinear (EXP/LOG)
            a[j] = _EXP[a[j]] if j in _XP else _LOG[a[j]]
        for j in range(16):                                      # even keying layer (ADD/XOR)
            a[j] = (a[j] + k2[j]) & 0xff if j in _XP else a[j] ^ k2[j]
        a = _pht(a)
    last = sub[16]                                               # output transform with subkey 17
    for j in range(16):
        a[j] = (a[j] ^ last[j]) if j in _XP else (a[j] + last[j]) & 0xff
    return bytes(a)


def _ar(key, inp):
    return _safer_plus(inp, key, prime=False)


def _ar_prime(key, inp):
    return _safer_plus(inp, key, prime=True)


def _offset_key(k):
    # E1/E2/E3 key offset K' (Core spec 7.1): constants 233,229,223,193,179,167,149,131 with the
    # +/XOR pattern, flipped between the two halves.
    C = (233, 229, 223, 193, 179, 167, 149, 131)
    add0 = (True, False, True, False, True, False, True, False,     # K[0..7]: +,^,+,^,...
            False, True, False, True, False, True, False, True)     # K[8..15]: ^,+,^,+,...
    cc = C + C
    return bytes(((k[i] + cc[i]) % 256) if add0[i] else (k[i] ^ cc[i]) for i in range(16))


def e1(key16, rand16, addr6):
    """E1: returns (SRES 4 bytes, ACO 12 bytes). key, rand, addr are big-endian byte strings."""
    kprime = _offset_key(key16)
    h = _ar(key16, rand16)                                        # Ar(K, RAND)
    exp_addr = bytes(addr6) + bytes(addr6) + bytes(addr6[:4])      # addr||addr||addr[0:4] = 16 B
    inp = bytes(((h[i] ^ rand16[i]) + exp_addr[i]) % 256 for i in range(16))
    out = _ar_prime(kprime, inp)
    return out[:4], out[4:16]


if __name__ == '__main__':
    import sys
    if len(sys.argv) == 4:
        k = bytes.fromhex(sys.argv[1]); r = bytes.fromhex(sys.argv[2]); a = bytes.fromhex(sys.argv[3])
        s, aco = e1(k, r, a)
        print('SRES', s.hex(), 'ACO', aco.hex())
    else:
        s, aco = e1(bytes(16), bytes(16), bytes(6))
        print('E1 smoke', s.hex(), aco.hex())
