"""AVRCP 1.6 target (the phone's media player) over AVCTP (L2CAP PSM 0x17, control channel).

    tg = AvrcpTarget(send=avctp_write, on_command=lambda op: ..., title='Song', artist='Artist')
    tg.on_data(pdu)                 # AVCTP PDUs from the glasses (controller)
    tg.set_track(title=..., artist=..., album=..., duration_ms=...)   # TRACK_CHANGED notification
    tg.set_play_status('playing')   # PLAYBACK_STATUS_CHANGED notification
    tg.set_absolute_volume(64)      # phone as CT for absolute volume (AVRCP 1.4+): command to the sink

Handles UNIT INFO / SUBUNIT INFO, PASS THROUGH (play, pause, stop, next, previous, volume up/down),
and the vendor-dependent (BT SIG company 0x001958) PDUs: GetCapabilities, GetElementAttributes
(with continuation for long responses), GetPlayStatus, RegisterNotification (interim + changed),
SetAbsoluteVolume, InformDisplayableCharacterSet / InformBatteryStatus, SetAddressedPlayer,
List/GetCurrent player application settings (none).
"""
import struct

PID_AVRCP = 0x110E
CONTROL, STATUS, SPECIFIC_INQUIRY, NOTIFY, GENERAL_INQUIRY = 0, 1, 2, 3, 4
NOT_IMPLEMENTED, ACCEPTED, REJECTED, IN_TRANSITION, STABLE, CHANGED, INTERIM = 8, 9, 10, 11, 12, 13, 15
PANEL = (0x09 << 3) | 0
UNIT_INFO, SUBUNIT_INFO, PASS_THROUGH, VENDOR_DEPENDENT = 0x30, 0x31, 0x7C, 0x00
BT_SIG = b'\x00\x19\x58'

GET_CAPABILITIES, LIST_APP_SETTING_ATTRS, GET_CURRENT_APP_SETTING = 0x10, 0x11, 0x13
INFORM_DISPLAYABLE_CHARSET, INFORM_BATTERY_STATUS = 0x17, 0x18
GET_ELEMENT_ATTRIBUTES, GET_PLAY_STATUS, REGISTER_NOTIFICATION = 0x20, 0x30, 0x31
REQUEST_CONTINUING, ABORT_CONTINUING, SET_ABSOLUTE_VOLUME, SET_ADDRESSED_PLAYER = 0x40, 0x41, 0x50, 0x60

EVENT_PLAYBACK_STATUS_CHANGED, EVENT_TRACK_CHANGED, EVENT_TRACK_REACHED_END, EVENT_TRACK_REACHED_START, \
    EVENT_PLAYBACK_POS_CHANGED = 1, 2, 3, 4, 5
EVENT_VOLUME_CHANGED = 0x0d
SUPPORTED_EVENTS = (EVENT_PLAYBACK_STATUS_CHANGED, EVENT_TRACK_CHANGED, EVENT_TRACK_REACHED_END,
                    EVENT_TRACK_REACHED_START, EVENT_PLAYBACK_POS_CHANGED, EVENT_VOLUME_CHANGED)
ATTR_TITLE, ATTR_ARTIST, ATTR_ALBUM, ATTR_TRACK_NUMBER, ATTR_TOTAL_TRACKS, ATTR_GENRE, ATTR_PLAYING_TIME = \
    1, 2, 3, 4, 5, 6, 7
PLAY_STATUS = {'stopped': 0, 'playing': 1, 'paused': 2, 'fwd_seek': 3, 'rev_seek': 4, 'error': 0xff}
OP_VOLUME_UP, OP_VOLUME_DOWN, OP_PLAY, OP_STOP, OP_PAUSE, OP_FORWARD, OP_BACKWARD = \
    0x41, 0x42, 0x44, 0x45, 0x46, 0x4B, 0x4C
OP_NAMES = {OP_VOLUME_UP: 'volume_up', OP_VOLUME_DOWN: 'volume_down', OP_PLAY: 'play', OP_STOP: 'stop',
            OP_PAUSE: 'pause', OP_FORWARD: 'next', OP_BACKWARD: 'previous'}
# AVRCP status codes (error responses carry one byte)
INVALID_COMMAND, INVALID_PARAMETER, PARAMETER_NOT_FOUND, INTERNAL_ERROR = 0, 1, 2, 3
MAX_AVC = 512                        # AV/C frame limit on the control channel (AVRCP 6.15.2)


