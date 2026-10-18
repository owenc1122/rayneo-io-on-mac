"""SBC (low-complexity subband codec, A2DP spec v1.3 appendix B) in pure Python.

    enc = SbcEncoder(rate=44100, channels=2, mode=JOINT_STEREO, blocks=16, subbands=8,
                     allocation=LOUDNESS, bitpool=53)
    frame = enc.encode(pcm)          # pcm: list of channels, each blocks*subbands int16 samples
    dec = SbcDecoder(); pcm = dec.decode(frame)

The encoder follows the spec's reference algorithm: polyphase analysis filterbank (Proto_4_40 /
Proto_8_80 windows), scale factors, joint-stereo decision per subband, loudness/SNR bit allocation,
quantisation, CRC-8 and bit packing. The decoder is the spec's synthesis side; it is used by the
unit tests to check that encoded frames decode back to the input.
"""
import math

MONO, DUAL_CHANNEL, STEREO, JOINT_STEREO = 0, 1, 2, 3
LOUDNESS, SNR = 0, 1
RATES = (16000, 32000, 44100, 48000)
BLOCKS = (4, 8, 12, 16)

# Prototype filter windows (A2DP spec tables 12.x, "Proto_4_40" and "Proto_8_80").
PROTO_4_40 = (
    0.0, 5.36548976E-04, 1.49188357E-03, 2.73370904E-03, 3.83720193E-03, 3.89205149E-03,
    1.86581691E-03, -3.06012286E-03, 1.09137620E-02, 2.04385087E-02, 2.88757392E-02,
    3.21939290E-02, 2.58767811E-02, 6.13245186E-03, -2.88217274E-02, -7.76463494E-02,
    1.35593274E-01, 1.94987841E-01, 2.46636662E-01, 2.81828203E-01, 2.94315332E-01,
    2.81828203E-01, 2.46636662E-01, 1.94987841E-01, -1.35593274E-01, -7.76463494E-02,
    -2.88217274E-02, 6.13245186E-03, 2.58767811E-02, 3.21939290E-02, 2.88757392E-02,
    2.04385087E-02, -1.09137620E-02, -3.06012286E-03, 1.86581691E-03, 3.89205149E-03,
    3.83720193E-03, 2.73370904E-03, 1.49188357E-03, 5.36548976E-04)
PROTO_8_80 = (
    0.0, 1.56575398E-04, 3.43256425E-04, 5.54620202E-04, 8.23919506E-04, 1.13992507E-03,
    1.47640169E-03, 1.78371725E-03, 2.01182542E-03, 2.10371989E-03, 1.99454554E-03,
    1.61656283E-03, 9.02154502E-04, -1.78805361E-04, -1.64973098E-03, -3.49717454E-03,
    5.65949473E-03, 8.02941163E-03, 1.04584443E-02, 1.27472335E-02, 1.46525263E-02,
    1.59045603E-02, 1.62208471E-02, 1.53184106E-02, 1.29371806E-02, 8.85757540E-03,
    2.92408442E-03, -4.91578024E-03, -1.46404076E-02, -2.61098752E-02, -3.90751381E-02,
    -5.31873032E-02, 6.79989431E-02, 8.29847578E-02, 9.75753918E-02, 1.11196689E-01,
    1.23264548E-01, 1.33264415E-01, 1.40753505E-01, 1.45389847E-01, 1.46955068E-01,
    1.45389847E-01, 1.40753505E-01, 1.33264415E-01, 1.23264548E-01, 1.11196689E-01,
    9.75753918E-02, 8.29847578E-02, -6.79989431E-02, -5.31873032E-02, -3.90751381E-02,
    -2.61098752E-02, -1.46404076E-02, -4.91578024E-03, 2.92408442E-03, 8.85757540E-03,
    1.29371806E-02, 1.53184106E-02, 1.62208471E-02, 1.59045603E-02, 1.46525263E-02,
    1.27472335E-02, 1.04584443E-02, 8.02941163E-03, -5.65949473E-03, -3.49717454E-03,
    -1.64973098E-03, -1.78805361E-04, 9.02154502E-04, 1.61656283E-03, 1.99454554E-03,
    2.10371989E-03, 2.01182542E-03, 1.78371725E-03, 1.47640169E-03, 1.13992507E-03,
    8.23919506E-04, 5.54620202E-04, 3.43256425E-04, 1.56575398E-04)

