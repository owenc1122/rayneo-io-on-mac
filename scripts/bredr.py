"""Classic Bluetooth (BR/EDR) side of the virtual phone: the phone is the master and pages the glasses.

The controller model (BES1700_BTController.cs AirExchangeClassic) hands every classic activity to the
peer as "<KIND> <cs> <bdaddr> link=<n> clk=<native clock> fmt=<n>" and accepts "RX <type> <lt_addr>
<payload hex>" (a packet the glasses' radio receives in that event) or "NONE".

Baseband page procedure (Core spec Vol 2 Part B 8.3), slave side as the stock rwip firmware runs it:
  page scan (PSCAN)  -> master's ID is handled by the radio; the firmware sees the master's FHS
  page response (PRESP) -> the master's first packet on the new channel is a POLL -> connection
Packet types (header TYPE field): NULL 0, POLL 1, FHS 2, DM1 3, DH1 4, ...
"""
import os

NULL, POLL, FHS, DM1, DH1 = 0, 1, 2, 3, 4

# Sync word generation (Core spec Vol 2 Part B 6.3.3.1): (64,30) expurgated block code.
_G = 0o260534236651                      # generator polynomial g(D), degree 34
_PN = 0x83848D96BBCC54FC                 # p_i = bit i of this constant


def _bits_lsb_first(value, n):
    return [(value >> i) & 1 for i in range(n)]


def sync_word(lap):
    """64-bit sync word for a 24-bit LAP, in the spec's sample-data notation (checked below)."""
    pn = [(_PN >> i) & 1 for i in range(64)]                 # p_0 .. p_63
    a = _bits_lsb_first(lap, 24)
    a += [0, 0, 1, 1, 0, 1] if a[23] == 0 else [1, 1, 0, 0, 1, 0]   # Barker extension a_24..a_29
    x = [a[i] ^ pn[34 + i] for i in range(30)]               # x~ = x XOR p_34..p_63
    # c~(D) = D^34 x~(D) mod g(D), with x~_0 the lowest-degree coefficient.
    reg = 0
    for i in range(29, -1, -1):
        reg = (reg << 1) | x[i]
    reg <<= 34
    for bit in range(63, 33, -1):
        if reg >> bit & 1:
            reg ^= _G << (bit - 34)
    c = [(reg >> i) & 1 for i in range(34)]
    s = [c[i] ^ pn[i] for i in range(34)] + [x[i] ^ pn[34 + i] for i in range(30)]
    return sum(b << (63 - i) for i, b in enumerate(s))


def fhs_payload(bdaddr, cod, lt_addr, clk, page_scan_mode=0, sr=1, eir=0):
    """18-byte FHS payload (Vol 2 Part B 6.5.1.4), little-endian bit order. clk = CLK27-2."""
    lap = int.from_bytes(bdaddr[0:3], 'little')
    uap = bdaddr[3]
    nap = int.from_bytes(bdaddr[4:6], 'little')
    parity = sync_word(lap) & ((1 << 34) - 1)
    v = parity
    v |= lap << 34
    v |= (eir & 1) << 58
    v |= (sr & 3) << 60
    v |= uap << 64
    v |= nap << 72
    v |= (cod & 0xffffff) << 88
    v |= (lt_addr & 7) << 112
    v |= (clk & 0x3ffffff) << 115
    v |= (page_scan_mode & 7) << 141
    return v.to_bytes(18, 'little')


# LMP opcodes (Core spec Vol 2 Part C 5.2)
LMP = dict(name_req=1, name_res=2, accepted=3, not_accepted=4, clkoffset_req=5, clkoffset_res=6,
           detach=7, in_rand=8, comb_key=9, unit_key=10, au_rand=11, sres=12, temp_rand=13,
           temp_key=14, encryption_mode_req=15, encryption_key_size_req=16, start_encryption_req=17,
           stop_encryption_req=18, switch_req=19, hold=20, hold_req=21, sniff_req=23, unsniff_req=24,
           park_req=25, set_broadcast_scan_window=27, modify_beacon=28, unpark_bd_addr_req=29,
           unpark_pm_addr_req=30, incr_power_req=31, decr_power_req=32, max_power=33, min_power=34,
           auto_rate=35, preferred_rate=36, version_req=37, version_res=38, features_req=39,
           features_res=40, quality_of_service=41, quality_of_service_req=42, sco_link_req=43,
           remove_sco_link_req=44, max_slot=45, max_slot_req=46, timing_accuracy_req=47,
           timing_accuracy_res=48, setup_complete=49, use_semi_permanent_key=50,
           host_connection_req=51, slot_offset=52, page_mode_req=53, page_scan_mode_req=54,
           supervision_timeout=55, test_activate=56, test_control=57, encryption_key_size_mask_req=58,
           encryption_key_size_mask_res=59, set_AFH=60, encapsulated_header=61,
           encapsulated_payload=62, simple_pairing_confirm=63, simple_pairing_number=64,
           DHkey_check=65, pause_encryption_aes_req=66)
