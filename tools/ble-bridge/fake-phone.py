#!/usr/bin/env python3
"""Test stand-in for BLEBridgeHelper + a real phone: speaks the helper protocol to ble-bridge.py and runs
the scripted rnlink phone (scripts/rnlink.py) through it. Proves the bridge's data path end to end:
    python3 tools/ble-bridge/fake-phone.py [--helper-port 23650] [--seconds 60]
Exit status 0 once the glasses answer the rnlink auth."""
import argparse, json, os, socket, sys, time
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'scripts'))
import importlib.util, rnlink
_spec = importlib.util.spec_from_file_location('ble_peer', os.path.join(ROOT, 'scripts', 'ble-peer.py'))
ble_peer = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(ble_peer)

ap = argparse.ArgumentParser(); ap.add_argument('--helper-port', type=int, default=23650); ap.add_argument('--seconds', type=float, default=60)
a = ap.parse_args()
say = lambda *x: print(time.strftime('%H:%M:%S'), 'fake-phone:', *x, flush=True)
deadline = time.time() + a.seconds
while True:
    try: s = socket.create_connection(('127.0.0.1', a.helper_port)); break
    except OSError:
        if time.time() > deadline: sys.exit('bridge not reachable')
        time.sleep(0.5)
send = lambda m: s.sendall((json.dumps(m) + '\n').encode())
pending = b''
def readline():
    global pending
    while b'\n' not in pending:
        try: chunk = s.recv(65536)
        except socket.timeout: return ''
        if not chunk: sys.exit('bridge closed')
        pending += chunk
    line, pending = pending.split(b'\n', 1)
    return line.decode()
glue = ble_peer.Central(sys.stdout)                 # only for its rnlink notification reassembly
db = None; write_h = notify_h = None; mtu = 23
def rn_send(raw):
    for i in range(0, len(raw), mtu - 3):
        send({'t': 'write', 'id': 0, 'handle': write_h, 'data': raw[i:i + mtu - 3].hex(), 'rsp': False})
glue.rn = rnlink.RnlinkPhone(lambda *x: say(*x), rn_send, glue)
s.settimeout(1)
started = False
while time.time() < deadline:
    line = readline()
    if glue.rn.authed:
        say('PASS: rnlink authenticated through the bridge'); sys.exit(0)
    if not line:
        if started: glue.rn.on_tick()
        continue
    m = json.loads(line)
    if m['t'] == 'db':
        db = m; mtu = m.get('mtu', 23)
        for sv in m['services']:
            for c in sv['chars']:
                if len(c['uuid']) == 32 and c['props'] & 0x30: notify_h = c['handle']
                if len(c['uuid']) == 32 and c['props'] & 0x0c and write_h is None: write_h = c['handle']
        say('db: %d services, notify 0x%04x write 0x%04x mtu %d name %r' % (len(m['services']), notify_h, write_h, mtu, m['name']))
        glue.glasses_addr = b''
        send({'t': 'phone', 'connected': True})
        send({'t': 'subscribe', 'handle': notify_h, 'value': 1})
    elif m['t'] == 'link' and m['up'] and db and not started:
        started = True; say('link up: starting rnlink'); glue.rn.start()
    elif m['t'] == 'notify' and m['handle'] == notify_h:
        glue.on_rnlink_chunk(bytes.fromhex(m['data']))
say('FAIL: no rnlink auth within %ss' % a.seconds); sys.exit(1)
