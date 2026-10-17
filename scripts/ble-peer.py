#!/usr/bin/env python3
"""Virtual BLE phone for the emulated glasses (link-layer peer of BES1700_BTController).

    scripts/ble-peer.py [--port 23600] [--log peer.log]

Start it before the emulator and set `btcRadio PeerPort <port>` (see Tests/scenarios/ble-peer.resc).
The baseband model hands every BLE advertising/connection event to this process in lock step;
this script plays the central: it answers the glasses' connectable advertising with a
CONNECT_IND, then for each connection event supplies the central's PDU and receives the
glasses' PDU. It implements the LL control procedures a phone would answer, L2CAP basic
framing, ATT MTU exchange and primary-service / characteristic discovery of the glasses'
GATT database, and answers the glasses' own GATT client requests with "attribute not found".
"""
import argparse, os, socket, struct, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rnlink

LL_VERSION_IND, LL_UNKNOWN_RSP, LL_FEATURE_REQ, LL_FEATURE_RSP = 0x0c, 0x07, 0x08, 0x09
LL_PERIPHERAL_FEATURE_REQ, LL_REJECT_EXT_IND, LL_LENGTH_REQ, LL_LENGTH_RSP = 0x0e, 0x11, 0x14, 0x15
LL_TERMINATE_IND, LL_CONNECTION_PARAM_REQ, LL_PHY_REQ = 0x02, 0x0f, 0x16
LL_NAMES = {0x00: 'CONNECTION_UPDATE_IND', 0x01: 'CHANNEL_MAP_IND', 0x02: 'TERMINATE_IND', 0x03: 'ENC_REQ',
            0x05: 'START_ENC_REQ', 0x07: 'UNKNOWN_RSP', 0x08: 'FEATURE_REQ', 0x09: 'FEATURE_RSP',
            0x0c: 'VERSION_IND', 0x0d: 'REJECT_IND', 0x0e: 'PERIPHERAL_FEATURE_REQ', 0x0f: 'CONNECTION_PARAM_REQ',
            0x11: 'REJECT_EXT_IND', 0x12: 'PING_REQ', 0x14: 'LENGTH_REQ', 0x15: 'LENGTH_RSP', 0x16: 'PHY_REQ',
            0x19: 'MIN_USED_CHANNELS_IND'}
CENTRAL_ADDR = bytes.fromhex('0100eeffc0c0')        # random static C0:C0:FF:EE:00:01 (LSB first)
IBEACON = bytes.fromhex('4c000215')