# Loudness offsets (A2DP spec table 12.17/12.18), indexed [rate index][subband].
OFFSET4 = ((-1, 0, 0, 0), (-2, 0, 0, 1), (-2, 0, 0, 1), (-2, 0, 0, 1))
OFFSET8 = ((-2, 0, 0, 0, 0, 0, 0, 1), (-3, 0, 0, 0, 0, 0, 1, 2),
           (-4, 0, 0, 0, 0, 0, 1, 2), (-4, 0, 0, 0, 0, 0, 1, 2))


def crc8(bits):
    """SBC CRC-8: polynomial x^8+x^4+x^3+x^2+1, initial value 0x0F, over a list of bits (MSB first)."""
    crc = 0x0f
    for b in bits:
        top = (crc >> 7) & 1
        crc = (crc << 1) & 0xff
        if top ^ b:
            crc ^= 0x1d
    return crc


def _bits(value, n):
    return [(value >> (n - 1 - i)) & 1 for i in range(n)]


def frame_length(subbands, blocks, mode, bitpool):
    nch = 1 if mode == MONO else 2
    n = 4 + (4 * subbands * nch) // 8
    if mode in (MONO, DUAL_CHANNEL):
        payload = blocks * nch * bitpool
    else:
        payload = (subbands if mode == JOINT_STEREO else 0) + blocks * bitpool
    return n + (payload + 7) // 8


def bit_allocation(scale_factors, mode, subbands, rate_index, allocation, bitpool):
    """Spec 12.6.3: bits[ch][sb] from scale factors. Stereo/joint allocate both channels jointly."""
    nch = len(scale_factors)
    offs = OFFSET4 if subbands == 4 else OFFSET8

    def need(ch, sb):
        sf = scale_factors[ch][sb]
        if allocation == SNR:
            return sf
        if sf == 0:
            return -5
        loud = sf - offs[rate_index][sb]
        return loud // 2 if loud > 0 else loud

    def allocate(chans):
        cells = [(ch, sb) for sb in range(subbands) for ch in chans]   # spec order: sb outer, ch inner
        bitneed = {c: need(*c) for c in cells}
        max_need = max(bitneed.values())
        bitcount = slicecount = 0
        bitslice = max_need + 1
        while True:
            bitslice -= 1
            bitcount += slicecount
            slicecount = 0
            for c in cells:
                if bitslice + 1 < bitneed[c] < bitslice + 16:
                    slicecount += 1
                elif bitneed[c] == bitslice + 1:
                    slicecount += 2
            if bitcount + slicecount >= bitpool:
                break
        if bitcount + slicecount == bitpool:
            bitcount += slicecount
            bitslice -= 1
        bits = {c: 0 if bitneed[c] < bitslice + 2 else min(bitneed[c] - bitslice, 16) for c in cells}
        for c in cells:
            if bitcount >= bitpool:
                break
            if 2 <= bits[c] < 16:
                bits[c] += 1
                bitcount += 1
            elif bitneed[c] == bitslice + 1 and bitpool > bitcount + 1:
                bits[c] = 2
                bitcount += 2
        for c in cells:
            if bitcount >= bitpool:
                break
            if bits[c] < 16:
                bits[c] += 1
                bitcount += 1
        return bits

    out = [[0] * subbands for _ in range(nch)]
    groups = [[0], [1]] if mode == DUAL_CHANNEL else [list(range(nch))]
    for g in groups:
        for (ch, sb), b in allocate(g).items():
            out[ch][sb] = b
    return out


