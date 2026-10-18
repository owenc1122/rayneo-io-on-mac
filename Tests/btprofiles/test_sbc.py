"""SBC codec: filterbank reconstruction, CRC, frame layout and encode->decode round trip.

    python3 -m unittest discover Tests/btprofiles
"""
import math
import os
import random
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'scripts'))
from btprofiles import sbc  # noqa: E402


def tone(n, freq, rate, amp=12000, phase=0.0):
    return [int(amp * math.sin(2 * math.pi * freq * i / rate + phase)) for i in range(n)]


def snr_db(ref, out, delay):
    ref, out = ref[:len(ref) - delay], out[delay:]
    sig = sum(r * r for r in ref)
    err = sum((r - o) ** 2 for r, o in zip(ref, out)) or 1e-9
    return 10 * math.log10(sig / err)


def run(enc, dec, chans):
    n = enc.samples_per_frame
    out = [[] for _ in chans]
    frames = []
    for f in range(len(chans[0]) // n):
        frame = enc.encode([c[f * n:(f + 1) * n] for c in chans])
        frames.append(frame)
        for ch, samples in enumerate(dec.decode(frame)):
            out[ch] += samples
    return frames, out


class FilterbankTest(unittest.TestCase):
    def test_analysis_synthesis_reconstructs(self):
        # Unquantised analysis -> synthesis: unity gain, delay 9M+1 samples, ~65 dB (near-PR bank).
        for m in (4, 8):
            a, s = sbc._Analysis(m), sbc._Synthesis(m)
            random.seed(m)
            x = [random.uniform(-10000, 10000) for _ in range(m * 300)]
            y = []
            for b in range(len(x) // m):
                y += s.block(a.block(x[b * m:(b + 1) * m]))
            self.assertGreater(snr_db(x, y, 9 * m + 1), 60, 'subbands %d' % m)


class CodecTest(unittest.TestCase):
    def test_crc8_known_value(self):
        # header 0xbd (44.1k, 16 blocks, joint, loudness, 8 subbands) + bitpool 0x35, no side bits
        self.assertEqual(sbc.crc8(sbc._bits(0xbd, 8) + sbc._bits(0x35, 8)),
                         sbc.crc8(sbc._bits(0xbd35, 16)))
        self.assertEqual(sbc.crc8([]), 0x0f)

    def test_frame_length_formula(self):
        # 44.1 kHz joint stereo 16 blocks 8 subbands bitpool 53: the common A2DP "high quality" frame
        self.assertEqual(sbc.frame_length(8, 16, sbc.JOINT_STEREO, 53), 119)
        self.assertEqual(sbc.frame_length(8, 16, sbc.MONO, 31), 70)

    def test_header_fields(self):
        enc = sbc.SbcEncoder(44100, 2, sbc.JOINT_STEREO, 16, 8, sbc.LOUDNESS, 53)
        frame = enc.encode([[0] * 128, [0] * 128])
        self.assertEqual(frame[0], 0x9c)
        self.assertEqual(frame[1], 0b10111101)
        self.assertEqual(frame[2], 53)
        self.assertEqual(len(frame), enc.frame_bytes)

    def test_round_trip_joint_stereo(self):
        rate = 44100
        enc = sbc.SbcEncoder(rate, 2, sbc.JOINT_STEREO, 16, 8, sbc.LOUDNESS, 53)
        dec = sbc.SbcDecoder()
        left, right = tone(128 * 40, 440, rate), tone(128 * 40, 660, rate, amp=8000)
        frames, out = run(enc, dec, [left, right])
        self.assertTrue(all(len(f) == 119 for f in frames))
        self.assertEqual(dec.params['bitpool'], 53)
        for ref, got in zip((left, right), out):
            self.assertGreater(snr_db(ref, got, 73), 40)

    def test_round_trip_other_modes(self):
        for mode, nch, m, blocks, alloc, pool in ((sbc.MONO, 1, 8, 16, sbc.SNR, 31),
                                                  (sbc.STEREO, 2, 4, 8, sbc.LOUDNESS, 32),
                                                  (sbc.DUAL_CHANNEL, 2, 8, 12, sbc.SNR, 24)):
            enc = sbc.SbcEncoder(48000, nch, mode, blocks, m, alloc, pool)
            dec = sbc.SbcDecoder()
            chans = [tone(blocks * m * 30, 1000 + 300 * c, 48000) for c in range(nch)]
            frames, out = run(enc, dec, chans)
            self.assertTrue(all(len(f) == enc.frame_bytes for f in frames))
            for ref, got in zip(chans, out):
                self.assertGreater(snr_db(ref, got, 9 * m + 1), 18, 'mode %d' % mode)

    def test_corrupted_frame_rejected(self):
        enc = sbc.SbcEncoder(44100, 2, sbc.JOINT_STEREO, 16, 8, sbc.LOUDNESS, 53)
        frame = bytearray(enc.encode([tone(128, 440, 44100)] * 2))
        frame[4] ^= 0x10                                      # flip a scale-factor bit
        with self.assertRaises(ValueError):
            sbc.SbcDecoder().decode(bytes(frame))

    def test_bit_allocation_spends_bitpool(self):
        sfs = [[7, 6, 5, 4, 3, 2, 1, 0], [8, 7, 6, 5, 4, 3, 2, 1]]
        for alloc in (sbc.LOUDNESS, sbc.SNR):
            bits = sbc.bit_allocation(sfs, sbc.JOINT_STEREO, 8, 2, alloc, 35)
            total = sum(map(sum, bits))
            self.assertLessEqual(total, 35)
            self.assertGreaterEqual(total, 33)
            self.assertTrue(all(0 <= b <= 16 and b != 1 for row in bits for b in row))


if __name__ == '__main__':
    unittest.main()