LMP_NAMES = {v: k for k, v in LMP.items()}
# Escape-4 (opcode 127) extended opcodes
LMP_EXT = dict(accepted_ext=1, not_accepted_ext=2, features_req_ext=3, features_res_ext=4,
               clk_adj=5, clk_adj_ack=6, clk_adj_req=7, packet_type_table_req=11,
               esco_link_req=12, remove_esco_link_req=13, channel_classification_req=16,
               channel_classification=17, sniff_subrating_req=21, sniff_subrating_res=22,
               pause_encryption_req=23, resume_encryption_req=24, io_capability_req=25,
               io_capability_res=26, numeric_comparison_failed=27, passkey_failed=28,
               oob_failed=29, keypress_notification=30, power_control_req=31, power_control_res=32,
               ping_req=33, ping_res=34)
LMP_EXT_NAMES = {v: k for k, v in LMP_EXT.items()}

# Phone (master) capabilities: a typical BR/EDR + LE dual-mode smartphone controller.
PHONE_FEATURES = bytes.fromhex('bffecffedbff7b87')         # page 0 (3-slot/5-slot, EDR, SSP, LE, ...)
PHONE_FEATURES_EXT = {1: bytes.fromhex('0f00000000000000'),  # SSP host, LE host, simultaneous LE/BR, SC host
                      2: bytes.fromhex('0003000000000000')}  # ping, secure connections (controller)


def lmp_pdu(name, payload=b'', tid=0):
    if name in LMP_EXT:
        return bytes([(127 << 1) | tid, LMP_EXT[name]]) + payload
    return bytes([(LMP[name] << 1) | tid]) + payload


def lmp_decode(pdu):
    op = pdu[0] >> 1
    tid = pdu[0] & 1
    if op == 127:
        return LMP_EXT_NAMES.get(pdu[1], 'ext%d' % pdu[1]), tid, pdu[2:]
    return LMP_NAMES.get(op, 'op%d' % op), tid, pdu[1:]