class AvrcpTarget:
    def __init__(self, send, on_command=None, say=None, title='Virtual Track', artist='Virtual Artist',
                 album='Virtual Album', genre='', track_number=1, total_tracks=1, duration_ms=180000):
        self.send = send
        self.on_command = on_command            # callback(op_name) for pass-through key presses
        self.say = say or (lambda *_: None)
        self.track = {}
        self.set_track(title, artist, album, genre, track_number, total_tracks, duration_ms, notify=False)
        self.status = 'stopped'
        self.position_ms = 0
        self.volume = 0x40                      # absolute volume 0..0x7f
        self.registered = {}                    # event id -> transaction label (interim sent)
        self.continuation = None                # (pdu id, remaining bytes)
        self.ct_label = 0
        self.ct_pending = {}
        self.sink_volume = None                 # last volume the sink reported (CT side)
        self.battery = None
        self.rx_frag = None

    # ---- AVCTP framing ----
    def _avctp(self, label, cr, payload):
        # transaction label | packet type single (0) | C/R | IPID 0, then the AVRCP profile id
        self.send(bytes([(label << 4) | (cr << 1)]) + struct.pack('>H', PID_AVRCP) + payload)

    def _respond(self, label, ctype, subunit, opcode, operands):
        self._avctp(label, 1, bytes([ctype, subunit, opcode]) + operands)

    def _vendor(self, label, ctype, pdu, params, packet_type=0):
        body = BT_SIG + bytes([pdu, packet_type]) + struct.pack('>H', len(params)) + params
        self._respond(label, ctype, PANEL, VENDOR_DEPENDENT, body)

    def _vendor_error(self, label, pdu, code):
        self._vendor(label, REJECTED, pdu, bytes([code]))

    def on_data(self, pdu):
        if len(pdu) < 3:
            return
        label, ptype, cr, ipid = pdu[0] >> 4, (pdu[0] >> 2) & 3, (pdu[0] >> 1) & 1, pdu[0] & 1
        if ptype != 0:                          # fragmented AVCTP messages: reassemble
            if ptype == 1:
                self.rx_frag = bytearray(pdu[:1]) + pdu[2:]       # drop the start packet's count byte
                return
            if self.rx_frag is None:
                return
            self.rx_frag += pdu[1:]
            if ptype == 2:
                return
            pdu, self.rx_frag = bytes(self.rx_frag), None
        pid = struct.unpack_from('>H', pdu, 1)[0]
        if pid != PID_AVRCP:
            self._avctp_ipid(label)
            return
        frame = pdu[3:]
        if cr:
            self.on_response(label, frame)
        else:
            self.on_command_frame(label, frame)

    def _avctp_ipid(self, label):
        self.send(bytes([(label << 4) | 0x03]) + struct.pack('>H', PID_AVRCP))

    # ---- commands from the controller (the glasses) ----
    def on_command_frame(self, label, frame):
        ctype, subunit, opcode, ops = frame[0] & 0x0f, frame[1], frame[2], frame[3:]
        if opcode == UNIT_INFO:
            self._respond(label, STABLE, 0xff, UNIT_INFO, bytes([0x07, PANEL]) + BT_SIG)
        elif opcode == SUBUNIT_INFO:
            self._respond(label, STABLE, 0xff, SUBUNIT_INFO, bytes([0x07, PANEL, 0xff, 0xff, 0xff]))
        elif opcode == PASS_THROUGH:
            op, released = ops[0] & 0x7f, bool(ops[0] & 0x80)
            name = OP_NAMES.get(op)
            if name is None:
                self._respond(label, NOT_IMPLEMENTED, subunit, opcode, ops)
                return
            self._respond(label, ACCEPTED, subunit, opcode, ops)
            if not released:                    # act on press, ignore the release
                self.say('AVRCP <- pass-through %s' % name)
                self._apply_key(name)
        elif opcode == VENDOR_DEPENDENT and ops[:3] == BT_SIG:
            pdu_id, plen = ops[3], struct.unpack_from('>H', ops, 5)[0]
            self.on_vendor(label, ctype, pdu_id, ops[7:7 + plen])
        else:
            self._respond(label, NOT_IMPLEMENTED, subunit, opcode, ops)

    def _apply_key(self, name):
        if name == 'play':
            self.set_play_status('playing')
        elif name == 'pause':
            self.set_play_status('paused')
        elif name == 'stop':
            self.set_play_status('stopped')
        elif name == 'volume_up':
            self._local_volume(min(0x7f, self.volume + 8))
        elif name == 'volume_down':
            self._local_volume(max(0, self.volume - 8))
        if self.on_command:
            self.on_command(name)

    def on_vendor(self, label, ctype, pdu_id, params):
        self.say('AVRCP <- PDU 0x%02x %s' % (pdu_id, params.hex()))
        if pdu_id == GET_CAPABILITIES:
            if params[:1] == b'\x02':
                self._vendor(label, STABLE, pdu_id, bytes([2, 1]) + BT_SIG)
            elif params[:1] == b'\x03':
                self._vendor(label, STABLE, pdu_id, bytes([3, len(SUPPORTED_EVENTS)]) + bytes(SUPPORTED_EVENTS))
            else:
                self._vendor_error(label, pdu_id, INVALID_PARAMETER)
        elif pdu_id == GET_ELEMENT_ATTRIBUTES:
            n = params[8] if len(params) > 8 else 0
            wanted = [struct.unpack_from('>I', params, 9 + 4 * i)[0] for i in range(n)] or list(range(1, 8))
            body = bytearray()
            count = 0
            for a in wanted:
                if a in self.track:
                    v = self.track[a].encode()
                    body += struct.pack('>IHH', a, 106, len(v)) + v      # charset 106 = UTF-8
                    count += 1
            self._send_long(label, pdu_id, bytes([count]) + bytes(body))
        elif pdu_id == REQUEST_CONTINUING:
            if self.continuation and self.continuation[0] == params[0]:
                self._send_long(label, params[0], self.continuation[1], continuing=True)
            else:
                self._vendor_error(label, pdu_id, INVALID_PARAMETER)
        elif pdu_id == ABORT_CONTINUING:
            self.continuation = None
            self._vendor(label, ACCEPTED, pdu_id, b'')
        elif pdu_id == GET_PLAY_STATUS:
            length = int(self.track.get(ATTR_PLAYING_TIME, '0') or 0)
            self._vendor(label, STABLE, pdu_id, struct.pack('>IIB', length, self.position_ms,
                                                            PLAY_STATUS[self.status]))
        elif pdu_id == REGISTER_NOTIFICATION:
            event = params[0]
            if event not in SUPPORTED_EVENTS:
                return self._vendor_error(label, pdu_id, INVALID_PARAMETER)
            self.registered[event] = label
            self._vendor(label, INTERIM, pdu_id, self._event_payload(event))
        elif pdu_id == SET_ABSOLUTE_VOLUME:
            vol = params[0] & 0x7f
            self.volume = vol
            self.say('AVRCP absolute volume %d' % vol)
            self._vendor(label, ACCEPTED, pdu_id, bytes([vol]))
            if self.on_command:
                self.on_command('volume:%d' % vol)
        elif pdu_id == INFORM_DISPLAYABLE_CHARSET:
            self._vendor(label, ACCEPTED, pdu_id, b'')
        elif pdu_id == INFORM_BATTERY_STATUS:
            self.battery = params[0] if params else None
            self._vendor(label, ACCEPTED, pdu_id, b'')
        elif pdu_id == SET_ADDRESSED_PLAYER:
            self._vendor(label, ACCEPTED, pdu_id, bytes([0x04]))           # status: operation completed
        elif pdu_id == LIST_APP_SETTING_ATTRS:
            self._vendor(label, STABLE, pdu_id, bytes([0]))
        elif pdu_id == GET_CURRENT_APP_SETTING:
            self._vendor(label, STABLE, pdu_id, bytes([0]))
        else:
            self._vendor_error(label, pdu_id, INVALID_COMMAND)

    def _send_long(self, label, pdu_id, params, continuing=False):
        """Responses longer than one AV/C frame go out as start/continue/end packets (AVRCP 6.8)."""
        room = MAX_AVC - 3 - 7                   # ctype/subunit/opcode + company/pdu/type/len
        if len(params) <= room and not continuing:
            self.continuation = None
            return self._vendor(label, STABLE, pdu_id, params)
        chunk, rest = params[:room], params[room:]
        ptype = (2 if rest else 3) if continuing else 1      # start / continue / end
        self.continuation = (pdu_id, rest) if rest else None
        self._vendor(label, STABLE, pdu_id, chunk, packet_type=ptype)

    def _event_payload(self, event):
        if event == EVENT_PLAYBACK_STATUS_CHANGED:
            return bytes([event, PLAY_STATUS[self.status]])
        if event == EVENT_TRACK_CHANGED:
            # Identifier 0 = a track is selected (no browsing), 0xffff... = none
            return bytes([event]) + (b'\x00' * 8 if self.track.get(ATTR_TITLE) else b'\xff' * 8)
        if event == EVENT_PLAYBACK_POS_CHANGED:
            return bytes([event]) + struct.pack('>I', self.position_ms)
        if event == EVENT_VOLUME_CHANGED:
            return bytes([event, self.volume & 0x7f])
        return bytes([event])

    def _notify(self, event):
        label = self.registered.pop(event, None)
        if label is not None:                    # a notification fires once; the CT re-registers
            self._vendor(label, CHANGED, REGISTER_NOTIFICATION, self._event_payload(event))

    # ---- phone-side state changes ----
    def set_track(self, title='', artist='', album='', genre='', track_number=1, total_tracks=1,
                  duration_ms=0, notify=True):
        self.track = {ATTR_TITLE: title, ATTR_ARTIST: artist, ATTR_ALBUM: album,
                      ATTR_TRACK_NUMBER: str(track_number), ATTR_TOTAL_TRACKS: str(total_tracks),
                      ATTR_GENRE: genre, ATTR_PLAYING_TIME: str(duration_ms)}
        self.position_ms = 0
        if notify:
            self._notify(EVENT_TRACK_CHANGED)

    def set_play_status(self, status):
        if status != self.status:
            self.status = status
            self._notify(EVENT_PLAYBACK_STATUS_CHANGED)

    def set_position(self, ms):
        self.position_ms = ms
        self._notify(EVENT_PLAYBACK_POS_CHANGED)

    def _local_volume(self, vol):
        self.volume = vol
        self._notify(EVENT_VOLUME_CHANGED)

    # ---- phone as controller for absolute volume (AVRCP 1.4+: the sink renders the volume) ----
    def set_absolute_volume(self, vol):
        self.ct_label = (self.ct_label + 1) % 16
        self.ct_pending[self.ct_label] = SET_ABSOLUTE_VOLUME
        params = bytes([vol & 0x7f])
        body = BT_SIG + bytes([SET_ABSOLUTE_VOLUME, 0]) + struct.pack('>H', len(params)) + params
        self._avctp(self.ct_label, 0, bytes([CONTROL, PANEL, VENDOR_DEPENDENT]) + body)
        return self.ct_label

    def register_sink_volume(self):
        self.ct_label = (self.ct_label + 1) % 16
        self.ct_pending[self.ct_label] = REGISTER_NOTIFICATION
        params = bytes([EVENT_VOLUME_CHANGED, 0, 0, 0, 0])
        body = BT_SIG + bytes([REGISTER_NOTIFICATION, 0]) + struct.pack('>H', len(params)) + params
        self._avctp(self.ct_label, 0, bytes([NOTIFY, PANEL, VENDOR_DEPENDENT]) + body)

    def on_response(self, label, frame):
        ctype, ops = frame[0] & 0x0f, frame[3:]
        if frame[2] != VENDOR_DEPENDENT or ops[:3] != BT_SIG:
            return
        pdu_id, plen = ops[3], struct.unpack_from('>H', ops, 5)[0]
        params = ops[7:7 + plen]
        if pdu_id == SET_ABSOLUTE_VOLUME and ctype == ACCEPTED:
            self.sink_volume = params[0] & 0x7f
        elif pdu_id == REGISTER_NOTIFICATION and params[:1] == bytes([EVENT_VOLUME_CHANGED]):
            self.sink_volume = params[1] & 0x7f
            if ctype == CHANGED:
                self.register_sink_volume()
        self.ct_pending.pop(label, None)
        self.say('AVRCP <- response 0x%02x ctype %d %s' % (pdu_id, ctype, params.hex()))
