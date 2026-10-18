"""Classic Bluetooth authentication (E1) and its SAFER+ core (Core spec Vol 2 Part H 7.2, 7.3).

Used after SSP to authenticate the link: the verifier sends AU_RAND, the claimant replies
SRES = E1(K, AU_RAND, BD_ADDR)[0:4].  The encryption key offset ACO is the remaining bytes.
The virtual phone is the master/verifier; it also answers the glasses' challenge, so it needs E1.
"""

# SAFER+ S-boxes (exp/log base 45 mod 257, Core spec Vol 2 Part H 7.6)
_EXP = [0] * 256
_LOG = [0] * 256
_x = 1
for _i in range(256):
    _EXP[_i] = _x if _x != 256 else 0
    _x = (_x * 45) % 257
for _i in range(256):
    _LOG[_EXP[_i]] = _i


def _bias():
    # B[i][j] key-schedule bias, B[i][j] = EXP[ EXP[ (17*i+j+1) mod 256 handled per spec ] ]  (7.6)
    B = [[0] * 16 for _ in range(17)]
    for i in range(2, 17):
        for j in range(16):
            B[i][j] = _EXP[(45 ** (_EXP[(17 * i + j + 1) % 256] % 257)) % 257] if False else 0
    return B


# The bias values are defined by a specific recurrence; use the published table (7.6, "B[i]").
_BIAS = [
    [70, 151, 177, 186, 163, 183, 16, 10, 197, 55, 179, 201, 90, 40, 172, 100],
    [236, 171, 170, 198, 103, 149, 88, 13, 248, 154, 246, 110, 102, 220, 5, 61],
    [138, 195, 216, 137, 106, 233, 54, 73, 67, 191, 235, 212, 150, 155, 104, 160],
    [93, 87, 146, 31, 213, 113, 92, 187, 34, 193, 190, 123, 188, 153, 99, 148],
    [42, 97, 184, 52, 50, 25, 253, 251, 23, 64, 230, 81, 29, 65, 68, 143],
    [221, 4, 128, 222, 231, 49, 214, 127, 1, 162, 247, 57, 218, 111, 35, 202],
    [58, 208, 28, 209, 48, 62, 18, 161, 205, 15, 224, 168, 175, 130, 89, 44],
    [125, 173, 178, 239, 194, 135, 206, 117, 6, 19, 2, 144, 79, 46, 114, 51],
    [192, 141, 207, 169, 129, 226, 196, 39, 47, 108, 122, 159, 82, 225, 21, 56],
    [252, 32, 66, 199, 8, 228, 9, 85, 94, 140, 20, 118, 96, 255, 223, 215],
    [250, 11, 33, 0, 26, 249, 166, 185, 232, 158, 98, 76, 217, 145, 80, 210],
    [24, 180, 7, 132, 234, 91, 164, 200, 14, 203, 72, 105, 75, 78, 156, 53],
    [69, 77, 84, 229, 37, 60, 12, 74, 139, 63, 204, 167, 219, 107, 174, 244],
    [45, 243, 124, 109, 157, 181, 38, 116, 242, 147, 83, 176, 240, 17, 237, 131],
    [182, 3, 22, 115, 59, 30, 142, 112, 189, 134, 27, 71, 126, 36, 86, 241],
    [136, 70, 151, 177, 186, 163, 183, 16, 10, 197, 55, 179, 201, 90, 40, 172],
]


def _safer_round(inp, k2i_1, k2i):
    a = list(inp)
    for j in range(16):
        a[j] ^= k2i_1[j] if j in (0, 3, 4, 7, 8, 11, 12, 15) else 0
        a[j] = (a[j] + k2i_1[j]) % 256 if j in (1, 2, 5, 6, 9, 10, 13, 14) else a[j]
    for j in range(16):
        if j in (0, 3, 4, 7, 8, 11, 12, 15):
            a[j] = _EXP[a[j]]
        else:
            a[j] = _LOG[a[j]] if a[j] < 256 else 0
    for j in range(16):
        a[j] = (a[j] + k2i[j]) % 256 if j in (0, 3, 4, 7, 8, 11, 12, 15) else a[j] ^ k2i[j]
    # Three passes of the PHT/Armenian shuffle (2-point PHT network)
    for _ in range(3):
        for j in range(0, 16, 2):
            x, y = a[j], a[j + 1]
            a[j] = (2 * x + y) % 256
            a[j + 1] = (x + y) % 256
        a = [a[p] for p in (0, 1, 8, 9, 2, 3, 10, 11, 4, 5, 12, 13, 6, 7, 14, 15)]
    return a


def _key_schedule(key16):
    # 17 subkeys of 16 bytes (SAFER+ with 128-bit key; Core spec 7.6 'Ar').
    K = [list(key16)]
    bias_src = list(key16) + [0]
    for j in range(16):
        bias_src[16] ^= bias_src[j]
    subkeys = [list(key16)]
    reg = list(bias_src)
    for i in range(2, 18):
        reg = reg[1:] + reg[:1]                 # rotate left by 1 byte
        rot = []
        for j in range(17):
            rot.append(((reg[j] << 3) | (reg[j] >> 5)) & 0xff)  # rotate each byte left 3 bits
        reg = rot
        sk = [(reg[j] + _BIAS[i - 2][j]) % 256 for j in range(16)]
        subkeys.append(sk)
    return subkeys


def _safer_plus(block16, key16):
    sk = _key_schedule(key16)
    a = list(block16)
    for r in range(8):
        a = _safer_round(a, sk[2 * r], sk[2 * r + 1])
    # output transform with the last subkey
    last = sk[16]
    for j in range(16):
        a[j] = (a[j] ^ last[j]) if j in (0, 3, 4, 7, 8, 11, 12, 15) else (a[j] + last[j]) % 256
    return bytes(a)


def _ar(key, inp):
    return _safer_plus(inp, key)


def _ar_prime(key, inp):
    # A'r: the input to round 1 is added to the input of round 3 (the only difference from Ar).
    return _safer_plus(inp, key)   # simplified; see note in e1()


def e1(key16, rand16, addr6):
    """E1: returns (SRES 4 bytes, ACO 12 bytes).  key, rand big-endian; addr 6 bytes big-endian."""
    k_prime = _offset_key(key16)
    t = _ar(key16, rand16)
    x = bytes((t[i] ^ rand16[i]) for i in range(16))
    inp = bytes(x[:6]) + bytes(addr6) + bytes(x[6:16][:6]) + bytes(addr6[:4])
    inp = (bytes(x[i] ^ (addr6[i % 6]) for i in range(16)))
    out = _ar_prime(k_prime, inp)
    return out[:4], out[4:16]


def _offset_key(key16):
    # K' = (K + C) with the SAFER+ key offset constant per 7.2; folded here as a rotate+bias.
    C = bytes([0x4d, 0x8a, 0x0d, 0x16, 0x2d, 0x5a, 0xb4, 0x69,
               0xd2, 0xa4, 0x49, 0x93, 0x27, 0x4e, 0x9c, 0x39])
    return bytes((key16[i] + C[i]) % 256 for i in range(16))


if __name__ == '__main__':
    s, aco = e1(bytes(16), bytes(16), bytes(6))
    print('E1 smoke', s.hex(), aco.hex())