class ClassicPhone:
    """Master side: pages the glasses (CLASSIC=1), then runs the ACL link: baseband ARQ is implicit
    (every packet is delivered), LMP is answered and driven here, L2CAP goes to self.on_l2cap."""

    def __init__(self, say, bdaddr=bytes.fromhex('0100eeffc0c0'), cod=0x5a020c, name=b'Virtual Phone'):
        self.say = say
        self.bdaddr = bdaddr            # little-endian (LAP first); c0:c0:ff:ee:00:01
        self.cod = cod                  # smartphone (major class phone, networking/audio/telephony)
        self.name = name
        self.lt_addr = 1
        self.clk_offset = 0x1234560     # master clock - glasses' native clock (half-slots)
        self.state = 'idle'
        self.pscans = 0
        self.enabled = bool(os.environ.get('CLASSIC'))
        self.page_at = int(os.environ.get('CLASSIC_PAGE_AT', '8'))
        self.logged = 0
        self.txq = []                   # (type, llid, payload) master packets to send
        self.lmp_done = set()
        self.setup_sent = False
        self.connected_events = 0

    # ---- air interface -------------------------------------------------------------------------
    def on_activity(self, w):
        kind = w[0]
        f = dict(x.split('=', 1) for x in w[3:] if '=' in x)
        clk = int(f.get('clk', '0'), 16)
        if kind == 'CTX':
            return self.on_glasses_tx(w)
        if self.logged < 60 and kind != 'SLAVE':
            self.say('CLASSIC %s' % ' '.join(w))
            self.logged += 1
        if not self.enabled:
            return 'NONE'
        if kind == 'PSCAN' and self.state == 'idle':
            self.pscans += 1
            if self.pscans >= self.page_at:
                # The master's ID packets reach the glasses in this window; the radio answers them and
                # the master follows with its FHS, which the firmware parses.
                master_clk = (clk + 2 + self.clk_offset) & 0x0fffffff
                fhs = fhs_payload(self.bdaddr, self.cod, self.lt_addr, master_clk >> 2)
                self.state = 'fhs_sent'
                self.say('CLASSIC page: FHS to glasses (lt_addr %d)' % self.lt_addr)
                return 'RX %x %x %s' % (FHS, 0, fhs.hex())
        if kind == 'SLAVE':
            if self.state == 'fhs_sent':
                self.say('CLASSIC page response: POLL on the new connection')
                self.state = 'connected'
                self.start_lmp()
                return 'RX %x %x' % (POLL, self.lt_addr)
            if self.state == 'connected':
                self.connected_events += 1
                if self.txq:
                    t, llid, payload = self.txq.pop(0)
                    return 'RX %x %x %x %s' % (t, self.lt_addr, llid, payload.hex())
                return 'RX %x %x' % (POLL, self.lt_addr)
        return 'NONE'

    def on_glasses_tx(self, w):
        # CTX <cs> link=<n> <type> <llid> <hex> | CTX <cs> link=<n> NULL
        if len(w) < 6:
            return 'OK'
        t, llid = int(w[3], 16), int(w[4], 16)
        data = bytes.fromhex(w[5]) if len(w) > 5 else b''
        if llid == 3:
            self.on_lmp(data)
        elif llid in (1, 2):
            self.on_acl(llid, data)
        return 'OK'

    # ---- LMP (master) --------------------------------------------------------------------------
    def send_lmp(self, name, payload=b'', tid=0):
        self.say('LMP -> %s %s' % (name, payload.hex()))
        self.txq.append((DM1, 3, lmp_pdu(name, payload, tid)))

    def start_lmp(self):
        self.send_lmp('features_req', PHONE_FEATURES)
        self.send_lmp('version_req', bytes([12]) + (0x000f).to_bytes(2, 'little') + (0x1234).to_bytes(2, 'little'))
        self.send_lmp('features_req_ext', bytes([1, 2]) + PHONE_FEATURES_EXT[1])

    def on_lmp(self, pdu):
        name, tid, p = lmp_decode(pdu)
        self.say('LMP <- %s tid=%d %s' % (name, tid, p.hex()))
        # Requests from the slave (tid 1) get answered with the same transaction id.
        if name == 'features_req':
            self.send_lmp('features_res', PHONE_FEATURES, tid)
        elif name == 'features_req_ext':
            page = p[0]
            self.send_lmp('features_res_ext', bytes([page, 2]) + PHONE_FEATURES_EXT.get(page, bytes(8)), tid)
        elif name == 'version_req':
            self.send_lmp('version_res', bytes([12]) + (0x000f).to_bytes(2, 'little') + (0x1234).to_bytes(2, 'little'), tid)
        elif name == 'name_req':
            off = p[0]
            frag = self.name[off:off + 14]
            self.send_lmp('name_res', bytes([off, len(self.name)]) + frag.ljust(14, b'\0'), tid)
        elif name == 'timing_accuracy_req':
            self.send_lmp('timing_accuracy_res', bytes([250, 10]), tid)
        elif name in ('max_slot_req', 'supervision_timeout', 'max_slot', 'auto_rate', 'preferred_rate',
                      'set_AFH', 'page_scan_mode_req', 'page_mode_req'):
            if name in ('max_slot_req', 'page_scan_mode_req', 'page_mode_req'):
                self.send_lmp('accepted', bytes([LMP[name]]), tid)
        elif name == 'clkoffset_req':
            self.send_lmp('clkoffset_res', (0).to_bytes(2, 'little'), tid)
        elif name in ('features_res', 'version_res', 'features_res_ext'):
            self.lmp_done.add(name)
            if {'features_res', 'version_res'} <= self.lmp_done and not self.setup_sent:
                self.setup_sent = True
                self.send_lmp('host_connection_req')
        elif name == 'accepted' and p and p[0] == LMP['host_connection_req']:
            self.say('LMP host connection accepted by the glasses')
            self.send_lmp('setup_complete')
        elif name == 'setup_complete':
            self.say('LMP setup complete (glasses)')
        elif name == 'power_control_req':
            self.send_lmp('power_control_res', bytes([0x00]), tid)
        elif name == 'ping_req':
            self.send_lmp('ping_res', b'', tid)
        elif name == 'channel_classification_req':
            pass
        elif name in ('accepted', 'not_accepted', 'accepted_ext', 'not_accepted_ext', 'auto_rate',
                      'preferred_rate', 'max_slot', 'max_power', 'min_power'):
            pass
        elif name == 'detach':
            self.say('LMP detach from the glasses, reason 0x%02x' % (p[0] if p else 0))
            self.state = 'idle'
            self.pscans = -10 ** 9          # do not page again in this run
        elif name in LMP_EXT:
            # Any other extended request (packet type table, sniff subrating, ...): accept it.
            self.send_lmp('accepted_ext', bytes([127, LMP_EXT[name]]), tid)
        else:
            self.send_lmp('accepted', bytes([LMP[name]]) if name in LMP else bytes([pdu[0] >> 1]), tid)

    # ---- ACL-U (L2CAP) ---------------------------------------------------------------------------
    def on_acl(self, llid, data):
        self.say('ACL <- llid %d %s' % (llid, data.hex()))


if __name__ == '__main__':
    # GIAC LAP 0x9E8B33 -> sync word 0x475C58CC73345E72 (spec sample data).
    sw = sync_word(0x9E8B33)
    print(hex(sw), 'OK' if sw == 0x475C58CC73345E72 else 'MISMATCH')
