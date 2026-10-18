"""Secure Simple Pairing (legacy, P-192) crypto for the virtual phone's classic-BT stack.

The glasses advertise SSP host support without Secure Connections (features ext page 1 bit3 clear),
so pairing uses P-192 ECDH and the SHA-256-based functions f1/f2/f3/g (Core spec Vol 2 Part H 7.7).
Just Works association (both sides NoInputNoOutput, no MITM): the numeric check values are compared
but never shown, ra = rb = 0.

Wire convention (confirmed empirically against the stock BTC firmware): every multi-octet value on the
LMP wire is little-endian, while the crypto functions operate on the standard big-endian representation.
So the public keys, nonces and the 128-bit results are byte-reversed at the air boundary; internally
everything here is big-endian.  This module is pure crypto; the LMP sequencing lives in bredr.py.
"""
import hashlib
import hmac
import os

# NIST P-192 (secp192r1)
_P = 0xfffffffffffffffffffffffffffffffeffffffffffffffff
_A = _P - 3
_B = 0x64210519e59c80e70fa7e9ab72243049feb8deecc146b9b1
_GX = 0x188da80eb03090f67cbf20eb43a18800f4ff0afd82ff1012
_GY = 0x07192b95ffc8da78631011ed6b24cdd573f977a11e794811
_N = 0xffffffffffffffffffffffff99def836146bc9b1b4d22831
_KEYLEN = 24


def _inv(x, m):
    return pow(x, -1, m)


def _add(p, q):
    if p is None:
        return q
    if q is None:
        return p
    x1, y1 = p
    x2, y2 = q
    if x1 == x2 and (y1 + y2) % _P == 0:
        return None
    if p == q:
        lam = (3 * x1 * x1 + _A) * _inv(2 * y1, _P) % _P
    else:
        lam = (y2 - y1) * _inv((x2 - x1) % _P, _P) % _P
    x3 = (lam * lam - x1 - x2) % _P
    y3 = (lam * (x1 - x3) - y1) % _P
    return (x3, y3)


def _mul(k, p):
    r = None
    while k:
        if k & 1:
            r = _add(r, p)
        p = _add(p, p)
        k >>= 1
    return r


def keypair(priv=None):
    """Return (priv_int, public_key_48_bytes = X||Y big-endian)."""
    if priv is None:
        priv = int.from_bytes(os.urandom(24), 'big') % (_N - 1) + 1
    x, y = _mul(priv, (_GX, _GY))
    return priv, x.to_bytes(_KEYLEN, 'big') + y.to_bytes(_KEYLEN, 'big')


def dhkey(priv, peer_pub):
    """P-192 ECDH shared secret = X coordinate, 24 bytes big-endian (peer_pub big-endian X||Y)."""
    x = int.from_bytes(peer_pub[:_KEYLEN], 'big')
    y = int.from_bytes(peer_pub[_KEYLEN:2 * _KEYLEN], 'big')
    sx, _sy = _mul(priv, (x, y))
    return sx.to_bytes(_KEYLEN, 'big')


def f1(U, V, X, Z):
    """Commitment. U,V = 24-byte PK X-coords (big-endian), X = 16-byte nonce, Z = 1 byte."""
    return hmac.new(X, U + V + Z, hashlib.sha256).digest()[:16]


def g(U, V, X, Y):
    """Numeric comparison value (6 digits). U,V = PK X-coords, X,Y = nonces (big-endian)."""
    return int.from_bytes(hashlib.sha256(U + V + X + Y).digest()[-4:], 'big') % 1000000


def f2(W, N1, N2, keyID, A1, A2):
    """Link key. W = 24-byte DHKey, N1/N2 = nonces, keyID = 4 bytes, A1/A2 = 6-byte addrs (big-endian)."""
    return hmac.new(W, N1 + N2 + keyID + A1 + A2, hashlib.sha256).digest()[:16]


def f3(W, N1, N2, R, IOcap, A1, A2):
    """Check value. R = 16-byte (0 for Just Works), IOcap = 3 bytes."""
    return hmac.new(W, N1 + N2 + R + IOcap + A1 + A2, hashlib.sha256).digest()[:16]


def _rev(b):
    return b[::-1]


class SspJustWorks:
    """Initiator (master = phone) Just Works SSP.  All on-wire values are little-endian; everything
    stored here is big-endian, reversed at the wire boundary by the caller via the air_* helpers.

    addr_a/addr_b: BD_ADDRs big-endian (6 bytes).  io_a/io_b: the 3 IO-capability octets as used by f3.
    """

    def __init__(self, addr_a_be, addr_b_be, io_a=b'\x03\x00\x00', io_b=b'\x03\x00\x00'):
        self.A, self.B = addr_a_be, addr_b_be
        self.io_a, self.io_b = io_a, io_b
        if os.environ.get('SSP_FIXED'):
            self.priv, self.pk_a = keypair(0x1122334455667788990011223344556677889900112233)
            self.na = bytes(range(16))
        else:
            self.priv, self.pk_a = keypair()
            self.na = os.urandom(16)
        self.pk_b = None
        self.cb = None          # big-endian
        self.nb = None          # big-endian
        self.dh = None

    # ---- wire helpers: public key fragments and nonces are little-endian on air ----
    def air_pk_a(self):
        return _rev(self.pk_a[:24]) + _rev(self.pk_a[24:])

    def set_air_pk_b(self, air48):
        self.pk_b = _rev(air48[:24]) + _rev(air48[24:48])
        self.dh = dhkey(self.priv, self.pk_b)

    def air_na(self):
        return _rev(self.na)

    def set_air_nb(self, air16):
        self.nb = _rev(air16)

    def set_air_cb(self, air16):
        self.cb = _rev(air16)

    def pkax(self):
        return self.pk_a[:24]

    def pkbx(self):
        return self.pk_b[:24]

    def check_confirm(self):
        return f1(self.pkbx(), self.pkax(), self.nb, b'\x00') == self.cb

    def numeric(self):
        return g(self.pkax(), self.pkbx(), self.na, self.nb)

    def air_ea(self):
        # f3's IOcap octet order is (AuthReq, OOB, IO_Capability) — reversed from the io_capability PDU.
        return _rev(f3(self.dh, self.na, self.nb, b'\x00' * 16, self.io_a[::-1], self.A, self.B))

    def check_air_eb(self, air16):
        return _rev(air16) == f3(self.dh, self.nb, self.na, b'\x00' * 16, self.io_b, self.B, self.A)

    def link_key(self):
        return f2(self.dh, self.na, self.nb, b'btlk', self.A, self.B)


if __name__ == '__main__':
    a_priv, a_pub = keypair()
    b_priv, b_pub = keypair()
    assert dhkey(a_priv, b_pub) == dhkey(b_priv, a_pub)
    print('ssp P-192 ECDH OK')
