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
import struct
import ssp

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

# RFCOMM server channels the phone (AG/target) advertises over SDP; rnlink SPP is channel 26.
HFP_AG_CHANNEL = 13


# ---- SDP data elements and a tiny SDP server (Core spec Vol 3 Part B 3.3, 4.x) -------------------
def de_uint(v, size):                                       # unsigned int element (type 1)
    return bytes([(1 << 3) | {1: 0, 2: 1, 4: 2, 8: 3}[size]]) + int(v).to_bytes(size, 'big')


def de_uuid16(v):                                           # 16-bit UUID element (type 3)
    return bytes([(3 << 3) | 1]) + int(v).to_bytes(2, 'big')


def de_str(s):                                              # text string element (type 4, 8-bit len)
    b = s.encode()
    return bytes([(4 << 3) | 5, len(b)]) + b


def de_seq(items):                                          # data-element sequence (type 6, 8-bit len)
    body = b''.join(items)
    return bytes([(6 << 3) | 5, len(body)]) + body


def sdp_parse(data, i=0):
    """Read one SDP data element at offset i -> (type, value_bytes, next_index)."""
    b = data[i]
    typ, sz = b >> 3, b & 7
    i += 1
    if sz < 5:
        ln = (1, 2, 4, 8, 16)[sz]
    elif sz == 5:
        ln = data[i]; i += 1
    elif sz == 6:
        ln = struct.unpack_from('>H', data, i)[0]; i += 2
    else:
        ln = struct.unpack_from('>I', data, i)[0]; i += 4
    return typ, data[i:i + ln], i + ln


def sdp_uuids(seqval):                                      # 16-bit UUIDs inside a sequence element
    out, i = [], 0
    while i < len(seqval):
        typ, val, i = sdp_parse(seqval, i)
        if typ == 3 and len(val) == 2:
            out.append(int.from_bytes(val, 'big'))
    return out


def sdp_attr_ranges(seqval):                                # requested attribute id ranges
    rs, i = [], 0
    while i < len(seqval):
        typ, val, i = sdp_parse(seqval, i)
        if typ == 1 and len(val) == 2:
            a = int.from_bytes(val, 'big'); rs.append((a, a))
        elif typ == 1 and len(val) == 4:
            v = int.from_bytes(val, 'big'); rs.append((v >> 16, v & 0xffff))
    return rs or [(0, 0xffff)]


def a2dp_source_record():
    """A2DP Audio Source service record (AVDTP on L2CAP PSM 0x0019)."""
    return [
        (0x0000, de_uint(0x00010002, 4)),
        (0x0001, de_seq([de_uuid16(0x110A)])),                              # AudioSource
        (0x0004, de_seq([de_seq([de_uuid16(0x0100), de_uint(0x0019, 2)]),   # L2CAP, PSM 0x0019
                         de_seq([de_uuid16(0x0019), de_uint(0x0103, 2)])])),  # AVDTP v1.3
        (0x0005, de_seq([de_uuid16(0x1002)])),                              # PublicBrowseRoot
        (0x0009, de_seq([de_seq([de_uuid16(0x110D), de_uint(0x0103, 2)])])),  # A2DP v1.3
        (0x0311, de_uint(0x0001, 2)),                                       # supported features
    ]


def avrcp_target_record():
    """AVRCP Target service record (AVCTP on L2CAP PSM 0x0017)."""
    return [
        (0x0000, de_uint(0x00010003, 4)),
        (0x0001, de_seq([de_uuid16(0x110C)])),                              # AV_RemoteControlTarget
        (0x0004, de_seq([de_seq([de_uuid16(0x0100), de_uint(0x0017, 2)]),   # L2CAP, PSM 0x0017 (AVCTP)
                         de_seq([de_uuid16(0x0017), de_uint(0x0104, 2)])])),  # AVCTP v1.4
        (0x0005, de_seq([de_uuid16(0x1002)])),
        (0x0009, de_seq([de_seq([de_uuid16(0x110E), de_uint(0x0106, 2)])])),  # AVRCP v1.6
        (0x0311, de_uint(0x00b2, 2)),                                       # category 1+2, player/settings
    ]


