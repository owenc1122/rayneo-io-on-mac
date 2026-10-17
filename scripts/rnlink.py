"""rnlink wire codec for the virtual phone (derived from the stock AP firmware).

Frame on the GATT link (handle 0x8002 notify from glasses, write to 0x8005 to glasses):
    aa55 | len:u16be | ctrl:u16be | business:u8 | payload... | crc16:u16be
len counts [ctrl .. end of payload] (= total - 6); crc16 is CRC16/XMODEM (poly 0x1021,
init 0, MSB-first, no reflection) over those same bytes [offset 4 : -2].
An ACK frame is the special case business/ctrl where the whole thing is 'aa55 0004 <seq> <flag> <busid> crc'.

Inside an RNLINK (business 0x10) payload the first byte is a command; dev-info / auth use
TLV items: tag:u8 | length:u16be | value. Business ids (BUSINESS_ID_*) from the firmware table.
"""
import struct

BUSINESS = {0: 'RESERVED', 1: 'APP_MARKET', 2: 'SHORTCUTS', 3: 'GYRO_CORRECTION', 4: 'WHISPER_MODE',
            5: 'SCREEN_LOCK_TIME', 6: 'VERSION_CHECK', 7: 'ACTION_BUTTON', 8: 'STREAM_MODULE',
            9: 'FOTA_MODULE', 0xa: 'ALBUM_TRANSFER', 0xb: 'LOG_INTERFACE', 0xc: 'HEARTBEAT_CMD',
            0xd: 'VOICE_ASSISTANT_CMD', 0xe: 'RECORD_CMD', 0xf: 'LAUNCHER_CMD', 0x10: 'RNLINK',
            0x18: 'A2UI'}
NAME = {v: k for k, v in BUSINESS.items()}

_CRC = []
def _crc_table():
    if not _CRC:
        for i in range(256):
            c = i << 8
            for _ in range(8):
                c = ((c << 1) ^ 0x1021) & 0xffff if c & 0x8000 else (c << 1) & 0xffff
            _CRC.append(c)
    return _CRC

def crc16(data):
    t = _crc_table(); c = 0
    for b in data:
        c = (t[(c >> 8) ^ b] ^ ((c << 8) & 0xffff)) & 0xffff
    return c

def frame(business, payload, ctrl=0, flags=0, extra=None):
    # body = ctrl:u16be | flags:u8 | [extra:u8 if flags&2] | business:u8 | payload
    body = struct.pack('>H', ctrl & 0xffff) + bytes([flags])
    if flags & 2:
        body += bytes([extra or 0])
    body += bytes([business]) + payload
    return b'\xaa\x55' + struct.pack('>H', len(body)) + body + struct.pack('>H', crc16(body))

def parse(buf):
    """Return (business, ctrl, flags, payload, crc_ok) or None. buf is one complete frame."""
    if len(buf) < 8 or buf[0] != 0xaa or buf[1] != 0x55:
        return None
    ln = struct.unpack_from('>H', buf, 2)[0]
    if len(buf) < ln + 6:
        return None
    crc_ok = crc16(buf[4:4 + ln]) == struct.unpack_from('>H', buf, 4 + ln)[0]
    ctrl = struct.unpack_from('>H', buf, 4)[0]
    flags = buf[6]
    bus_off = 8 if flags & 2 else 7
    business = buf[bus_off]
    payload = buf[bus_off + 1:4 + ln]
    return business, ctrl, flags, payload, crc_ok

def tlv_iter(data):
    i = 0
    while i + 3 <= len(data):
        tag = data[i]; ln = struct.unpack_from('>H', data, i + 1)[0]
        yield tag, data[i + 3:i + 3 + ln]
        i += 3 + ln

def tlv(tag, value):
    return bytes([tag]) + struct.pack('>H', len(value)) + value


import hashlib