class _Analysis:
    """Spec 12.5.1 analysis filterbank for one channel."""

    def __init__(self, m):
        self.m = m
        self.c = PROTO_4_40 if m == 4 else PROTO_8_80
        self.x = [0.0] * (10 * m)
        self.cos = [[math.cos((i + 0.5) * (k - m / 2) * math.pi / m) for k in range(2 * m)]
                    for i in range(m)]

    def block(self, samples):
        m = self.m
        self.x = list(reversed(samples)) + self.x[:9 * m]          # newest sample first
        z = [c * x for c, x in zip(self.c, self.x)]
        y = [z[i] + z[i + 2 * m] + z[i + 4 * m] + z[i + 6 * m] + z[i + 8 * m] for i in range(2 * m)]
        return [sum(cv * yv for cv, yv in zip(row, y)) for row in self.cos]


class _Synthesis:
    """Spec 12.5.2 synthesis filterbank for one channel."""

    def __init__(self, m):
        self.m = m
        self.d = [v * -m for v in (PROTO_4_40 if m == 4 else PROTO_8_80)]
        self.v = [0.0] * (20 * m)
        self.n = [[math.cos((i + 0.5) * (k + m / 2) * math.pi / m) for i in range(m)]
                  for k in range(2 * m)]

    def block(self, s):
        m = self.m
        self.v = [sum(nv * sv for nv, sv in zip(row, s)) for row in self.n] + self.v[:18 * m]
        u = [0.0] * (10 * m)
        for i in range(5):
            for j in range(m):
                u[i * 2 * m + j] = self.v[i * 4 * m + j]
                u[i * 2 * m + m + j] = self.v[i * 4 * m + 3 * m + j]
        w = [a * b for a, b in zip(u, self.d)]
        return [sum(w[j + m * i] for i in range(10)) for j in range(m)]


class SbcEncoder:
    def __init__(self, rate=44100, channels=2, mode=JOINT_STEREO, blocks=16, subbands=8,
                 allocation=LOUDNESS, bitpool=53):
        if mode == MONO:
            channels = 1
        assert rate in RATES and blocks in BLOCKS and subbands in (4, 8)
        assert channels == (1 if mode == MONO else 2)
        self.rate, self.channels, self.mode = rate, channels, mode
        self.blocks, self.subbands, self.allocation, self.bitpool = blocks, subbands, allocation, bitpool
        self.filters = [_Analysis(subbands) for _ in range(channels)]

    @property
    def samples_per_frame(self):
        return self.blocks * self.subbands

    @property
    def frame_bytes(self):
        return frame_length(self.subbands, self.blocks, self.mode, self.bitpool)

    def encode(self, pcm):
        """pcm: one list per channel of blocks*subbands int16 values -> one SBC frame (bytes)."""
        m, nb, nch = self.subbands, self.blocks, self.channels
        sb = [[self.filters[ch].block(pcm[ch][blk * m:(blk + 1) * m]) for ch in range(nch)]
              for blk in range(nb)]                                   # sb[blk][ch][subband]

        def sf_of(values):
            peak = max(abs(v) for v in values)
            sf = 0
            while sf < 15 and peak >= (1 << (sf + 1)):
                sf += 1
            return sf

        sfs = [[sf_of([sb[blk][ch][s] for blk in range(nb)]) for s in range(m)] for ch in range(nch)]
        join = [0] * m
        if self.mode == JOINT_STEREO:
            for s in range(m - 1):
                mid = [(sb[blk][0][s] + sb[blk][1][s]) / 2 for blk in range(nb)]
                side = [(sb[blk][0][s] - sb[blk][1][s]) / 2 for blk in range(nb)]
                sm, ss = sf_of(mid), sf_of(side)
                if sm + ss < sfs[0][s] + sfs[1][s]:
                    join[s] = 1
                    sfs[0][s], sfs[1][s] = sm, ss
                    for blk in range(nb):
                        sb[blk][0][s], sb[blk][1][s] = mid[blk], side[blk]
        rate_index = RATES.index(self.rate)
        bits = bit_allocation(sfs, self.mode, m, rate_index, self.allocation, self.bitpool)

        hdr = ((rate_index << 6) | (BLOCKS.index(nb) << 4) | (self.mode << 2) |
               (self.allocation << 1) | (1 if m == 8 else 0))
        crc_bits = _bits(hdr, 8) + _bits(self.bitpool, 8)
        side = []
        if self.mode == JOINT_STEREO:
            side += join[:m - 1] + [0]
        for ch in range(nch):
            for s in range(m):
                side += _bits(sfs[ch][s], 4)
        crc = crc8(crc_bits + side)
        out = [1, 0, 0, 1, 1, 1, 0, 0] + crc_bits + _bits(crc, 8) + side
        for blk in range(nb):
            for ch in range(nch):
                for s in range(m):
                    b = bits[ch][s]
                    if b:
                        levels = (1 << b) - 1
                        scale = float(1 << (sfs[ch][s] + 1))
                        q = int((sb[blk][ch][s] / scale + 1.0) * levels / 2)
                        out += _bits(max(0, min(levels - 1, q)), b)
        out += [0] * (-len(out) % 8)
        return bytes(int(''.join(map(str, out[i:i + 8])), 2) for i in range(0, len(out), 8))