class Central:
    def __init__(self, log):
        self.log = log
        self.connected_cs = None
        self.queue = []                 # pending central PDUs: (llid, payload)
        self.rx_l2cap = b''            # reassembly of glasses -> central L2CAP
        self.mtu = 23
        self.gatt_step = 'mtu'
        self.services = []
        self.chars = []
        self.events = 0
        self.followups = []
        self.last_read = 0
        self.notify_handle = -1
        self.write_handle = -1
        self.rn_buf = b''               # rnlink GATT reassembly (glasses -> phone)
        self.rn = None                  # RnlinkPhone, attached by main()
        self.log_raw = False            # dump raw notify chunks (debug)
        self.glasses_addr = b''

    def say(self, *a):
        print(time.strftime('%H:%M:%S'), *a, file=self.log, flush=True)

    # ---- advertising -------------------------------------------------------------------------
    def on_adv(self, cs, fmt, adva, pdus):
        if self.connected_cs is not None:
            return 'NONE'
        for p in pdus:
            hdr, data = p.split(':')
            hdr = int(hdr, 16)
            data = bytes.fromhex(data)
            if hdr & 0xf != 0 or IBEACON in data:     # ADV_IND only, skip the iBeacon set
                continue
            self.say('ADV cs=%s adva=%s data=%s -> CONNECT_IND' % (cs, adva, data.hex()))
            self.connected_cs = cs
            self.glasses_addr = bytes.fromhex(adva)[::-1]   # natural order (MSB first)
            # AA, CRCInit, WinSize 2.5 ms, WinOffset 0, interval 30 ms, latency 0, timeout 32 s, all channels, hop 7.
            # The emulator runs ~1/8 real time and the firmware schedules connection anchors sparsely, so a
            # short supervision timeout drops the link (reason 8) before app data flows; use the 32 s maximum.
            ll = struct.pack('<I', 0x50654c1a) + bytes([0x55, 0x55, 0x55]) + struct.pack(
                '<BHHHH', 2, 0, 24, 0, 3200) + bytes.fromhex('ffffffff1f') + bytes([7])
            payload = CENTRAL_ADDR + bytes.fromhex(adva) + ll
            assert len(payload) == 34
            # Phone-side opening, like iOS: version exchange then ATT MTU.
            self.queue.append((3, bytes([LL_VERSION_IND, 0x0c, 0x4c, 0x00, 0x00, 0x01])))
            return 'CONNECT ' + payload.hex()
        return 'NONE'

    # ---- connection events -------------------------------------------------------------------
    def next_pdu(self):
        self.events += 1
        if not self.queue and self.gatt_step:
            self.gatt_next()
        if self.queue:
            llid, payload = self.queue.pop(0)
            return llid, payload
        return 1, b''                                   # empty PDU

    def on_glasses_pdu(self, hdr, payload):
        llid = hdr & 3
        if llid == 3 and payload:
            op = payload[0]
            self.say('glasses LL %s %s' % (LL_NAMES.get(op, hex(op)), payload[1:].hex()))
            if op == LL_VERSION_IND:
                pass
            elif op in (LL_FEATURE_REQ, LL_PERIPHERAL_FEATURE_REQ):
                self.queue.append((3, bytes([LL_FEATURE_RSP]) + bytes.fromhex('ff79010000000000')))
            elif op == LL_LENGTH_REQ:
                self.queue.append((3, bytes([LL_LENGTH_RSP]) + struct.pack('<HHHH', 251, 2120, 251, 2120)))
            elif op in (LL_CONNECTION_PARAM_REQ, LL_PHY_REQ):
                self.queue.append((3, bytes([LL_REJECT_EXT_IND, op, 0x1a])))
            elif op == LL_TERMINATE_IND:
                self.say('glasses terminated the connection, reason 0x%02x' % payload[1])
                self.connected_cs = None
            elif op in (LL_FEATURE_RSP, LL_LENGTH_RSP, LL_UNKNOWN_RSP, LL_REJECT_EXT_IND, 0x09):
                pass
            else:
                self.queue.append((3, bytes([LL_UNKNOWN_RSP, op])))
        elif llid == 2:
            self.rx_l2cap = payload
            self.l2cap_check()
        elif llid == 1 and payload:
            self.rx_l2cap += payload
            self.l2cap_check()

    def l2cap_check(self):
        if len(self.rx_l2cap) < 4:
            return
        ln, cid = struct.unpack_from('<HH', self.rx_l2cap)
        if len(self.rx_l2cap) < 4 + ln:
            return
        sdu, self.rx_l2cap = self.rx_l2cap[4:4 + ln], b''
        if cid == 4:
            self.on_att(sdu)
        elif cid == 6:
            self.say('glasses SMP %s' % sdu.hex())
            if sdu and sdu[0] == 0x0b:                    # Security Request: not answered (no pairing)
                pass
            elif sdu and sdu[0] == 0x01:                  # Pairing Request -> Pairing Not Supported
                self.send_l2cap(6, bytes([0x05, 0x05]))
        elif cid == 5:
            self.say('glasses L2CAP signalling %s' % sdu.hex())
            if sdu and sdu[0] == 0x12:                    # connection parameter update request -> accepted
                self.send_l2cap(5, bytes([0x13, sdu[1], 2, 0, 0, 0]))
        else:
            self.say('glasses L2CAP cid %d %s' % (cid, sdu.hex()))

    def send_l2cap(self, cid, sdu):
        frame = struct.pack('<HH', len(sdu), cid) + sdu
        first = True
        while frame:
            chunk, frame = frame[:27], frame[27:]
            self.queue.append((2 if first else 1, chunk))
            first = False

    # ---- ATT -----------------------------------------------------------------------------
    def on_att(self, pdu):
        op = pdu[0]
        if op == 0x02:                                    # glasses ask our MTU
            self.say('glasses ATT MTU req %d' % struct.unpack_from('<H', pdu, 1))
            self.send_l2cap(4, bytes([0x03]) + struct.pack('<H', 247))
        elif op == 0x03:
            self.mtu = min(247, struct.unpack_from('<H', pdu, 1)[0])
            self.say('ATT MTU %d' % self.mtu)
            self.gatt_step = 'services'
        elif op == 0x11:                                  # read by group type rsp
            n = pdu[1]
            for i in range(2, len(pdu), n):
                s, e = struct.unpack_from('<HH', pdu, i)
                uuid = pdu[i + 4:i + n][::-1].hex()
                self.services.append((s, e, uuid))
                self.say('service 0x%04x-0x%04x %s' % (s, e, uuid))
            self.gatt_step = 'services'
        elif op == 0x09:                                  # read by type rsp (characteristics)
            n = pdu[1]
            for i in range(2, len(pdu), n):
                h, props, vh = struct.unpack_from('<HBH', pdu, i)
                uuid = pdu[i + 5:i + n][::-1].hex()
                self.chars.append((h, props, vh, uuid))
                self.say('  characteristic 0x%04x props 0x%02x value 0x%04x %s' % (h, props, vh, uuid))
            self.gatt_step = 'chars'
        elif op == 0x01:                                  # error rsp
            req, h, err = pdu[1], struct.unpack_from('<H', pdu, 2)[0], pdu[4]
            if req == 0x10 and err == 0x0a:
                self.say('service discovery complete (%d services)' % len(self.services))
                self.gatt_step = 'chars'
            elif req == 0x08 and err == 0x0a:
                self.say('characteristic discovery complete (%d characteristics)' % len(self.chars))
                self.plan_follow_up()
            elif self.followups:
                self.say('ATT error req 0x%02x handle 0x%04x err 0x%02x' % (req, h, err))
                self.gatt_step = 'follow'
            else:
                self.say('ATT error req 0x%02x handle 0x%04x err 0x%02x' % (req, h, err))
                self.gatt_step = None
        elif op == 0x0b:
            self.say('read 0x%04x = %s' % (self.last_read, pdu[1:].hex()))
            self.gatt_step = 'follow'
        elif op == 0x13:
            self.say('write response')
            self.gatt_step = 'follow'
        elif op in (0x1b, 0x1d):
            h = struct.unpack_from('<H', pdu, 1)[0]
            if op == 0x1d:
                self.send_l2cap(4, bytes([0x1e]))
            if h == self.notify_handle:
                self.on_rnlink_chunk(pdu[3:])
            else:
                self.say('glasses %s handle 0x%04x %s' % ('notify' if op == 0x1b else 'indicate',
                                                           h, pdu[3:].hex()))
        elif op in (0x04, 0x06, 0x08, 0x0a, 0x0c, 0x10, 0x12, 0x18):   # glasses' GATT client requests
            self.say('glasses ATT request %s' % pdu.hex())
            h = struct.unpack_from('<H', pdu, 1)[0] if len(pdu) >= 3 else 0
            if op == 0x12:
                self.send_l2cap(4, bytes([0x13]))
            else:
                self.send_l2cap(4, bytes([0x01, op]) + struct.pack('<H', h) + bytes([0x0a]))
        else:
            self.say('glasses ATT %s' % pdu.hex())
        self.pending_att = False

    def plan_follow_up(self):
        # Identify the RayNeo rnlink characteristics (128-bit UUIDs): notify (props 0x30) and write.
        for h, props, vh, uuid in self.chars:
            if len(uuid) == 32 and props & 0x30:
                self.notify_handle = vh
            # Prefer the LOWEST-handle 128-bit write characteristic: the firmware accepts
            # unauthenticated rnlink writes there; the higher one needs an encrypted link.
            if len(uuid) == 32 and props & 0x0c and self.write_handle < 0:
                self.write_handle = vh
        # Subscribe only to the rnlink notify characteristic, then start the rnlink handshake.
        self.followups = [('subscribe', vh + 1, 1 if props & 0x10 else 2)
                          for h, props, vh, uuid in self.chars if len(uuid) == 32 and props & 0x30]
        self.say('rnlink notify=0x%04x write=0x%04x glasses_addr=%s' % (
            self.notify_handle, self.write_handle, self.glasses_addr.hex()))
        self.gatt_step = 'follow'

    # ---- rnlink transport ----------------------------------------------------------------------
    # The glasses interleave GATT notifications: a complete small frame can arrive between the start
    # and the continuation notifications of a larger frame. Continuation notifications never begin with
    # 0xaa55 (the payload is protobuf/JSON, bytes < 0x80), so a notification that starts with aa55 is a
    # new frame (complete, or the start of a multi-notification one) and one that does not is a
    # continuation of the pending multi-notification frame.
    def on_rnlink_chunk(self, data):
        if self.log_raw:
            self.say('raw chunk len=%d %s' % (len(data), data.hex()))
        if data[:2] != b'\xaa\x55' and self.rn_buf:          # continuation of the pending big frame
            self.rn_buf += data
            total = ((self.rn_buf[2] << 8) | self.rn_buf[3]) + 6
            if len(self.rn_buf) >= total:
                frame, self.rn_buf = self.rn_buf[:total], b''
                self._deliver(frame)
            return
        buf = data
        while len(buf) >= 6 and buf[0] == 0xaa and buf[1] == 0x55:
            total = ((buf[2] << 8) | buf[3]) + 6
            if len(buf) >= total:
                self._deliver(buf[:total]); buf = buf[total:]
            else:
                self.rn_buf = buf; return                     # start of a multi-notification frame
        if buf:
            self.say('rnlink resync, dropping %s' % buf.hex())

    def _deliver(self, frame):
        if self.rn:
            self.rn.on_frame(frame)

    def rnlink_send(self, raw):
        # Write-command (0x52, no response) the rnlink frame to the glasses in <=(mtu-3)-byte chunks;
        # 0x8005 is a write-without-response characteristic on the unauthenticated rnlink path.
        mtu = self.mtu - 3
        for i in range(0, len(raw), mtu):
            self.send_l2cap(4, bytes([0x52]) + struct.pack('<H', self.write_handle) + raw[i:i + mtu])

    def gatt_next(self):
        if getattr(self, 'pending_att', False):
            return
        if self.gatt_step == 'follow':
            if not self.followups:
                self.say('GATT client idle; starting rnlink handshake')
                self.gatt_step = None
                if self.rn:
                    self.rn.start()
                return
            step = self.followups.pop(0)
            if step[0] == 'read':
                self.last_read = step[1]
                self.send_l2cap(4, bytes([0x0a]) + struct.pack('<H', step[1]))
            else:
                self.say('subscribe CCCD 0x%04x = %d' % (step[1], step[2]))
                self.send_l2cap(4, bytes([0x12]) + struct.pack('<HH', step[1], step[2]))
            self.pending_att = True
            return
        if self.gatt_step == 'mtu':
            self.send_l2cap(4, bytes([0x02]) + struct.pack('<H', 247))
        elif self.gatt_step == 'services':
            start = self.services[-1][1] + 1 if self.services else 1
            if start > 0xffff:
                self.gatt_step = 'chars'
                return
            self.send_l2cap(4, bytes([0x10]) + struct.pack('<HHH', start, 0xffff, 0x2800))
        elif self.gatt_step == 'chars':
            start = self.chars[-1][2] + 1 if self.chars else 1
            self.send_l2cap(4, bytes([0x08]) + struct.pack('<HHH', start, 0xffff, 0x2803))
        else:
            return
        self.pending_att = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=23600)
    ap.add_argument('--log', default='-')
    ap.add_argument('--raw', action='store_true')
    a = ap.parse_args()
    log = sys.stdout if a.log == '-' else open(a.log, 'a')
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('127.0.0.1', a.port))
    srv.listen(1)
    c = Central(log)
    c.rn = rnlink.RnlinkPhone(c.say, c.rnlink_send, c)
    c.say('waiting for the emulator on port %d' % a.port)
    # Re-accept across reconnects: a dropped model connection (or a stray probe) must not kill us.
    while True:
        conn, _ = srv.accept()
        f = conn.makefile('rw', newline='\n')
        c.__init__(log); c.rn = rnlink.RnlinkPhone(c.say, c.rnlink_send, c)   # fresh per model session
        c.log_raw = a.raw
        c.say('emulator connected')
        for line in f:
            w = line.split()
            if not w:
                continue
            if w[0] == 'ADV':
                reply = c.on_adv(w[1], int(w[2]), w[3], w[4:])
            elif w[0] == 'EVT':
                if c.connected_cs is None:
                    reply = 'NONE'
                else:
                    llid, payload = c.next_pdu()
                    reply = 'RX %02x %s' % (llid, payload.hex())
            elif w[0] == 'TX':
                for p in w[2:]:
                    hdr, data = p.split(':')
                    c.on_glasses_pdu(int(hdr, 16), bytes.fromhex(data))
                reply = 'OK'
            else:
                reply = 'NONE'
            try:
                f.write(reply + '\n'); f.flush()
            except (BrokenPipeError, OSError):
                break
        c.say('emulator disconnected, waiting again')


if __name__ == '__main__':
    main()