# Auth secret from the AP firmware (ptr 0x1832ef0d).
AUTH_KEY = bytes.fromhex('0712c8ad27744195de5fa1ea6d025fb8')
PHONE_ADDR = bytes.fromhex('c0c0ffee0001')      # natural order, matches the BLE central address
PHONE_NAME = b'Virtual Phone'


def rnlink_msg(cmd, data):
    """An RNLINK (business 0x10) message: cmd:u8 | len:u16be | data."""
    return bytes([cmd]) + struct.pack('>H', len(data)) + data


# ---- PbMsg (protobuf) used by the feature businesses (LAUNCHER_CMD 0xf, etc.) -------------------
# message PbMsg { uint32 version=1; uint32 type=2; string message=3; bytes data=4; uint32 sequence=5;
#                 uint32 mode=6; }  (see rnlink-proto/nopkg.proto)
def _pb_varint(buf, i):
    v = s = 0
    while True:
        b = buf[i]; v |= (b & 0x7f) << s; s += 7; i += 1
        if not b & 0x80:
            return v, i

def pb_decode(buf):
    out = {}
    i = 0
    while i < len(buf):
        key, i = _pb_varint(buf, i)
        field, wire = key >> 3, key & 7
        if wire == 0:
            out[field], i = _pb_varint(buf, i)
        elif wire == 2:
            ln, i = _pb_varint(buf, i); out[field] = buf[i:i + ln]; i += ln
        else:
            break
    return out

def pb_encode(fields):
    """fields: {num: int|bytes|str}. ints -> varint (wire 0), bytes/str -> length-delimited (wire 2)."""
    out = b''
    for num, val in fields.items():
        if isinstance(val, int):
            out += bytes([num << 3]) + _enc_varint(val)
        else:
            v = val.encode() if isinstance(val, str) else val
            out += bytes([(num << 3) | 2]) + _enc_varint(len(v)) + v
    return out

def _enc_varint(v):
    out = b''
    while True:
        b = v & 0x7f; v >>= 7
        out += bytes([b | (0x80 if v else 0)])
        if not v:
            return out

def pb_msg(type_, message=None, data=None, sequence=None, mode=None):
    f = {1: 1, 2: type_}
    if message is not None:
        f[3] = message
    if data is not None:
        f[4] = data
    if sequence is not None:
        f[5] = sequence
    if mode is not None:
        f[6] = mode
    return pb_encode(f)