def hfp_ag_record(channel, features=0x0023):
    """HFP Audio Gateway service record (attr id -> element). features: SDP supported-features
    bitmap (bit0 three-way, bit1 EC/NR, bit5 wide-band speech)."""
    return [
        (0x0000, de_uint(0x00010001, 4)),                                   # ServiceRecordHandle
        (0x0001, de_seq([de_uuid16(0x111F), de_uuid16(0x1203)])),           # HF-AG + GenericAudio
        (0x0004, de_seq([de_seq([de_uuid16(0x0100)]),                       # L2CAP
                         de_seq([de_uuid16(0x0003), de_uint(channel, 1)])])),  # RFCOMM + channel
        (0x0005, de_seq([de_uuid16(0x1002)])),                              # PublicBrowseRoot
        (0x0009, de_seq([de_seq([de_uuid16(0x111E), de_uint(0x0108, 2)])])),  # Handsfree v1.8
        (0x0100, de_str('Voice gateway')),                                  # ServiceName
        (0x0301, de_uint(0x01, 1)),                                         # Network: can reject a call
        (0x0311, de_uint(features, 2)),                                     # SupportedFeatures
    ]


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
        self.channels = {}
        self.profiles_started = False
        self.ssp = None
        self.paired = False
        self.pk_frags_out = []
        self.sweep = os.environ.get('SSP_SWEEP')
        self.variants = ['', 'd', 'i', 'a', 'b', 'n', 'o', 'ab', 'db', 'ib', 'nb', 'na',
                         'di', 'dab', 'nab', 'oab', 'oi', 'on', 'dn', 'iab', 'dib', 'ndab']
        self.vi = 0
        self.on_spp_open = None         # callback(phone) when the rnlink SPP channel is up
        self.on_spp_data = None         # callback(bytes) for data from the glasses on SPP
        self.on_tick = None             # periodic phone-side work while connected
        self.served = {0x0001: self.on_sdp_server}   # PSMs the phone answers (glasses-initiated)
        self.served_open = {}           # PSM -> on_open(scid) for accepted incoming channels
        self._out_cid = 0x0040          # monotonic CID allocator for outgoing (phone-initiated) channels
        self._in_cid = 0x0080           # local CID allocator for incoming (glasses-initiated) channels
        self.dlcs = {}                  # RFCOMM DLCI -> per-DLC state (shared mux, several channels)
        self.rfcomm_mux_up = False      # RFCOMM control channel (DLCI 0) established
        self.pending_dlc = None         # DLCI waiting for the mux to come up
        self.spp_dlci = None            # rnlink SPP DLC (channel 26)
        self.hfp = None                 # HFP Audio Gateway, bound once its DLC (glasses HF channel) opens
        self.on_hf_channel = None       # callback(channel) once the glasses' HF RFCOMM channel is known
        self.a2dp = None                # A2DP source (AVDTP, L2CAP PSM 0x19)
        self.avrcp = None               # AVRCP target (AVCTP, L2CAP PSM 0x17)
        self.sco_codec = 2              # HFP (e)SCO: 2 = mSBC (wide band), 1 = CVSD
        self.sco_len = 60               # SCO frame bytes per 7.5 ms
        self.sco_active = False         # (e)SCO link established

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
                if self.on_tick and self.connected_events % 16 == 0:
                    self.on_tick()
                if self.hfp and self.hfp.slc and self.connected_events % 16 == 0:
                    if not getattr(self, 'hfp_call_made', False):
                        self.hfp_call_made = True
                        self.say('HFP SLC up -> raising incoming call +15550123')
                        self.hfp.incoming_call('+15550123')
                        if os.environ.get('SCO_AUDIO'):         # in-band ring: open SCO during RING
                            self.hfp.connect_audio()
                    elif self.hfp.ind.get('callsetup'):         # keep ringing until answered/screenshot
                        self.hfp.ring()
                if self.a2dp and self.a2dp.state == 'streaming' and self.connected_events % 3 == 0:
                    self.a2dp.stream(40)                        # pump ~40 ms of SBC media per few events
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
        elif name == 'accepted' and p and p[0] == LMP['encryption_mode_req']:
            self.enc_step = 'size'
            self.send_lmp('encryption_key_size_req', bytes([16]))
        elif name == 'accepted' and p and p[0] == LMP['encryption_key_size_req']:
            self.enc_step = 'start'
            import os as _os
            self.send_lmp('start_encryption_req', _os.urandom(16))
        elif name == 'accepted' and p and p[0] == LMP['start_encryption_req']:
            self.say('link encryption enabled; opening services')
            self.start_profiles_once()
        elif name == 'accepted' and p and p[0] == LMP['host_connection_req']:
            self.say('LMP host connection accepted by the glasses')
            self.send_lmp('setup_complete')
        elif name == 'accepted' and p and p[0] == LMP['encapsulated_header'] and self.pk_frags_out:
            for frag in self.pk_frags_out:
                self.send_lmp('encapsulated_payload', frag.ljust(16, b'\0'))
            self.pk_frags_out = []
        elif name == 'setup_complete':
            self.say('LMP setup complete (glasses)')
            if os.environ.get('SSP_RESPONDER'):
                if not self.profiles_started:
                    self.profiles_started = True
                    self.start_profiles()
            elif not self.paired and self.ssp is None:
                self.start_pairing()
        # ---- SSP (Just Works, P-192) ----
        elif name == 'io_capability_req':
            self.say('SSP <- io_cap_req (glasses initiate) io=%d oob=%d auth=%d' % (p[0], p[1], p[2]))
            self.ssp = ssp.SspJustWorks(self.bdaddr[::-1], bytes.fromhex('554433221100'))
            self.ssp.io_b = bytes([p[0], p[1], p[2]])   # initiator (glasses) io caps
            self.ssp_responder = True
            self.send_lmp('io_capability_res', bytes([0x03, 0x00, 0x00]))
        elif name == 'io_capability_res':
            # ext payload: IO_cap(1) OOB(1) AuthReq(1)
            self.ssp.io_b = bytes([p[2], p[1], p[0]])
            self.say('SSP <- io_cap_res io=%d oob=%d auth=%d' % (p[0], p[1], p[2]))
            self.send_pubkey()
        elif name == 'encapsulated_header':
            self.pk_in = b''
            self.send_lmp('accepted', bytes([LMP['encapsulated_header']]), tid)
        elif name == 'encapsulated_payload':
            self.pk_in += p[:16]
            self.send_lmp('accepted', bytes([LMP['encapsulated_payload']]), tid)
            if len(self.pk_in) >= 48:
                self.ssp.set_air_pk_b(self.pk_in[:48])
                self.say('SSP <- peer public key')
        elif name == 'simple_pairing_confirm':
            self.ssp.set_air_cb(p[:16])
            self.say('SSP <- confirm (Cb)')
            self.send_lmp('simple_pairing_number', self.ssp.air_na())   # initiator reveals Na
        elif name == 'simple_pairing_number':
            self.ssp.set_air_nb(p[:16])
            ok = self.ssp.check_confirm()
            self.say('SSP <- Nb; confirm %s; numeric %06d' % ('OK' if ok else 'MISMATCH', self.ssp.numeric()))
            self.send_lmp('accepted', bytes([LMP['simple_pairing_number']]), tid)
            self.send_lmp('DHkey_check', self.ssp.air_ea())        # Just Works: auto-accept, send Ea
        elif name == 'DHkey_check' and getattr(self, 'ssp_responder', False):
            self.say('SSP CAPTURE ea_air=%s pka=%s pkb_air=%s na=%s nb=%s dh=%s ioA=%s' % (
                p[:16].hex(), self.ssp.pk_a.hex(), getattr(self,'pk_in',b'')[:48].hex(),
                self.ssp.na.hex(), (self.ssp.nb or b'').hex(), (self.ssp.dh or b'').hex(), self.ssp.io_b.hex()))
            return
        elif name == 'DHkey_check':
            good = self.ssp.check_air_eb(p[:16])
            self.say('SSP <- Eb (%s)' % ('OK' if good else 'MISMATCH'))
            self.send_lmp('accepted', bytes([LMP['DHkey_check']]), tid)
            self.finish_pairing()
        elif name == 'numeric_comparison_failed' or name == 'passkey_failed' or name == 'oob_failed':
            self.say('SSP FAILED: %s' % name)
        elif name == 'encryption_mode_req':
            self.send_lmp('accepted', bytes([LMP['encryption_mode_req']]), tid)
        elif name == 'encryption_key_size_req':
            self.send_lmp('accepted', bytes([LMP['encryption_key_size_req']]), tid)
        elif name == 'start_encryption_req':
            self.send_lmp('accepted', bytes([LMP['start_encryption_req']]), tid)
            self.say('link encrypted (radio cipher is a no-op in the model)')
        elif name == 'au_rand':
            # The glasses challenge us (we are the claimant): SRES = E1(K, their_RAND, our_addr)[:4].
            import e1 as _e1
            their_rand_be = bytes(p[:16])[::-1]              # wire LE -> crypto BE
            sres_be, _aco = _e1.e1(self.link_key, their_rand_be, self.bdaddr[::-1])
            self.send_lmp('sres', sres_be[::-1], tid)
            self.say('LMP <- au_rand (glasses challenge); replied sres %s' % sres_be[::-1].hex())
        elif name == 'sres':
            # Glasses' response to our au_rand. Compare to our E1 (oracle: log both; link-key/byte-order
            # don't need to be right for the glasses' value to be captured).
            import e1 as _e1
            theirs = bytes(p[:4])
            mine_be, _aco = _e1.e1(self.link_key, self.au_rand_be, bytes.fromhex('554433221100'))
            self.say('ORACLE au_sres: glasses=%s mine_be=%s mine_le=%s match=%s' % (
                theirs.hex(), mine_be.hex(), mine_be[::-1].hex(),
                theirs in (mine_be, mine_be[::-1])))
            self.enc_step = 'mode'                           # proceed to encryption
            self.send_lmp('encryption_mode_req', bytes([1]))
        elif name == 'power_control_req':
            self.send_lmp('power_control_res', bytes([0x00]), tid)
        elif name in ('sniff_req', 'hold_req'):
            # Keep the virtual link in active mode. The model cannot honour sniff/hold anchor timing,
            # so if the glasses sleep in sniff the link goes silent and the firmware's supervision
            # timer expires (detach reason 8) mid-bond -> "Bond failed". Reject so the glasses keep
            # polling, on_tick keepalive keeps flowing, and bonding can complete.
            self.send_lmp('not_accepted', bytes([LMP[name], 0x1a]), tid)   # 0x1a: unsupported LMP feature
        elif name == 'ping_req':
            self.send_lmp('ping_res', b'', tid)
        elif name == 'channel_classification_req':
            pass
        elif name == 'accepted_ext' and len(p) >= 2 and p[1] == LMP_EXT['esco_link_req']:
            self.say('LMP eSCO link accepted by the glasses')
            self._sco_up()
        elif name == 'not_accepted_ext' and len(p) >= 2 and p[1] == LMP_EXT['esco_link_req']:
            self.say('LMP eSCO link req NOT accepted (reason 0x%02x)' % (p[2] if len(p) > 2 else 0))
        elif name == 'esco_link_req':
            # The glasses accept by echoing / counter-propose their own eSCO params; take their M->S
            # packet length and accept.
            if len(p) >= 10:
                self.sco_len = struct.unpack_from('<H', p, 8)[0] or self.sco_len
            self.say('LMP <- eSCO link req from the glasses (len %d); accepting' % self.sco_len)
            self.send_lmp('accepted_ext', bytes([127, LMP_EXT['esco_link_req']]), tid)
            self._sco_up()
        elif name == 'not_accepted' and p and p[0] == LMP['DHkey_check']:
            self.say('SSP DHkey check rejected by the glasses')
        elif name in ('accepted', 'not_accepted', 'accepted_ext', 'not_accepted_ext', 'auto_rate',
                      'preferred_rate', 'max_slot', 'max_power', 'min_power'):
            pass
        elif name == 'detach':
            self.say('LMP detach from the glasses, reason 0x%02x' % (p[0] if p else 0))
            if self.sweep and not self.paired and self.vi < len(self.variants):
                self.reset_for_repair()
            else:
                self.state = 'idle'
                self.pscans = -10 ** 9
        elif name in LMP_EXT:
            # Any other extended request (packet type table, sniff subrating, ...): accept it.
            self.send_lmp('accepted_ext', bytes([127, LMP_EXT[name]]), tid)
        else:
            self.send_lmp('accepted', bytes([LMP[name]]) if name in LMP else bytes([pdu[0] >> 1]), tid)

    # ---- SSP pairing (initiator) -----------------------------------------------------------------
    def reset_for_repair(self):
        self.state = "idle"; self.pscans = 0; self.page_at = 3; self.txq = []; self.lmp_done = set()
        self.setup_sent = False; self.profiles_started = False; self.channels = {}
        self.ssp = None; self.pk_frags_out = []; self.connected_events = 0

    def start_pairing(self):
        self.ssp = ssp.SspJustWorks(self.bdaddr[::-1], bytes.fromhex('554433221100'))
        self.say('SSP -> start pairing (Just Works, P-192)')
        self.send_lmp('io_capability_req', bytes([0x03, 0x00, 0x00]))

    def send_pubkey(self):
        pk = self.ssp.air_pk_a()
        self.send_lmp('encapsulated_header', bytes([1, 1, len(pk)]))
        self.pk_frags_out = [pk[i:i + 16] for i in range(0, len(pk), 16)]

    def finish_pairing(self):
        self.paired = True
        self.link_key = self.ssp.link_key()
        self.say('SSP complete: link key %s' % self.link_key.hex())
        # Post-SSP legacy LMP authentication (E1) before encryption -- the glasses require it, or they
        # leave PSM 3 pending and detach 0x22. Master challenges the glasses with au_rand first.
        import os as _os
        self.au_rand_be = _os.urandom(16)
        self.send_lmp('au_rand', self.au_rand_be[::-1])   # LMP wire is little-endian
        self.say('LMP -> au_rand (authenticate glasses)')

    def start_profiles_once(self):
        if not self.profiles_started:
            self.profiles_started = True
            self.start_profiles()

    # ---- ACL-U (L2CAP, Core spec Vol 3 Part A) ---------------------------------------------------
    ACL_MAX = 17                        # DM1 payload; L2CAP PDUs are fragmented to fit

    def send_l2cap(self, cid, payload):
        pdu = struct.pack('<HH', len(payload), cid) + payload
        first = True
        while pdu:
            chunk, pdu = pdu[:self.ACL_MAX], pdu[self.ACL_MAX:]
            self.txq.append((DM1, 2 if first else 1, chunk))
            first = False

    def on_acl(self, llid, data):
        if llid == 2:
            self.rx_l2cap = data
        else:
            self.rx_l2cap = getattr(self, 'rx_l2cap', b'') + data
        if len(self.rx_l2cap) >= 4:
            ln, cid = struct.unpack_from('<HH', self.rx_l2cap)
            if len(self.rx_l2cap) >= 4 + ln:
                pdu, self.rx_l2cap = self.rx_l2cap[4:4 + ln], b''
                self.on_l2cap(cid, pdu)

    def on_l2cap(self, cid, pdu):
        if cid == 1:
            self.on_signal(pdu)
        elif cid in self.channels:
            ch = self.channels[cid]
            ch['handler'](pdu)
        else:
            self.say('L2CAP <- cid 0x%04x (unknown) %s' % (cid, pdu.hex()))

    # L2CAP signaling (CID 1). Commands: code, identifier, length, data.
    def signal(self, code, data):
        self.sig_id = getattr(self, 'sig_id', 0) % 255 + 1
        self.send_l2cap(1, struct.pack('<BBH', code, self.sig_id, len(data)) + data)
        return self.sig_id

    def connect_psm(self, psm, handler, on_open):
        scid = self._out_cid; self._out_cid += 1   # monotonic: never reuse a CID still (or recently) live
        self.channels[scid] = dict(psm=psm, dcid=None, handler=handler, on_open=on_open,
                                   conf_out=False, conf_in=False, open=False)
        self.say('L2CAP -> connect PSM 0x%04x (scid 0x%04x)' % (psm, scid))
        self.signal(0x02, struct.pack('<HH', psm, scid))
        return scid

    def on_signal(self, pdu):
        while len(pdu) >= 4:
            code, ident, ln = struct.unpack_from('<BBH', pdu)
            d, pdu = pdu[4:4 + ln], pdu[4 + ln:]
            if code == 0x0a:                                    # information request
                itype = struct.unpack_from('<H', d)[0]
                if itype == 2:
                    rsp = struct.pack('<HH', 2, 0) + struct.pack('<I', 0x000002b8)
                elif itype == 3:
                    rsp = struct.pack('<HH', 3, 0) + bytes([0x86, 0, 0, 0, 0, 0, 0, 0])
                else:
                    rsp = struct.pack('<HH', itype, 1)
                self.send_l2cap(1, struct.pack('<BBH', 0x0b, ident, len(rsp)) + rsp)
            elif code == 0x0b:                                  # information response
                self.say('L2CAP info rsp %s' % d.hex())
            elif code == 0x03:                                  # connection response
                dcid, scid, result, status = struct.unpack_from('<HHHH', d)
                ch = self.channels.get(scid)
                self.say('L2CAP connection rsp dcid 0x%04x scid 0x%04x result %d status %d' % (dcid, scid, result, status))
                if ch and result == 0:
                    ch['dcid'] = dcid
                    # Configure: MTU 1021
                    self.signal(0x04, struct.pack('<HH', dcid, 0) + bytes([0x01, 2]) + struct.pack('<H', 1021))
                elif ch and result != 1:
                    self.say('L2CAP connection to PSM 0x%04x refused' % ch['psm'])
            elif code == 0x04:                                  # configuration request (from glasses)
                dcid, flags = struct.unpack_from('<HH', d)
                ch = self.channels.get(dcid)
                rsp = struct.pack('<HHH', ch['dcid'] if ch else 0, 0, 0) + d[4:]
                self.send_l2cap(1, struct.pack('<BBH', 0x05, ident, len(rsp)) + rsp)
                if ch:
                    ch['conf_in'] = True
                    self.check_open(dcid)
            elif code == 0x05:                                  # configuration response
                scid, flags, result = struct.unpack_from('<HHH', d)
                ch = self.channels.get(scid)
                self.say('L2CAP config rsp scid 0x%04x result %d' % (scid, result))
                if ch:
                    ch['conf_out'] = True
                    self.check_open(scid)
            elif code == 0x06:                                  # disconnection request
                dcid, scid = struct.unpack_from('<HH', d)
                self.send_l2cap(1, struct.pack('<BBHHH', 0x07, ident, 4, dcid, scid))
                self.channels.pop(dcid, None)
            elif code == 0x07:                                  # disconnection response
                pass
            elif code == 0x08:                                  # echo request
                self.send_l2cap(1, struct.pack('<BBH', 0x09, ident, len(d)) + d)
            elif code == 0x02:                                  # connection request from the glasses
                psm, rcid = struct.unpack_from('<HH', d)
                srv = self.served.get(psm)
                self.say('L2CAP connection req from glasses PSM 0x%04x (scid 0x%04x)%s'
                         % (psm, rcid, '' if srv else ' - refused'))
                if srv:
                    mycid = self._in_cid; self._in_cid += 1
                    opener = self.served_open.get(psm, (lambda s: None))
                    self.channels[mycid] = dict(psm=psm, dcid=rcid, open=False, conf_in=False,
                        conf_out=False, on_open=(lambda s, o=opener: o(s)),
                        handler=(lambda pdu, s=mycid, fn=srv: fn(s, pdu)))
                    self.send_l2cap(1, struct.pack('<BBHHHHH', 0x03, ident, 8, mycid, rcid, 0, 0))
                    self.signal(0x04, struct.pack('<HH', rcid, 0) + bytes([0x01, 2]) + struct.pack('<H', 1021))
                else:
                    self.send_l2cap(1, struct.pack('<BBHHHHH', 0x03, ident, 8, 0, rcid, 0x0002, 0))
            else:
                self.say('L2CAP signal code 0x%02x %s' % (code, d.hex()))

    def check_open(self, scid):
        ch = self.channels[scid]
        if ch['conf_in'] and ch['conf_out'] and not ch['open']:
            ch['open'] = True
            self.say('L2CAP channel 0x%04x (PSM 0x%04x) open' % (scid, ch['psm']))
            ch['on_open'](scid)

    def send_chan(self, scid, payload):
        self.send_l2cap(self.channels[scid]['dcid'], payload)

    # ---- profile bring-up after the link is set up --------------------------------------------
    def start_profiles(self):
        self.signal(0x0a, struct.pack('<H', 2))                 # extended features
        self.sdp_find_channel(self.RNLINK_UUID, self._rnlink_sdp_found, 'rnlink SPP')

    # SDP client (Vol 3 Part B): ServiceSearchAttributeRequest to find a service's RFCOMM channel.
    RNLINK_UUID = bytes.fromhex('99999999999999999999999999999999')

    def sdp_find_channel(self, uuid, on_found, name):
        cid = self.connect_psm(0x0001, None, None)
        ch = self.channels[cid]
        ch['sdp_uuid'], ch['sdp_found'], ch['sdp_name'] = uuid, on_found, name
        ch['handler'] = lambda pdu, s=cid: self.on_sdp(s, pdu)
        ch['on_open'] = lambda scid=cid: self._sdp_query(scid)
        return cid

    def _sdp_query(self, scid):
        ch = self.channels[scid]
        uuid = ch['sdp_uuid']
        pattern = (bytes([0x35, 3, 0x19]) + uuid) if len(uuid) == 2 else (bytes([0x35, 17, 0x1c]) + uuid)
        attrs = bytes([0x35, 5, 0x0a, 0x00, 0x00, 0xff, 0xff])
        body = pattern + struct.pack('>H', 0x0400) + attrs + b'\0'
        self.say('SDP -> SearchAttrReq (%s)' % ch['sdp_name'])
        self.send_chan(scid, bytes([0x06]) + struct.pack('>HH', 1, len(body)) + body)

    def on_sdp(self, scid, pdu):
        if not pdu or pdu[0] != 0x07:
            return
        ch = self.channels.get(scid, {})
        # RFCOMM channel = protocol descriptor UUID 0x0003 followed by a uint8 channel.
        i = pdu.find(bytes([0x19, 0x00, 0x03, 0x08]))
        channel = pdu[i + 4] if i >= 0 else None
        self.say('SDP <- %s: RFCOMM channel %s' % (ch.get('sdp_name', '?'), channel))
        if ch.get('dcid') is not None:                          # tear down this SDP L2CAP channel
            self.signal(0x06, struct.pack('<HH', ch['dcid'], scid))
        self.channels.pop(scid, None)
        if channel is not None and ch.get('sdp_found'):
            ch['sdp_found'](channel)

    def _rnlink_sdp_found(self, channel):
        self.rfcomm_channel = channel
        self.say('SDP: rnlink SPP on RFCOMM channel %d' % channel)
        self.rfcomm_cid = self.connect_psm(0x0003, self.on_rfcomm, self._spp_start)

    # ---- HFP Audio Gateway (phone): on an incoming call the AG opens the SLC to the glasses' HF ----
    def start_hfp(self):
        self.sdp_find_channel(bytes([0x11, 0x1e]), self._hfp_sdp_found, 'HFP HF (0x111E)')

    def _hfp_sdp_found(self, channel):
        from btprofiles import hfp
        self.hfp = hfp.HfpAudioGateway(send=lambda b: self.dlc_write(self.hfp_dlci, b), say=self.say,
                                       on_audio=self._sco_audio, inband_ring=bool(os.environ.get('SCO_AUDIO')))
        self.say('HFP: glasses HF on RFCOMM channel %d; opening AG SLC' % channel)
        self.hfp_dlci = self.rfcomm_open_dlc(channel, self.hfp.on_data, self._hfp_opened, 'HFP')

    def _hfp_opened(self, dlci):
        # DLC up; the glasses' HF now drives the SLC AT handshake and the AG answers. The incoming
        # call is raised from on_activity once hfp.slc is set.
        self.say('HFP AG RFCOMM DLC up (DLCI %d); waiting for HF service-level connection' % dlci)

    def _sco_audio(self, codec):
        # hfp.py negotiated the codec (+BCS); the phone (AG) now sets up the (e)SCO link as master.
        # HFP T2 for mSBC (2-EV3, transparent air mode, 60 B, T_eSCO=12) / EV3 for CVSD (air 2). The
        # downlink audio (60 B mSBC / 60 B CVSD per 7.5 ms) then rides the SCO link to the glasses'
        # ScoService via intersys ch3 (controller bridge, pumped from on_activity once sco_active).
        self.sco_codec = codec
        air = 3 if codec == 2 else 2            # transparent (mSBC) / CVSD
        pkt = 0x26 if codec == 2 else 0x07      # 2-EV3 (T2) / EV3
        self.sco_len = 60
        payload = (bytes([1, self.lt_addr, 0, 0, 12, 6, pkt, pkt])
                   + struct.pack('<HH', self.sco_len, self.sco_len) + bytes([air, 0]))
        self.say('HFP audio up: codec %s -> LMP eSCO link req (air %d, pkt 0x%02x, len %d)'
                 % ('mSBC' if codec == 2 else 'CVSD', air, pkt, self.sco_len))
        self.send_lmp('esco_link_req', payload)

    def _sco_up(self):
        if not getattr(self, 'sco_active', False):
            self.sco_active = True
            self.say('(e)SCO link established (codec %s, %d B/frame); SCO audio active'
                     % ('mSBC' if self.sco_codec == 2 else 'CVSD', self.sco_len))

    # ---- A2DP source + AVRCP target (the phone streams music to the glasses' A2DP sink) -----------
    def start_a2dp(self):
        # The glasses are the A2DP SINK + AVRCP CONTROLLER and run no server on PSM 0x19/0x17 (they
        # return "PSM not supported" to an incoming connect): they INITIATE, audio-focus-driven, when
        # media starts on the glasses. So the phone is the ACP source + AVRCP target: we listen on
        # PSM 0x19 (AVDTP: first channel = signaling, second = media) and 0x17 (AVCTP) and respond.
        from btprofiles import avdtp, avrcp
        wav = os.environ.get('A2DP_WAV', '.local/test-audio/wake-xiaolei.wav')
        self.a2dp_sig_cid = self.a2dp_media_cid = self.avrcp_cid = None
        self.a2dp = avdtp.A2dpSource(
            send=lambda b: self.send_chan(self.a2dp_sig_cid, b),
            send_media=lambda b: (self.send_chan(self.a2dp_media_cid, b) if self.a2dp_media_cid else None),
            open_transport=None, audio=avdtp.WavSource(wav), say=self.say)
        self.avrcp = avrcp.AvrcpTarget(send=lambda b: self.send_chan(self.avrcp_cid, b), say=self.say,
                                       title='Virtual Track', artist='Virtual Artist')
        self.served[0x0019] = lambda scid, pdu: self.a2dp.on_data(pdu)
        self.served[0x0017] = lambda scid, pdu: self.avrcp.on_data(pdu)
        self.served_open[0x0019] = self._a2dp_chan_open
        self.served_open[0x0017] = self._avctp_open
        self.say('A2DP source + AVRCP target ready (ACP); waiting for the glasses to open media')

    def _a2dp_chan_open(self, scid):
        if self.a2dp_sig_cid is None:
            self.a2dp_sig_cid = scid
            self.say('A2DP AVDTP signaling channel open (the glasses will discover our source SEP)')
        else:
            self.a2dp_media_cid = scid
            self.a2dp.transport_up = True
            self.say('A2DP media transport channel open; ready to stream SBC')

    def _avctp_open(self, scid):
        self.avrcp_cid = scid
        self.say('AVRCP AVCTP channel open')

    # ---- SDP server: the glasses (HF/sink) query the phone for its HFP AG / A2DP / AVRCP services --
    def on_sdp_server(self, scid, pdu):
        if not pdu or pdu[0] not in (0x02, 0x04, 0x06):
            return
        pid, tid, plen = pdu[0], struct.unpack_from('>H', pdu, 1)[0], struct.unpack_from('>H', pdu, 3)[0]
        params = pdu[5:5 + plen]
        if pid == 0x06:                                         # ServiceSearchAttributeRequest
            _, pat, j = sdp_parse(params, 0)
            j += 2                                              # skip MaximumAttributeByteCount
            _, attrlist, j = sdp_parse(params, j)
            uuids, ranges = sdp_uuids(pat), sdp_attr_ranges(attrlist)
            self.say('SDP-server <- SearchAttrReq uuids=%s' % ['0x%04x' % u for u in uuids])
            records = []
            if {0x111F, 0x111E, 0x1203} & set(uuids):           # HFP AG asked for
                records.append(hfp_ag_record(HFP_AG_CHANNEL))
            if {0x110A, 0x110D} & set(uuids):                   # A2DP (glasses query 0x110d)
                records.append(a2dp_source_record())
            if {0x110C, 0x110E} & set(uuids):                   # AVRCP (glasses query 0x110e)
                records.append(avrcp_target_record())
            lists = []
            for rec in records:
                items = [de_uint(aid, 2) + val for aid, val in rec
                         if any(lo <= aid <= hi for lo, hi in ranges)]
                lists.append(de_seq(items))
            attrlists = de_seq(lists)
            body = struct.pack('>H', len(attrlists)) + attrlists + b'\x00'
            self.send_chan(scid, bytes([0x07]) + struct.pack('>HH', tid, len(body)) + body)
            if records:
                served = []
                if {0x111F, 0x111E, 0x1203} & set(uuids): served.append('HFP AG (ch %d)' % HFP_AG_CHANNEL)
                if {0x110A, 0x110D} & set(uuids): served.append('A2DP source (PSM 0x19)')
                if {0x110C, 0x110E} & set(uuids): served.append('AVRCP target (PSM 0x17)')
                self.say('SDP-server -> %s' % ', '.join(served))
        else:                                                   # 0x02/0x04: minimal empty answer
            rid = 0x03 if pid == 0x02 else 0x05
            body = (struct.pack('>HH', 0, 0) + b'\x00') if pid == 0x02 else (struct.pack('>H', 1) + de_seq([]) + b'\x00')
            self.send_chan(scid, bytes([rid]) + struct.pack('>HH', tid, len(body)) + body)

    # ---- RFCOMM (TS 07.10 subset + Bluetooth credit-based flow control), the phone initiates ----
    @staticmethod
    def _fcs(data):
        crc = 0xff
        for b in data:
            crc ^= b
            for _ in range(8):
                crc = (crc >> 1) ^ 0xe0 if crc & 1 else crc >> 1
        return 0xff - crc

    def rfcomm_frame(self, dlci, ctrl, payload=b'', cr=1, credits=None):
        addr = (dlci << 2) | (cr << 1) | 1
        if credits is not None:
            ctrl |= 0x10                                            # P/F: a credit byte follows
        ln = len(payload)
        lenb = bytes([(ln << 1) | 1]) if ln < 128 else struct.pack('<H', ln << 1)
        body = bytes([addr, ctrl]) + lenb + (bytes([credits]) if credits is not None else b'') + payload
        fcs = self._fcs(bytes([addr, ctrl]) if (ctrl & 0xef) == 0xef else bytes([addr, ctrl]) + lenb)
        return body + bytes([fcs])

    def rfcomm_send(self, frame):
        self.send_chan(self.rfcomm_cid, frame)

    def mux(self, mtype, data, cr=1):
        # Multiplexer control command on DLCI 0: type byte, length byte, values.
        return self.rfcomm_frame(0, 0xef, bytes([(mtype << 2) | (cr << 1) | 1, (len(data) << 1) | 1]) + data)

    # A DLC is phone-initiated on the glasses' server `channel`; DLCI = channel<<1 (direction bit 0 =
    # the device that set up the RFCOMM session). All DLCs share the one mux on self.rfcomm_cid.
    def rfcomm_open_dlc(self, channel, on_data, on_open=None, name='DLC'):
        dlci = channel << 1
        self.dlcs[dlci] = dict(channel=channel, on_data=on_data, on_open=on_open, name=name,
                               tx_credits=0, out=b'', rx_used=0, up=False)
        if not self.rfcomm_mux_up:
            self.pending_dlc = dlci
            self.say('RFCOMM -> SABM DLCI 0')
            self.rfcomm_send(self.rfcomm_frame(0, 0x3f))            # SABM, P=1
        else:
            self._rfcomm_pn(dlci)
        return dlci

    def _rfcomm_pn(self, dlci):
        d = self.dlcs[dlci]
        # PN: DLCI, CL=0xF (credit flow), priority 7, T1 0, N1 (max frame) 1000, NA 0, credits 7
        pn = bytes([dlci, 0xf0, 7, 0]) + struct.pack('<H', 1000) + bytes([0, 7])
        self.say('RFCOMM -> PN DLCI %d (%s channel %d)' % (dlci, d['name'], d['channel']))
        self.rfcomm_send(self.mux(0x20, pn))

    def dlc_write(self, dlci, raw):
        d = self.dlcs.get(dlci)
        if d is None:
            return
        d['out'] += raw
        self._dlc_flush(dlci)

    def _dlc_flush(self, dlci):
        d = self.dlcs[dlci]
        while d['out'] and d['tx_credits'] > 0:
            chunk, d['out'] = d['out'][:900], d['out'][900:]
            d['tx_credits'] -= 1
            give = None
            if d['rx_used'] >= 20:
                give, d['rx_used'] = d['rx_used'], 0
            self.rfcomm_send(self.rfcomm_frame(dlci, 0xef, chunk, credits=give))

    def on_rfcomm(self, pdu):
        addr, ctrl = pdu[0], pdu[1] & 0xef
        dlci = addr >> 2
        i = 2
        ln = pdu[i] >> 1
        if pdu[i] & 1 == 0:
            ln = (pdu[i] | pdu[i + 1] << 8) >> 1
            i += 1
        i += 1
        credits = 0
        if ctrl == 0xef and pdu[1] & 0x10 and dlci != 0:
            credits = pdu[i]
            i += 1
        data = pdu[i:i + ln]
        if ctrl == 0x63:                                            # UA
            self.say('RFCOMM <- UA DLCI %d' % dlci)
            if dlci == 0:
                self.rfcomm_mux_up = True
                if self.pending_dlc is not None:
                    self._rfcomm_pn(self.pending_dlc)
                    self.pending_dlc = None
            elif dlci in self.dlcs:                                 # our SABM for this DLC accepted
                self.say('RFCOMM -> MSC DLCI %d' % dlci)
                self.rfcomm_send(self.mux(0x38, bytes([(dlci << 2) | 3, 0x8d])))
        elif ctrl == 0x0f:                                          # DM
            self.say('RFCOMM <- DM DLCI %d (refused)' % dlci)
        elif ctrl == 0x2f:                                          # SABM from the glasses
            self.rfcomm_send(self.rfcomm_frame(dlci, 0x73, cr=1))
        elif ctrl == 0x43:                                          # DISC
            self.say('RFCOMM <- DISC DLCI %d' % dlci)
            self.rfcomm_send(self.rfcomm_frame(dlci, 0x73, cr=1))
        elif ctrl == 0xef and dlci == 0:
            self.on_mux(data)
        elif ctrl == 0xef and dlci in self.dlcs:
            d = self.dlcs[dlci]
            d['tx_credits'] += credits
            if data:
                d['rx_used'] += 1
                if d['on_data']:
                    d['on_data'](data)
            if d['rx_used'] >= 20 and not d['out']:
                self.rfcomm_send(self.rfcomm_frame(dlci, 0xef, b'', credits=d['rx_used']))
                d['rx_used'] = 0
            self._dlc_flush(dlci)

    def on_mux(self, data):
        mtype, cr = data[0] >> 2, (data[0] >> 1) & 1
        vals = data[2:2 + (data[1] >> 1)]
        if mtype == 0x20 and not cr:                                # PN response (vals[0] = DLCI)
            rdlci = vals[0]
            d = self.dlcs.get(rdlci)
            if d:
                d['tx_credits'] = vals[7]
            self.say('RFCOMM <- PN rsp: frame %d credits %d' % (struct.unpack_from('<H', vals, 4)[0], vals[7]))
            self.say('RFCOMM -> SABM DLCI %d' % rdlci)
            self.rfcomm_send(self.rfcomm_frame(rdlci, 0x3f))
        elif mtype == 0x38 and cr:                                  # MSC command from the glasses
            self.rfcomm_send(self.mux(0x38, vals, cr=0))
            mdlci = vals[0] >> 2
            d = self.dlcs.get(mdlci)
            if d and not d['up']:
                d['up'] = True
                # Give the glasses plenty of credits, then hand the open DLC to its owner.
                self.rfcomm_send(self.rfcomm_frame(mdlci, 0xef, b'', credits=60))
                if d['on_open']:
                    d['on_open'](mdlci)
        elif mtype == 0x38 and not cr:
            pass                                                    # MSC response
        elif cr:
            self.say('RFCOMM mux cmd 0x%02x %s (answered)' % (mtype, vals.hex()))
            self.rfcomm_send(self.mux(mtype, vals, cr=0))

    # ---- rnlink SPP DLC (channel 26): keeps the external on_spp_open / on_spp_data / spp_write API --
    def _spp_start(self, scid):
        self.spp_dlci = self.rfcomm_open_dlc(self.rfcomm_channel, self._spp_recv, self._spp_opened, 'SPP')

    def _spp_opened(self, dlci):
        self.spp_up = True
        self.say('SPP (RFCOMM channel %d) open: starting rnlink over classic BT' % self.dlcs[dlci]['channel'])
        if self.on_spp_open:
            self.on_spp_open(self)
        if os.environ.get('HFP_CALL'):                          # bring up the HFP AG for the call demo
            self.start_hfp()
        if os.environ.get('A2DP_MUSIC'):                        # stream music to the glasses' A2DP sink
            self.start_a2dp()

    def _spp_recv(self, data):
        if self.on_spp_data:
            self.on_spp_data(data)

    def spp_write(self, raw):
        if self.spp_dlci is not None:
            self.dlc_write(self.spp_dlci, raw)