class SbcDecoder:
    def __init__(self):
        self.filters = None

    def decode(self, frame):
        """One SBC frame -> list of channels of int16 samples. Raises ValueError on a bad frame."""
        bits = []
        for byte in frame:
            bits += _bits(byte, 8)
        pos = [0]

        def take(n):
            v = 0
            for b in bits[pos[0]:pos[0] + n]:
                v = (v << 1) | b
            pos[0] += n
            return v

        if take(8) != 0x9c:
            raise ValueError('bad SBC syncword')
        rate_index, nb, mode = take(2), BLOCKS[take(2)], take(2)
        allocation, m = take(1), (8 if take(1) else 4)
        bitpool, crc = take(8), take(8)
        nch = 1 if mode == MONO else 2
        side_start = pos[0]
        join = [0] * m
        if mode == JOINT_STEREO:
            join = [take(1) for _ in range(m)]
        sfs = [[take(4) for _ in range(m)] for _ in range(nch)]
        if crc8(bits[8:24] + bits[side_start:pos[0]]) != crc:
            raise ValueError('SBC CRC mismatch')
        alloc = bit_allocation(sfs, mode, m, rate_index, allocation, bitpool)
        if self.filters is None or len(self.filters) != nch or self.filters[0].m != m:
            self.filters = [_Synthesis(m) for _ in range(nch)]
        out = [[] for _ in range(nch)]
        for _ in range(nb):
            s = [[0.0] * m for _ in range(nch)]
            for ch in range(nch):
                for k in range(m):
                    b = alloc[ch][k]
                    if b:
                        levels = (1 << b) - 1
                        s[ch][k] = (1 << (sfs[ch][k] + 1)) * ((take(b) * 2.0 + 1.0) / levels - 1.0)
            if mode == JOINT_STEREO:
                for k in range(m):
                    if join[k]:
                        s[0][k], s[1][k] = s[0][k] + s[1][k], s[0][k] - s[1][k]
            for ch in range(nch):
                out[ch] += [max(-32768, min(32767, int(round(v)))) for v in self.filters[ch].block(s[ch])]
        self.params = dict(rate=RATES[rate_index], blocks=nb, mode=mode, allocation=allocation,
                           subbands=m, bitpool=bitpool)
        return out


def main():
    """python3 -m btprofiles.sbc in.wav out.sbc [bitpool]: encode a 16-bit WAV to raw SBC frames."""
    import sys
    import wave
    src, dst = sys.argv[1], sys.argv[2]
    with wave.open(src, 'rb') as w:
        rate, nch = w.getframerate(), w.getnchannels()
        raw = w.readframes(w.getnframes())
    import struct
    vals = struct.unpack('<%dh' % (len(raw) // 2), raw)
    chans = [list(vals[c::nch]) for c in range(nch)]
    enc = SbcEncoder(rate, nch, JOINT_STEREO if nch == 2 else MONO,
                     bitpool=int(sys.argv[3]) if len(sys.argv) > 3 else (53 if nch == 2 else 31))
    n = enc.samples_per_frame
    with open(dst, 'wb') as f:
        for i in range(0, len(chans[0]) - n + 1, n):
            f.write(enc.encode([c[i:i + n] for c in chans]))


if __name__ == '__main__':
    main()
