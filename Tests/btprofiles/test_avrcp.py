"""AVRCP target driven by a scripted controller (the glasses) over AVCTP."""
import os
import struct
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'scripts'))
from btprofiles import avrcp  # noqa: E402
from btprofiles.avrcp import BT_SIG, PANEL  # noqa: E402


def avctp(label, frame, cr=0):
    return bytes([(label << 4) | (cr << 1)]) + struct.pack('>H', avrcp.PID_AVRCP) + frame


def vendor(ctype, pdu, params=b''):
    return bytes([ctype, PANEL, avrcp.VENDOR_DEPENDENT]) + BT_SIG + bytes([pdu, 0]) + \
        struct.pack('>H', len(params)) + params


def parse(pkt):
    """-> (label, cr, ctype, opcode, operands) of one AVCTP/AV-C packet from the target."""
    frame = pkt[3:]
    return pkt[0] >> 4, (pkt[0] >> 1) & 1, frame[0] & 0x0f, frame[2], frame[3:]


def vparams(ops):
    """vendor operands -> (pdu, packet type, params)"""
    return ops[3], ops[4] & 3, ops[7:7 + struct.unpack_from('>H', ops, 5)[0]]


class AvrcpTest(unittest.TestCase):
    def setUp(self):
        self.out = []
        self.keys = []
        self.tg = avrcp.AvrcpTarget(send=self.out.append, on_command=self.keys.append,
                                    title='Hello', artist='Virtual Artist', album='Demo', duration_ms=200000)

    def cmd(self, label, frame):
        self.out.clear()
        self.tg.on_data(avctp(label, frame))
        return [parse(p) for p in self.out]

    def test_unit_and_subunit_info(self):
        [(label, cr, ctype, op, ops)] = self.cmd(1, bytes([avrcp.STATUS, 0xff, avrcp.UNIT_INFO, 0xff, 0xff, 0xff, 0xff, 0xff]))
        self.assertEqual((label, cr, ctype, op), (1, 1, avrcp.STABLE, avrcp.UNIT_INFO))
        self.assertEqual(ops[1], PANEL)
        [r] = self.cmd(2, bytes([avrcp.STATUS, 0xff, avrcp.SUBUNIT_INFO, 0x07, 0xff, 0xff, 0xff, 0xff]))
        self.assertEqual(r[2], avrcp.STABLE)

    def test_pass_through_play_pause(self):
        for op, name, status in ((avrcp.OP_PLAY, 'play', 'playing'), (avrcp.OP_PAUSE, 'pause', 'paused')):
            [r] = self.cmd(3, bytes([avrcp.CONTROL, PANEL, avrcp.PASS_THROUGH, op, 0]))
            self.assertEqual((r[2], r[4][0]), (avrcp.ACCEPTED, op))
            [r] = self.cmd(3, bytes([avrcp.CONTROL, PANEL, avrcp.PASS_THROUGH, op | 0x80, 0]))  # release
            self.assertEqual(r[2], avrcp.ACCEPTED)
            self.assertEqual(self.tg.status, status)
        self.assertEqual(self.keys, ['play', 'pause'])
        [r] = self.cmd(4, bytes([avrcp.CONTROL, PANEL, avrcp.PASS_THROUGH, 0x7e, 0]))
        self.assertEqual(r[2], avrcp.NOT_IMPLEMENTED)

    def test_capabilities_and_metadata(self):
        [r] = self.cmd(5, vendor(avrcp.STATUS, avrcp.GET_CAPABILITIES, b'\x03'))
        pdu, _, p = vparams(r[4])
        self.assertEqual(p[0], 3)
        self.assertIn(avrcp.EVENT_TRACK_CHANGED, p[2:])
        self.assertIn(avrcp.EVENT_VOLUME_CHANGED, p[2:])
        req = b'\x00' * 8 + bytes([2]) + struct.pack('>II', avrcp.ATTR_TITLE, avrcp.ATTR_ARTIST)
        [r] = self.cmd(6, vendor(avrcp.STATUS, avrcp.GET_ELEMENT_ATTRIBUTES, req))
        pdu, ptype, p = vparams(r[4])
        self.assertEqual((r[2], pdu, ptype, p[0]), (avrcp.STABLE, avrcp.GET_ELEMENT_ATTRIBUTES, 0, 2))
        attr, charset, ln = struct.unpack_from('>IHH', p, 1)
        self.assertEqual((attr, charset, p[9:9 + ln]), (avrcp.ATTR_TITLE, 106, b'Hello'))
        [r] = self.cmd(7, vendor(avrcp.STATUS, avrcp.GET_ELEMENT_ATTRIBUTES, b'\x00' * 8 + b'\x00'))
        self.assertEqual(vparams(r[4])[2][0], 7)                      # all attributes
        [r] = self.cmd(8, vendor(avrcp.STATUS, avrcp.GET_PLAY_STATUS))
        length, pos, status = struct.unpack('>IIB', vparams(r[4])[2])
        self.assertEqual((length, pos, status), (200000, 0, 0))

    def test_notifications(self):
        [r] = self.cmd(9, vendor(avrcp.NOTIFY, avrcp.REGISTER_NOTIFICATION,
                                 bytes([avrcp.EVENT_PLAYBACK_STATUS_CHANGED, 0, 0, 0, 0])))
        self.assertEqual((r[2], vparams(r[4])[2]), (avrcp.INTERIM, bytes([1, 0])))
        self.cmd(10, vendor(avrcp.NOTIFY, avrcp.REGISTER_NOTIFICATION, bytes([avrcp.EVENT_TRACK_CHANGED, 0, 0, 0, 0])))
        self.out.clear()
        self.tg.set_play_status('playing')
        [r] = [parse(p) for p in self.out]
        self.assertEqual((r[0], r[2], vparams(r[4])[2]), (9, avrcp.CHANGED, bytes([1, 1])))
        self.out.clear()
        self.tg.set_play_status('paused')                              # not re-registered: silent
        self.assertEqual(self.out, [])
        self.tg.set_track(title='Second', artist='B', duration_ms=1000)
        [r] = [parse(p) for p in self.out]
        self.assertEqual((r[0], r[2], vparams(r[4])[2][0]), (10, avrcp.CHANGED, avrcp.EVENT_TRACK_CHANGED))

    def test_absolute_volume(self):
        [r] = self.cmd(11, vendor(avrcp.CONTROL, avrcp.SET_ABSOLUTE_VOLUME, bytes([0x30])))
        self.assertEqual((r[2], vparams(r[4])[2]), (avrcp.ACCEPTED, bytes([0x30])))
        self.assertEqual(self.tg.volume, 0x30)
        self.assertIn('volume:48', self.keys)
        self.cmd(12, vendor(avrcp.NOTIFY, avrcp.REGISTER_NOTIFICATION, bytes([avrcp.EVENT_VOLUME_CHANGED, 0, 0, 0, 0])))
        self.cmd(13, bytes([avrcp.CONTROL, PANEL, avrcp.PASS_THROUGH, avrcp.OP_VOLUME_UP, 0]))
        changed = [parse(p) for p in self.out][1]
        self.assertEqual((changed[2], vparams(changed[4])[2]), (avrcp.CHANGED, bytes([0x0d, 0x38])))
        # Phone as CT: SetAbsoluteVolume to the sink, and its ACCEPTED response.
        self.out.clear()
        label = self.tg.set_absolute_volume(100)
        lbl, cr, ctype, op, ops = parse(self.out[0])
        self.assertEqual((cr, ctype, vparams(ops)[0], vparams(ops)[2]), (0, avrcp.CONTROL, avrcp.SET_ABSOLUTE_VOLUME, bytes([100])))
        self.tg.on_data(avctp(label, vendor(avrcp.ACCEPTED, avrcp.SET_ABSOLUTE_VOLUME, bytes([100])), cr=1))
        self.assertEqual(self.tg.sink_volume, 100)

    def test_long_metadata_uses_continuation(self):
        self.tg.set_track(title='T' * 400, artist='A' * 300, album='B', notify=False)
        [r] = self.cmd(14, vendor(avrcp.STATUS, avrcp.GET_ELEMENT_ATTRIBUTES, b'\x00' * 9))
        pdu, ptype, first = vparams(r[4])
        self.assertEqual(ptype, 1)                                     # start
        [r] = self.cmd(15, vendor(avrcp.CONTROL, avrcp.REQUEST_CONTINUING, bytes([avrcp.GET_ELEMENT_ATTRIBUTES])))
        pdu, ptype, rest = vparams(r[4])
        self.assertEqual(ptype, 3)                                     # end
        body = first + rest
        self.assertEqual(body[0], 7)
        self.assertIn(b'T' * 400, body)
        self.assertIn(b'A' * 300, body)

    def test_errors(self):
        [r] = self.cmd(1, vendor(avrcp.STATUS, 0x77))
        self.assertEqual((r[2], vparams(r[4])[2]), (avrcp.REJECTED, bytes([avrcp.INVALID_COMMAND])))
        self.out.clear()
        self.tg.on_data(bytes([0x10]) + struct.pack('>H', 0x1234) + b'\x00')   # other profile id
        self.assertEqual(self.out[0][0] & 1, 1)                        # IPID set


if __name__ == '__main__':
    unittest.main()
