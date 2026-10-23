#!/usr/bin/env python3
"""Bridge a REAL phone to the emulated glasses through the Mac's Bluetooth.

    python3 tools/ble-bridge/ble-bridge.py [--port 23600] [--helper-port 23650] [--log bridge.log]

Two halves:
  * Emulator side (this script): the link-layer central of scripts/ble-peer.py (same lock-step
    protocol with BES1700_BTController: `btcRadio PeerPort <port>`). It connects to the glasses'
    advertising, negotiates MTU, discovers the GATT database, and then, instead of playing a scripted
    phone, forwards ATT traffic to/from the helper.
  * Mac side: tools/ble-bridge/BLEBridgeHelper (Swift, CoreBluetooth CBPeripheralManager). It mirrors
    the discovered services/characteristics, advertises under the glasses' name, and relays a real
    phone's reads/writes/subscriptions here; glasses notifications/indications go back to the phone.

Helper protocol: JSON lines over TCP 127.0.0.1:<helper-port> (this script listens, the helper connects).
  bridge -> helper: {"t":"db", "name":str, "adv_uuids":[str], "mtu":int,
                     "services":[{"uuid":str, "chars":[{"uuid":str, "handle":int, "props":int}]}]}
                    {"t":"notify", "handle":int, "data":hex}          (notification or indication)
                    {"t":"read_rsp", "id":int, "data":hex} | {"t":"read_rsp", "id":int, "err":int}
                    {"t":"write_rsp", "id":int} | {"t":"write_rsp", "id":int, "err":int}
                    {"t":"link", "up":bool}                              (emulated link state)
  helper -> bridge: {"t":"read", "id":int, "handle":int}
                    {"t":"write", "id":int, "handle":int, "data":hex, "rsp":bool}
                    {"t":"subscribe", "handle":int, "value":0|1|2}       (value handle; CCCD = handle+1)
                    {"t":"phone", "connected":bool}
Handles are the glasses' ATT value handles; UUIDs are lower-case hex without dashes (16-bit = 4 digits).
"""
import argparse, json, os, queue, socket, struct, sys, threading, time
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'scripts'))
import importlib.util
_spec = importlib.util.spec_from_file_location('ble_peer', os.path.join(ROOT, 'scripts', 'ble-peer.py'))
ble_peer = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(ble_peer)

# iOS centrals typically get 185; the glasses' notifications must fit the PHONE's MTU because the helper
# cannot split a notification without changing what the app receives. BRIDGE_MTU overrides.
BRIDGE_MTU = int(os.environ.get('BRIDGE_MTU', 185))
GAP_UUIDS = {'1800', '1801'}          # CoreBluetooth owns GAP/GATT services; never mirrored


class Helper:
    """The helper connection (accepted on a thread); messages in both directions are queued."""
    def __init__(self, port, say):
        self.say, self.inbox, self.sock, self.lock = say, queue.Queue(), None, threading.Lock()
        self.last_db = None
        srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(('127.0.0.1', port)); srv.listen(1)
        threading.Thread(target=self._accept, args=(srv,), daemon=True).start()

    def _accept(self, srv):
        while True:
            conn, _ = srv.accept()
            with self.lock:
                if self.sock:
                    try: self.sock.close()
                    except OSError: pass
                self.sock = conn
            self.say('helper connected')
            if self.last_db:
                self.send(self.last_db)
            buf = b''
            try:
                while True:
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    buf += chunk
                    while b'\n' in buf:
                        line, buf = buf.split(b'\n', 1)
                        if line.strip():
                            try: self.inbox.put(json.loads(line))
                            except ValueError: self.say('helper sent bad JSON %r' % line[:80])
            except OSError:
                pass
            self.say('helper disconnected')
            self.inbox.put({'t': 'phone', 'connected': False})
            with self.lock:
                if self.sock is conn: self.sock = None

    def send(self, msg):
        if msg.get('t') == 'db':
            self.last_db = msg
        with self.lock:
            if not self.sock:
                return
            try: self.sock.sendall((json.dumps(msg) + '\n').encode())
            except OSError: pass


