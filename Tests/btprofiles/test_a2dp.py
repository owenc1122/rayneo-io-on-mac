"""AVDTP + A2DP source against a simulated sink (the glasses), decoding the streamed SBC."""
import math
import os
import struct
import sys
import tempfile
import unittest
import wave

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'scripts'))
from btprofiles import avdtp, sbc  # noqa: E402


def write_tone_wav(path, rate=44100, seconds=1.0, freq=440, channels=2):
    n = int(rate * seconds)
    with wave.open(path, 'wb') as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(rate)
        frames = b''.join(struct.pack('<%dh' % channels, *([int(10000 * math.sin(2 * math.pi * freq * i / rate))] * channels))
                          for i in range(n))
        w.writeframes(frames)


class Sink:
    """Minimal AVDTP sink (ACP + INT): one SBC sink SEP, SEID 3."""
    SEID = 3

    def __init__(self):
        self.to_source = None
        self.sent = []
        self.label = 0
        self.config = None
        self.media = []
        self.decoder = sbc.SbcDecoder()
        self.pcm = [[], []]

    def caps(self):
        info = avdtp.sbc_codec_info((44100, 48000), (sbc.JOINT_STEREO, sbc.STEREO), (16, 8),
                                    (8,), (sbc.LOUDNESS,), 2, 53)
        return avdtp.caps_bytes({avdtp.CAT_MEDIA_TRANSPORT: b'',
                                 avdtp.CAT_MEDIA_CODEC: bytes([0, 0]) + info,
                                 avdtp.CAT_DELAY_REPORTING: b''})

    def on_signal(self, pdu):            # from the source
        label, mtype, sig, params = pdu[0] >> 4, pdu[0] & 3, pdu[1] & 0x3f, pdu[2:]
        self.sent.append((mtype, sig, params))
        if mtype != avdtp.COMMAND:
            return
        rsp = b''
        if sig == avdtp.DISCOVER:
            rsp = bytes([(self.SEID << 2), (avdtp.AUDIO << 4) | (avdtp.SINK << 3)])
        elif sig in (avdtp.GET_CAPABILITIES, avdtp.GET_ALL_CAPABILITIES):
            rsp = self.caps()
        elif sig == avdtp.SET_CONFIGURATION:
            self.config = avdtp.parse_caps(params[2:])
        self.to_source(bytes([(label << 4) | avdtp.RESPONSE_ACCEPT, sig]) + rsp)

    def command(self, sig, params=b''):
        self.label = (self.label + 1) % 16
        self.to_source(bytes([(self.label << 4) | avdtp.COMMAND, sig]) + params)

    def on_media(self, pkt):
        self.media.append(pkt)
        nframes = pkt[12] & 0x0f
        data = pkt[13:]
        for _ in range(nframes):
            d = self.decoder
            before = len(self.pcm[0])
            out = d.decode(data)
            flen = sbc.frame_length(d.params['subbands'], d.params['blocks'], d.params['mode'],
                                    d.params['bitpool'])
            data = data[flen:]
            for ch, s in enumerate(out):
                self.pcm[ch] += s
            assert len(self.pcm[0]) > before