class RnlinkPhone:
    """Phone-side rnlink logic: completes the dev-info + auth handshake, then services features.

    `send` writes a raw frame (bytes) to the glasses; `say` logs; `central` exposes glasses_addr.
    """

    def __init__(self, say, send, central):
        self.say, self.send, self.central = say, send, central
        self.started = False
        self.dev_info_done = False
        self.authed = False
        self.rand = bytes.fromhex('a5b4c3d2')
        self.glasses_dev_addr = b''

    # ---- outbound ----
    def tx(self, business, payload, ctrl=0):
        self.send(frame(business, payload, ctrl=ctrl))

    def start(self):
        """Kick the handshake once the GATT link is ready (called when discovery is idle)."""
        if self.started:
            return
        self.started = True
        self.say('rnlink -> dev-info (cmd 0x11)')
        self.tx(0x10, rnlink_msg(0x11, self.dev_info_tlvs()))

    def dev_info_tlvs(self):
        # Android role so the glasses use the BLE/GATT path (no iAP2/MFi).
        return (tlv(0x10, bytes([2])) + tlv(0x11, PHONE_ADDR) + tlv(0x12, PHONE_NAME) +
                tlv(0x13, bytes([2])) + tlv(0x14, b'RayNeo') + tlv(0x16, b'VirtualPhone'))

    def auth_hash(self, rand, local_addr):
        return hashlib.sha256(rand + PHONE_ADDR + local_addr + AUTH_KEY).digest()

    def send_auth(self):
        # local_addr = the glasses BLE address exactly as the firmware hashes it. The glasses report
        # that byte order in their dev-info reply (tag 0x11), which equals central.glasses_addr.
        local = self.glasses_dev_addr or self.central.glasses_addr
        h = self.auth_hash(self.rand, local)
        self.say('rnlink -> auth (cmd 0x18) rand=%s hash=%s local=%s' % (
            self.rand.hex(), h.hex(), local.hex()))
        self.tx(0x10, rnlink_msg(0x18, tlv(0x10, self.rand) + tlv(0x11, h)))

    # ---- inbound ----
    def on_frame(self, buf):
        p = parse(buf)
        if not p:
            self.say('rnlink bad frame %s' % buf.hex()); return
        business, ctrl, flags, payload, crc_ok = p
        bn = BUSINESS.get(business, '0x%02x' % business)
        self.say('rnlink <- %s ctrl=%d flags=%x %s%s' % (
            bn, ctrl, flags, payload.hex(), '' if crc_ok else ' CRC-BAD'))
        if not crc_ok:
            return                              # skip fragmented/partial frames for now
        if business == 0x10 and len(payload) >= 3:
            cmd = payload[0]; data = payload[3:]
            self.on_rnlink_cmd(cmd, data)
        elif business in (0x0f, 0x0e, 0x0d, 0x0c, 0x18):
            self.on_feature(business, payload)

    def on_feature(self, business, payload):
        pb = pb_decode(payload)
        typ = pb.get(2)
        msg = pb.get(3, b'')
        try:
            text = msg.decode()
        except Exception:
            text = msg.hex()
        self.say('rnlink %s type=%s msg=%s' % (BUSINESS.get(business, hex(business)), typ, text))
        if business != 0x0f:
            return
        # Answer the glasses' time request with the current wall-clock + timezone.
        if 'sync_time' in text:
            import json, time as _t
            off = -_t.timezone if not _t.daylight else -_t.altzone
            payload_json = json.dumps({'cmd': 'sync_time', 'payload': {
                'utc': int(_t.time()), 'offset': off, 'timezone': 'Asia/Shanghai'}})
            self.say('rnlink -> sync_time reply %s' % payload_json)
            self.tx(0x0f, pb_msg(typ or 6, message=payload_json))
        if 'current_weather_request' in text or 'current_weather' in text:
            self.push_weather()

    # ---- phone-driven features ----
    def push_weather(self, temp=23, location='Shanghai', icon=1):
        import json
        # Dashboard command (launcher receiveMessage type 0x12 -> DashboardProtocolController::decode,
        # which cJSON-parses {"cmd","payload":{value,mode,data}}; data is a nested JSON string with
        # the weather fields temp/location/icon). cmd current_weather_update -> processCurrentWeatherUpdate.
        data = json.dumps({'temp': temp, 'location': location, 'icon': icon})
        msg = json.dumps({'cmd': 'current_weather_update', 'payload': {'value': 0, 'mode': 0, 'data': data}})
        self.say('rnlink -> weather %s' % msg)
        self.tx(0x0f, pb_msg(0x12, message=msg))

    def on_rnlink_cmd(self, cmd, data):
        if cmd == 0x11:                        # glasses dev-info reply
            info = {tag: val for tag, val in tlv_iter(data)}
            self.say('rnlink glasses dev-info %s' % {hex(t): v.hex() for t, v in info.items()})
            if 0x11 in info and len(info[0x11]) == 6:
                self.glasses_dev_addr = info[0x11]
            self.dev_info_done = True
            self.send_auth()
        elif cmd == 0x18:                      # glasses auth reply (success)
            self.authed = True
            self.say('rnlink AUTH OK, glasses reply %s' % data.hex())
            self.push_weather()               # proactively fill the home-screen weather
        else:
            self.say('rnlink cmd 0x%02x data %s (unhandled)' % (cmd, data.hex()))