class BridgeCentral(ble_peer.Central):
    """ble-peer's central with the scripted phone replaced by ATT forwarding."""
    def __init__(self, log, helper):
        super().__init__(log)
        self.helper = helper
        self.rn = None
        self.adv_name, self.adv_uuids = '', []
        self.ready = False
        self.att_wait = None          # outstanding helper request: ('read'|'write', id) awaiting the glasses' reply
        self.att_queue = []           # helper requests waiting for the ATT bearer
        self.subscribed = {}          # value handle -> CCCD value the phone set (replayed on a new link)
        self.drop = False

    # Advertising: remember name + 16-bit service UUIDs for the helper, then connect as ble-peer does.
    def on_adv(self, cs, fmt, adva, pdus):
        if self.connected_cs is None:
            for p in pdus:
                hdr, data = p.split(':'); hdr = int(hdr, 16); data = bytes.fromhex(data)
                if hdr & 0xf == 0 and ble_peer.IBEACON not in data:
                    self.adv_name, self.adv_uuids = parse_adv(data)
        reply = super().on_adv(cs, fmt, adva, pdus)
        if reply.startswith('CONNECT'):
            self.say('connecting to glasses "%s" uuids=%s' % (self.adv_name, self.adv_uuids))
        return reply

    def plan_follow_up(self):
        # Discovery done: publish the database, replay the phone's subscriptions, then forward.
        db = {'t': 'db', 'name': self.adv_name or 'RayNeo', 'adv_uuids': self.adv_uuids, 'mtu': self.mtu, 'services': []}
        for s, e, suuid in self.services:
            if suuid in GAP_UUIDS:
                continue
            chars = [{'uuid': u, 'handle': vh, 'props': props} for h, props, vh, u in self.chars if s <= h <= e]
            db['services'].append({'uuid': suuid, 'chars': chars})
        self.helper.send(db)
        self.followups = [('subscribe', h + 1, v) for h, v in self.subscribed.items() if v]
        self.say('database published (%d services); replaying %d subscriptions' % (len(db['services']), len(self.followups)))
        self.gatt_step = 'follow'

    def gatt_next(self):
        if self.gatt_step == 'follow' and not self.followups and not getattr(self, 'pending_att', False):
            self.gatt_step = None
            self.ready = True
            self.helper.send({'t': 'link', 'up': True})
            self.say('bridge ready')
            return
        if self.gatt_step == 'mtu':
            if getattr(self, 'pending_att', False): return
            self.send_l2cap(4, bytes([0x02]) + struct.pack('<H', BRIDGE_MTU)); self.pending_att = True
            return
        super().gatt_next()

    def next_pdu(self):
        self.pump_helper()
        if self.drop:
            self.drop = False
            self.queue = [(3, bytes([ble_peer.LL_TERMINATE_IND, 0x13]))]   # remote user terminated
            self.say('phone left: terminating the emulated link (glasses will advertise again)')
            self.connected_cs_after_drop = True
        return super().next_pdu()

    def on_glasses_pdu(self, hdr, payload):
        super().on_glasses_pdu(hdr, payload)
        if getattr(self, 'connected_cs_after_drop', False) and not self.queue:
            self.connected_cs_after_drop = False
            self.reset_link()

    def reset_link(self):
        self.connected_cs = None
        self.ready = False
        self.helper.send({'t': 'link', 'up': False})
        keep = (self.helper, self.subscribed)
        ble_peer.Central.__init__(self, self.log)
        self.helper, self.subscribed = keep
        self.rn = None; self.adv_name = ''; self.adv_uuids = []
        self.att_wait = None; self.att_queue = []; self.drop = False

    # ---- helper -> glasses ----
    def pump_helper(self):
        while True:
            try: m = self.helper.inbox.get_nowait()
            except queue.Empty: break
            t = m.get('t')
            if t == 'phone':
                was, self.phone = getattr(self, 'phone', False), bool(m.get('connected'))
                if was == self.phone:
                    continue
                self.say('phone %s' % ('connected' if self.phone else 'disconnected'))
                if was and not self.phone and self.connected_cs is not None and os.environ.get('BRIDGE_DROP_ON_LEAVE', '1') == '1':
                    self.subscribed = {}
                    self.drop = True
            elif t == 'subscribe':
                self.subscribed[int(m['handle'])] = int(m['value'])
                self.att_queue.append(m)
            elif t in ('read', 'write'):
                self.att_queue.append(m)
        if not self.ready:
            return
        # Write-without-response goes straight out; requests wait for the bearer (one at a time).
        while self.att_queue:
            m = self.att_queue[0]
            if m['t'] == 'write' and not m.get('rsp'):
                self.att_queue.pop(0)
                self.send_l2cap(4, bytes([0x52]) + struct.pack('<H', m['handle']) + bytes.fromhex(m['data']))
                continue
            if self.att_wait or getattr(self, 'pending_att', False):
                break
            self.att_queue.pop(0)
            if m['t'] == 'read':
                self.att_wait = ('read', m['id'])
                self.send_l2cap(4, bytes([0x0a]) + struct.pack('<H', m['handle']))
            elif m['t'] == 'write':
                self.att_wait = ('write', m['id'])
                self.send_l2cap(4, bytes([0x12]) + struct.pack('<H', m['handle']) + bytes.fromhex(m['data']))
            elif m['t'] == 'subscribe':
                self.att_wait = ('subscribe', None)
                self.send_l2cap(4, bytes([0x12]) + struct.pack('<HH', m['handle'] + 1, m['value']))

    # ---- glasses -> helper ----
    def on_att(self, pdu):
        op = pdu[0]
        if op == 0x02:                                   # glasses' MTU request: offer the phone-sized MTU
            self.send_l2cap(4, bytes([0x03]) + struct.pack('<H', BRIDGE_MTU))
            return
        if op == 0x03:                                   # our MTU request answered
            self.mtu = min(BRIDGE_MTU, struct.unpack_from('<H', pdu, 1)[0])
            self.say('ATT MTU %d' % self.mtu)
            self.gatt_step = 'services'; self.pending_att = False
            return
        if self.ready and op in (0x1b, 0x1d):
            h = struct.unpack_from('<H', pdu, 1)[0]
            if op == 0x1d:
                self.send_l2cap(4, bytes([0x1e]))
            self.helper.send({'t': 'notify', 'handle': h, 'data': pdu[3:].hex()})
            return
        if self.ready and self.att_wait and op in (0x0b, 0x13, 0x01):
            kind, rid = self.att_wait; self.att_wait = None
            if kind == 'read':
                self.helper.send({'t': 'read_rsp', 'id': rid, **({'data': pdu[1:].hex()} if op == 0x0b else {'err': pdu[4]})})
            elif kind == 'write':
                self.helper.send({'t': 'write_rsp', 'id': rid, **({} if op == 0x13 else {'err': pdu[4]})})
            elif op == 0x01:
                self.say('subscribe failed: err 0x%02x' % pdu[4])
            return
        super().on_att(pdu)