class A2dpTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.wav = os.path.join(self.tmp.name, 'tone.wav')
        write_tone_wav(self.wav)
        self.sink = Sink()
        self.opened = []
        self.src = avdtp.A2dpSource(send=self.sink.on_signal, send_media=self.sink.on_media,
                                    open_transport=lambda: self.opened.append(True),
                                    audio=avdtp.WavSource(self.wav))
        self.sink.to_source = self.src.on_data

    def tearDown(self):
        self.tmp.cleanup()

    def test_source_sets_up_and_streams(self):
        self.src.connect()
        sigs = [s for m, s, _ in self.sink.sent if m == avdtp.COMMAND]
        self.assertEqual(sigs, [avdtp.DISCOVER, avdtp.GET_ALL_CAPABILITIES, avdtp.SET_CONFIGURATION, avdtp.OPEN])
        self.assertEqual(self.opened, [True])                      # host asked to open the media channel
        codec = avdtp.parse_sbc_info(self.sink.config[avdtp.CAT_MEDIA_CODEC][2:])
        self.assertEqual((codec['rates'], codec['modes'], codec['blocks'], codec['subbands']),
                         ([44100], [sbc.JOINT_STEREO], [16], [8]))
        self.assertIn(avdtp.CAT_DELAY_REPORTING, self.sink.config)
        self.src.transport_open()
        self.assertEqual(self.sink.sent[-1][1], avdtp.START)
        self.assertEqual(self.src.state, 'streaming')
        sent = self.src.stream(1000)                               # one second of audio
        self.assertGreaterEqual(sent, 45)                          # 7 frames (896 samples) per packet
        hdrs = [struct.unpack('>BBHII', p[:12]) for p in self.sink.media]
        self.assertTrue(all(h[0] == 0x80 and h[1] == 96 for h in hdrs))
        self.assertEqual([h[2] for h in hdrs], list(range(len(hdrs))))
        self.assertEqual(hdrs[1][3] - hdrs[0][3], 7 * 128)
        self.assertTrue(all(len(p) <= 895 for p in self.sink.media))
        # The decoded stream is the WAV's 440 Hz tone: compare to the source after the codec delay.
        ref = [int(10000 * math.sin(2 * math.pi * 440 * i / 44100)) for i in range(len(self.sink.pcm[0]))]
        d = 73
        got = self.sink.pcm[0][d:]
        err = sum((a - b) ** 2 for a, b in zip(ref, got))
        sig = sum(a * a for a in ref[:len(got)])
        self.assertGreater(10 * math.log10(sig / err), 30)

    def test_sink_initiated_setup_and_control(self):
        s = self.sink
        s.command(avdtp.DISCOVER)
        seid = s.sent[-1][2][0] >> 2
        self.assertEqual((s.sent[-1][0], seid, (s.sent[-1][2][1] >> 3) & 1), (avdtp.RESPONSE_ACCEPT, 1, avdtp.SOURCE))
        s.command(avdtp.GET_CAPABILITIES, bytes([seid << 2]))
        caps = avdtp.parse_caps(s.sent[-1][2])
        self.assertNotIn(avdtp.CAT_DELAY_REPORTING, caps)          # only in GET_ALL_CAPABILITIES
        cfg = avdtp.sbc_codec_info((48000,), (sbc.STEREO,), (8,), (8,), (sbc.LOUDNESS,), 2, 40)
        s.command(avdtp.SET_CONFIGURATION, bytes([seid << 2, Sink.SEID << 2]) +
                  avdtp.caps_bytes({avdtp.CAT_MEDIA_TRANSPORT: b'', avdtp.CAT_MEDIA_CODEC: bytes([0, 0]) + cfg}))
        self.assertEqual(s.sent[-1][0], avdtp.RESPONSE_ACCEPT)
        self.assertEqual(self.src.config['rate'], 48000)
        self.assertEqual(self.src.encoder.bitpool, 40)
        s.command(avdtp.SET_CONFIGURATION, bytes([seid << 2, Sink.SEID << 2]))
        self.assertEqual((s.sent[-1][0], s.sent[-1][2][1]), (avdtp.RESPONSE_REJECT, avdtp.SEP_IN_USE))
        s.command(avdtp.START, bytes([seid << 2]))
        self.assertEqual(s.sent[-1][0], avdtp.RESPONSE_REJECT)    # not open yet
        s.command(avdtp.OPEN, bytes([seid << 2]))
        s.command(avdtp.START, bytes([seid << 2]))
        self.assertEqual(self.src.state, 'streaming')
        self.assertGreater(self.src.stream(100), 0)
        s.command(avdtp.DELAYREPORT, bytes([seid << 2]) + struct.pack('>H', 1500))
        self.assertEqual(self.src.delay_report, 1500)
        s.command(avdtp.SUSPEND, bytes([seid << 2]))
        self.assertEqual(self.src.state, 'open')
        self.assertEqual(self.src.stream(100), 0)
        s.command(avdtp.CLOSE, bytes([seid << 2]))
        self.assertEqual(self.src.state, 'idle')

    def test_fragmented_signaling_is_reassembled(self):
        caps = self.sink.caps()
        self.src.connect()                                         # DISCOVER pending
        # Send the DISCOVER response as start + end packets instead of a single packet.
        label = self.src.label
        rsp = bytes([(Sink.SEID << 2), (avdtp.AUDIO << 4) | (avdtp.SINK << 3)])
        self.src.pending[label] = avdtp.DISCOVER
        self.sink.sent.clear()
        self.src.on_data(bytes([(label << 4) | (avdtp.START_PKT << 2) | avdtp.RESPONSE_ACCEPT, 2,
                                avdtp.DISCOVER]) + rsp[:1])
        self.src.on_data(bytes([(label << 4) | (avdtp.END_PKT << 2) | avdtp.RESPONSE_ACCEPT]) + rsp[1:])
        self.assertEqual(self.sink.sent[0][1], avdtp.GET_ALL_CAPABILITIES)
        self.assertTrue(caps)

    def test_wav_source_resamples_and_mixes(self):
        mono = os.path.join(self.tmp.name, 'mono.wav')
        write_tone_wav(mono, rate=16000, channels=1, seconds=0.1)
        src = avdtp.WavSource(mono)
        out = src.read(441, 44100, 2)
        self.assertEqual((len(out), len(out[0])), (2, 441))
        self.assertEqual(out[0], out[1])


if __name__ == '__main__':
    unittest.main()
