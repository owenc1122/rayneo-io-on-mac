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
        # local_addr = glasses address as the firmware hashes it (swap order TBD; try adva-as-sent first).
        local = self.central.glasses_addr[::-1]          # == adva bytes (little-endian on the wire)
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
        if business == 0x10 and len(payload) >= 3:
            cmd = payload[0]; data = payload[3:]
            self.on_rnlink_cmd(cmd, data)

    def on_rnlink_cmd(self, cmd, data):
        if cmd == 0x11:                        # glasses dev-info reply
            info = {tag: val for tag, val in tlv_iter(data)}
            self.say('rnlink glasses dev-info %s' % {hex(t): v.hex() for t, v in info.items()})
            self.dev_info_done = True
            self.send_auth()
        elif cmd == 0x18:                      # glasses auth reply (success)
            self.authed = True
            self.say('rnlink AUTH OK, glasses reply %s' % data.hex())
        else:
            self.say('rnlink cmd 0x%02x data %s (unhandled)' % (cmd, data.hex()))
