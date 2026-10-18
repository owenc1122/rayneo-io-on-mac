"""HFP Audio Gateway driven by a scripted Hands-Free unit (the glasses' side of the RFCOMM DLC)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'scripts'))
from btprofiles import hfp  # noqa: E402

HF_FEATURES = (hfp.HF_EC_NR | hfp.HF_THREE_WAY | hfp.HF_CLI | hfp.HF_REMOTE_VOLUME |
               hfp.HF_ENHANCED_STATUS | hfp.HF_CODEC_NEGOTIATION | hfp.HF_HF_INDICATORS)


class HfpTest(unittest.TestCase):
    def setUp(self):
        self.out = b''
        self.audio = []
        self.ag = hfp.HfpAudioGateway(send=self._rx, on_audio=self.audio.append)

    def _rx(self, data):
        self.out += data

    def at(self, cmd):
        """Send one AT command (as the HF would) and return the AG's response lines."""
        self.out = b''
        self.ag.on_data(cmd.encode() + b'\r')
        return [l.decode() for l in self.out.split(b'\r\n') if l]

    def slc(self, features=HF_FEATURES):
        r = self.at('AT+BRSF=%d' % features)
        self.assertEqual(r, ['+BRSF: %d' % hfp.HfpAudioGateway.FEATURES, 'OK'])
        self.assertEqual(self.at('AT+BAC=1,2'), ['OK'])
        r = self.at('AT+CIND=?')
        self.assertTrue(r[0].startswith('+CIND: ("service",(0-1)),("call",(0-1)),("callsetup",(0-3))'))
        self.assertEqual(self.at('AT+CIND?'), ['+CIND: 1,0,0,0,5,0,5', 'OK'])
        self.assertEqual(self.at('AT+CMER=3,0,0,1'), ['OK'])
        self.assertFalse(self.ag.slc)                       # three-way + HF indicators still to come
        self.assertEqual(self.at('AT+CHLD=?'), ['+CHLD: (0,1,1x,2,2x,3)', 'OK'])
        self.assertEqual(self.at('AT+BIND=1,2'), ['OK'])
        self.assertEqual(self.at('AT+BIND=?'), ['+BIND: (1,2)', 'OK'])
        self.assertEqual(self.at('AT+BIND?'), ['+BIND: 1,1', '+BIND: 2,1', 'OK'])
        self.assertTrue(self.ag.slc)

    def test_service_level_connection(self):
        self.slc()
        self.assertEqual(self.ag.hf_codecs, [1, 2])

    def test_minimal_hf_slc(self):
        # An HF without three-way / HF indicators is connected after AT+CMER.
        self.at('AT+BRSF=0')
        self.at('AT+CIND=?')
        self.at('AT+CIND?')
        self.at('AT+CMER=3,0,0,1')
        self.assertTrue(self.ag.slc)

    def test_incoming_call_answered_on_glasses(self):
        self.slc()
        self.assertEqual(self.at('AT+CLIP=1'), ['OK'])
        self.out = b''
        self.ag.incoming_call('+15550123')
        lines = [l.decode() for l in self.out.split(b'\r\n') if l]
        self.assertEqual(lines, ['+CIEV: 3,1', 'RING', '+CLIP: "+15550123",145'])
        self.out = b''
        self.ag.ring()
        self.assertIn(b'RING', self.out)
        self.assertEqual(self.at('AT+CLCC'), ['+CLCC: 1,1,4,0,0,"+15550123",145', 'OK'])
        r = self.at('ATA')
        self.assertEqual(r, ['OK', '+CIEV: 2,1', '+CIEV: 3,0', '+BCS: 2'])   # mSBC proposed
        self.assertEqual(self.at('AT+BCS=2'), ['OK'])
        self.assertEqual(self.audio, [hfp.MSBC])
        self.assertEqual(self.at('AT+CLCC'), ['+CLCC: 1,1,0,0,0,"+15550123",145', 'OK'])
        self.assertEqual(self.at('AT+CHUP'), ['OK', '+CIEV: 2,0'])
        self.assertEqual(self.ag.calls, [])

    def test_incoming_call_rejected(self):
        self.slc()
        self.ag.incoming_call('10086')
        self.assertEqual(self.at('AT+CHUP'), ['OK', '+CIEV: 3,0'])
        self.out = b''
        self.ag.ring()
        self.assertEqual(self.out, b'')                     # nothing rings any more

    def test_outgoing_call_and_redial(self):
        self.slc()
        self.assertEqual(self.at('AT+BLDN'), ['ERROR'])
        self.assertEqual(self.at('ATD10086;'), ['OK', '+CIEV: 3,2'])
        self.out = b''
        self.ag.remote_alerting()
        self.ag.remote_answer()
        lines = [l.decode() for l in self.out.split(b'\r\n') if l]
        self.assertEqual(lines, ['+CIEV: 3,3', '+CIEV: 2,1', '+CIEV: 3,0', '+BCS: 2'])
        self.out = b''
        self.ag.remote_hangup()
        self.assertEqual(self.out, b'\r\n+CIEV: 2,0\r\n')
        self.assertEqual(self.at('AT+BLDN'), ['OK', '+CIEV: 3,2'])

    def test_call_waiting_and_hold(self):
        self.slc()
        self.at('AT+CCWA=1')
        self.ag.incoming_call('111')
        self.at('ATA')
        self.at('AT+BCS=2')
        self.out = b''
        self.ag.incoming_call('222')
        self.assertEqual([l.decode() for l in self.out.split(b'\r\n') if l], ['+CCWA: "222",129,1', '+CIEV: 3,1'])
        self.assertEqual(self.at('AT+CHLD=2'), ['OK', '+CIEV: 3,0', '+CIEV: 4,1'])
        self.assertEqual(self.at('AT+CLCC'), ['+CLCC: 1,1,1,0,0,"111",129', '+CLCC: 2,1,0,0,0,"222",129', 'OK'])
        self.assertEqual(self.at('AT+CHLD=1'), ['OK', '+CIEV: 4,0'])
        self.assertEqual([c['number'] for c in self.ag.calls], ['111'])

    def test_codec_fallback_and_volume(self):
        self.slc(features=HF_FEATURES & ~hfp.HF_CODEC_NEGOTIATION)
        self.ag.incoming_call('1')
        self.at('ATA')
        self.assertEqual(self.audio, [hfp.CVSD])            # no codec negotiation -> CVSD SCO
        self.assertEqual(self.at('AT+VGS=12'), ['OK'])
        self.assertEqual(self.ag.speaker_gain, 12)
        self.out = b''
        self.ag.set_speaker_volume(5)
        self.assertEqual(self.out, b'\r\n+VGS: 5\r\n')

    def test_indicators_and_misc(self):
        self.slc()
        self.out = b''
        self.ag.set_indicator('battchg', 2)
        self.assertEqual(self.out, b'\r\n+CIEV: 7,2\r\n')
        self.assertEqual(self.at('AT+BIA=1,1,1,1,1,1,0'), ['OK'])
        self.out = b''
        self.ag.set_indicator('battchg', 1)                 # deactivated by AT+BIA
        self.assertEqual(self.out, b'')
        self.assertEqual(self.at('AT+BIEV=2,80'), ['OK'])
        self.assertEqual(self.at('AT+COPS?'), ['+COPS: 0,0,"Virtual Carrier"', 'OK'])
        self.assertEqual(self.at('AT+CNUM'), ['+CNUM: ,"+15550100",145,,4', 'OK'])
        self.assertEqual(self.at('AT+CMEE=1'), ['OK'])
        self.assertEqual(self.at('AT+FOO'), ['+CME ERROR: 4'])
        self.assertEqual(self.at('AT+XAPL=ABCD-1234-0100,10'), ['OK'])

    def test_split_and_merged_input(self):
        self.out = b''
        self.ag.on_data(b'AT+BRS')
        self.assertEqual(self.out, b'')
        self.ag.on_data(b'F=0\rAT+CIND?\r')
        self.assertIn(b'+BRSF:', self.out)
        self.assertIn(b'+CIND: 1,0,0,0,5,0,5', self.out)


if __name__ == '__main__':
    unittest.main()