def parse_adv(ad):
    """(local name, [16/128-bit service UUIDs]) from advertising data AD structures."""
    name, uuids, i = '', [], 0
    while i < len(ad):
        ln = ad[i]
        if ln == 0 or i + 1 + ln > len(ad): break
        typ, val = ad[i + 1], ad[i + 2:i + 1 + ln]
        if typ in (0x08, 0x09): name = val.decode('utf-8', 'replace')
        elif typ in (0x02, 0x03): uuids += ['%04x' % struct.unpack_from('<H', val, j)[0] for j in range(0, len(val) - 1, 2)]
        elif typ in (0x06, 0x07): uuids += [val[j:j + 16][::-1].hex() for j in range(0, len(val) - 15, 16)]
        i += 1 + ln
    return name, uuids


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=23600)
    ap.add_argument('--helper-port', type=int, default=23650)
    ap.add_argument('--log', default='-')
    a = ap.parse_args()
    log = sys.stdout if a.log == '-' else open(a.log, 'a')
    say = lambda *x: print(time.strftime('%H:%M:%S'), *x, file=log, flush=True)
    helper = Helper(a.helper_port, say)
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('127.0.0.1', a.port)); srv.listen(1)
    say('bridge: emulator port %d, helper port %d' % (a.port, a.helper_port))
    while True:
        conn, _ = srv.accept()
        f = conn.makefile('rw', newline='\n')
        c = BridgeCentral(log, helper)
        c.bredr = ble_peer.bredr.ClassicPhone(say)   # classic BT stays the scripted (silent) phone
        say('emulator connected')
        for line in f:
            w = line.split()
            if not w: continue
            if w[0] == 'ADV':
                reply = c.on_adv(w[1], int(w[2]), w[3], w[4:])
            elif w[0] == 'EVT':
                if c.connected_cs is None:
                    c.pump_helper(); reply = 'NONE'
                else:
                    llid, payload = c.next_pdu(); reply = 'RX %02x %s' % (llid, payload.hex())
            elif w[0] == 'TX':
                for p in w[2:]:
                    hdr, data = p.split(':'); c.on_glasses_pdu(int(hdr, 16), bytes.fromhex(data))
                if c.connected_cs is None and c.ready:
                    c.reset_link()
                reply = 'OK'
            elif w[0] in ('PSCAN', 'ISCAN', 'SLAVE', 'CTX') or w[0].startswith('CL'):
                reply = c.bredr.on_activity(w)
            else:
                reply = 'NONE'
            try: f.write(reply + '\n'); f.flush()
            except (BrokenPipeError, OSError): break
        helper.send({'t': 'link', 'up': False})
        say('emulator disconnected, waiting again')


if __name__ == '__main__':
    main()
