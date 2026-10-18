"""AVDTP 1.3 + A2DP 1.3 source (the phone streams SBC audio to the glasses' sink).

    src = A2dpSource(send=sig_write, send_media=media_write, open_transport=open_media_channel,
                     audio=WavSource('test.wav'))
    src.on_data(pdu)          # AVDTP signaling PDUs from the glasses (L2CAP PSM 0x19, first channel)
    src.connect()             # phone as INT: DISCOVER -> GET_(ALL_)CAPABILITIES -> SET_CONFIGURATION -> OPEN
    src.transport_open()      # the host opened the media L2CAP channel (PSM 0x19, second channel) -> START
    src.stream(ms)            # emit the SBC media packets due for `ms` of audio (call on a timer)

It also answers as ACP when the glasses initiate (DISCOVER/GET_CAPABILITIES/SET_CONFIGURATION/OPEN/
START/SUSPEND/CLOSE/ABORT/DELAYREPORT). Media packets: RTP header (V=2, PT 96, seq, timestamp in
samples, SSRC) + A2DP SBC payload header (frame count) + whole SBC frames, sized to the media MTU.
"""
import struct
import wave

from . import sbc

DISCOVER, GET_CAPABILITIES, SET_CONFIGURATION, GET_CONFIGURATION, RECONFIGURE, OPEN, START, CLOSE, \
    SUSPEND, ABORT, SECURITY_CONTROL, GET_ALL_CAPABILITIES, DELAYREPORT = range(1, 14)
SIGNALS = {DISCOVER: 'DISCOVER', GET_CAPABILITIES: 'GET_CAPABILITIES', SET_CONFIGURATION: 'SET_CONFIGURATION',
           GET_CONFIGURATION: 'GET_CONFIGURATION', RECONFIGURE: 'RECONFIGURE', OPEN: 'OPEN', START: 'START',
           CLOSE: 'CLOSE', SUSPEND: 'SUSPEND', ABORT: 'ABORT', SECURITY_CONTROL: 'SECURITY_CONTROL',
           GET_ALL_CAPABILITIES: 'GET_ALL_CAPABILITIES', DELAYREPORT: 'DELAYREPORT'}
COMMAND, GENERAL_REJECT, RESPONSE_ACCEPT, RESPONSE_REJECT = 0, 1, 2, 3
SINGLE, START_PKT, CONTINUE_PKT, END_PKT = 0, 1, 2, 3
CAT_MEDIA_TRANSPORT, CAT_REPORTING, CAT_RECOVERY, CAT_CONTENT_PROTECTION, CAT_HEADER_COMPRESSION, \
    CAT_MULTIPLEXING, CAT_MEDIA_CODEC, CAT_DELAY_REPORTING = range(1, 9)
AUDIO, SBC_CODEC = 0x00, 0x00
SOURCE, SINK = 0, 1
BAD_ACP_SEID, SEP_IN_USE, BAD_STATE = 0x12, 0x13, 0x31

# SBC codec information element bits (A2DP 4.3.2)
SBC_RATE_BITS = {16000: 0x80, 32000: 0x40, 44100: 0x20, 48000: 0x10}
SBC_MODE_BITS = {sbc.MONO: 0x08, sbc.DUAL_CHANNEL: 0x04, sbc.STEREO: 0x02, sbc.JOINT_STEREO: 0x01}
SBC_BLOCK_BITS = {4: 0x80, 8: 0x40, 12: 0x20, 16: 0x10}
SBC_SUBBAND_BITS = {4: 0x08, 8: 0x04}
SBC_ALLOC_BITS = {sbc.SNR: 0x02, sbc.LOUDNESS: 0x01}


def sbc_codec_info(rates, modes, blocks, subbands, allocs, min_bitpool, max_bitpool):
    b0 = sum(SBC_RATE_BITS[r] for r in rates) | sum(SBC_MODE_BITS[m] for m in modes)
    b1 = (sum(SBC_BLOCK_BITS[b] for b in blocks) | sum(SBC_SUBBAND_BITS[s] for s in subbands) |
          sum(SBC_ALLOC_BITS[a] for a in allocs))
    return bytes([b0, b1, min_bitpool, max_bitpool])


def parse_sbc_info(info):
    """codec info (4 bytes) -> dict of supported value lists + bitpool range."""
    b0, b1, lo, hi = info[:4]
    pick = lambda table, byte: [k for k, bit in table.items() if byte & bit]
    return dict(rates=pick(SBC_RATE_BITS, b0), modes=pick(SBC_MODE_BITS, b0),
                blocks=pick(SBC_BLOCK_BITS, b1), subbands=pick(SBC_SUBBAND_BITS, b1),
                allocs=pick(SBC_ALLOC_BITS, b1), min_bitpool=lo, max_bitpool=hi)


def parse_caps(data):
    """Service capabilities (category, length, value)* -> {category: value}."""
    caps, i = {}, 0
    while i + 2 <= len(data):
        cat, ln = data[i], data[i + 1]
        caps[cat] = data[i + 2:i + 2 + ln]
        i += 2 + ln
    return caps


def caps_bytes(caps):
    return b''.join(bytes([cat, len(v)]) + v for cat, v in caps.items())


class WavSource:
    """16-bit PCM WAV, looped, linearly resampled to the negotiated rate; yields per-channel blocks."""

    def __init__(self, path, loop=True):
        with wave.open(path, 'rb') as w:
            assert w.getsampwidth() == 2, '16-bit PCM WAV only'
            self.rate, self.nch = w.getframerate(), w.getnchannels()
            raw = w.readframes(w.getnframes())
        n = len(raw) // (2 * self.nch)
        vals = struct.unpack('<%dh' % (n * self.nch), raw[:n * 2 * self.nch])
        self.chans = [list(vals[c::self.nch]) for c in range(self.nch)]
        self.loop, self.pos = loop, 0.0

    def read(self, n, rate, channels):
        """n samples per channel at `rate`, as `channels` lists (mono is duplicated / stereo mixed)."""
        step = self.rate / rate
        length = len(self.chans[0])
        out = [[] for _ in range(self.nch)]
        for _ in range(n):
            i = int(self.pos)
            frac = self.pos - i
            j = i + 1
            if j >= length:
                j = 0 if self.loop else i
            for c in range(self.nch):
                a, b = self.chans[c][i % length], self.chans[c][j % length]
                out[c].append(int(a + (b - a) * frac))
            self.pos += step
            if self.pos >= length:
                self.pos = self.pos - length if self.loop else length - 1
        if channels == 1 and self.nch == 2:
            return [[(a + b) // 2 for a, b in zip(*out)]]
        if channels == 2 and self.nch == 1:
            return [out[0], list(out[0])]
        return out[:channels]


class A2dpSource:
    """A2DP source SEP (SEID 1, SBC) over AVDTP."""

    SEID = 1

    def __init__(self, send, send_media=None, open_transport=None, audio=None, say=None,
                 media_mtu=895, max_bitpool=53, on_state=None):
        self.send, self.send_media, self.open_transport = send, send_media, open_transport
        self.audio, self.media_mtu, self.max_bitpool = audio, media_mtu, max_bitpool
        self.say = say or (lambda *_: None)
        self.on_state = on_state
        self.label = 0
        self.pending = {}                # transaction label -> signal id (commands we sent)
        self.rx_frag = None
        self.state = 'idle'              # idle -> configured -> open -> streaming
        self.remote_seid = None
        self.config = None               # dict(rate, mode, blocks, subbands, allocation, bitpool)
        self.encoder = None
        self.seq, self.timestamp = 0, 0
        self.ssrc = 1
        self.frames_sent = 0
        self.remote_seps = []
        self.delay_report = None
        self.remote_delay_reporting = False
        self.initiator = False
        self.transport_up = False

    # ---- capabilities of our source SEP ----
    def local_caps(self):
        info = sbc_codec_info((44100, 48000), (sbc.MONO, sbc.DUAL_CHANNEL, sbc.STEREO, sbc.JOINT_STEREO),
                              (4, 8, 12, 16), (4, 8), (sbc.SNR, sbc.LOUDNESS), 2, self.max_bitpool)
        return {CAT_MEDIA_TRANSPORT: b'',
                CAT_MEDIA_CODEC: bytes([AUDIO << 4, SBC_CODEC]) + info,
                CAT_DELAY_REPORTING: b''}

    def _set_state(self, state):
        self.state = state
        self.say('A2DP state %s' % state)
        if self.on_state:
            self.on_state(state)

    # ---- signaling transmit ----
    def _tx(self, label, msg_type, signal, params=b''):
        self.send(bytes([(label << 4) | (SINGLE << 2) | msg_type, signal & 0x3f]) + params)

    def command(self, signal, params=b''):
        self.label = (self.label + 1) % 16
        self.pending[self.label] = signal
        self.say('AVDTP -> %s %s' % (SIGNALS.get(signal, signal), params.hex()))
        self._tx(self.label, COMMAND, signal, params)
        return self.label

    # ---- INT procedures (the phone sets the stream up) ----
    def connect(self):
        self.command(DISCOVER)

    def transport_open(self):
        """The host opened the media transport channel; start streaming (INT) or wait for START (ACP)."""
        self.transport_up = True
        if self.state == 'open' and getattr(self, 'initiator', False):
            self.command(START, bytes([self.remote_seid << 2]))

    def suspend(self):
        if self.state == 'streaming':
            self.command(SUSPEND, bytes([self.remote_seid << 2]))

    def close(self):
        if self.state in ('open', 'streaming', 'configured'):
            self.command(CLOSE, bytes([self.remote_seid << 2]))

    def choose_config(self, remote):
        """Best common SBC configuration (A2DP 4.3.4 recommendations: 44.1 kHz, joint stereo, 16/8)."""
        pref = lambda wanted, options: next((w for w in wanted if w in options), options[0] if options else None)
        return dict(rate=pref([44100, 48000], remote['rates']),
                    mode=pref([sbc.JOINT_STEREO, sbc.STEREO, sbc.DUAL_CHANNEL, sbc.MONO], remote['modes']),
                    blocks=pref([16, 12, 8, 4], remote['blocks']),
                    subbands=pref([8, 4], remote['subbands']),
                    allocation=pref([sbc.LOUDNESS, sbc.SNR], remote['allocs']),
                    bitpool=max(remote['min_bitpool'], min(self.max_bitpool, remote['max_bitpool'])))

    def config_caps(self, cfg):
        info = sbc_codec_info((cfg['rate'],), (cfg['mode'],), (cfg['blocks'],), (cfg['subbands'],),
                              (cfg['allocation'],), 2, cfg['bitpool'])
        caps = {CAT_MEDIA_TRANSPORT: b'', CAT_MEDIA_CODEC: bytes([AUDIO << 4, SBC_CODEC]) + info}
        if self.remote_delay_reporting:
            caps[CAT_DELAY_REPORTING] = b''
        return caps

    # ---- signaling receive ----
    def on_data(self, pdu):
        if not pdu:
            return
        label, ptype, mtype = pdu[0] >> 4, (pdu[0] >> 2) & 3, pdu[0] & 3
        if ptype == START_PKT:                       # header, NOSP, signal id, payload
            self.rx_frag = (label, mtype, pdu[2] & 0x3f, bytearray(pdu[3:]))
            return
        if ptype == CONTINUE_PKT and self.rx_frag:
            self.rx_frag[3].extend(pdu[1:])
            return
        if ptype == END_PKT and self.rx_frag:
            label, mtype, signal, body = self.rx_frag
            body.extend(pdu[1:])
            self.rx_frag = None
            params = bytes(body)
        else:
            signal, params = pdu[1] & 0x3f, pdu[2:]
        if mtype == COMMAND:
            self.on_command(label, signal, params)
        elif mtype == GENERAL_REJECT:
            self.say('AVDTP <- general reject label %d' % label)
        else:
            sent = self.pending.pop(label, signal)
            self.on_response(sent, mtype == RESPONSE_ACCEPT, params)

    def on_command(self, label, signal, params):
        name = SIGNALS.get(signal, signal)
        self.say('AVDTP <- %s (command) %s' % (name, params.hex()))
        accept = lambda p=b'': self._tx(label, RESPONSE_ACCEPT, signal, p)
        reject = lambda p: self._tx(label, RESPONSE_REJECT, signal, p)
        seid = params[0] >> 2 if params else None
        if signal == DISCOVER:
            in_use = 1 if self.state != 'idle' else 0
            accept(bytes([(self.SEID << 2) | (in_use << 1), (AUDIO << 4) | (SOURCE << 3)]))
        elif signal in (GET_CAPABILITIES, GET_ALL_CAPABILITIES):
            if seid != self.SEID:
                return reject(bytes([BAD_ACP_SEID]))
            caps = self.local_caps()
            if signal == GET_CAPABILITIES:
                caps.pop(CAT_DELAY_REPORTING, None)
            accept(caps_bytes(caps))
        elif signal == SET_CONFIGURATION:
            if seid != self.SEID:
                return reject(bytes([CAT_MEDIA_CODEC, BAD_ACP_SEID]))
            if self.state != 'idle':
                return reject(bytes([CAT_MEDIA_CODEC, SEP_IN_USE]))
            caps = parse_caps(params[2:])
            codec = caps.get(CAT_MEDIA_CODEC, b'')
            if len(codec) < 6 or codec[1] != SBC_CODEC:
                return reject(bytes([CAT_MEDIA_CODEC, 0xc1]))       # A2DP: invalid codec type
            p = parse_sbc_info(codec[2:])
            self.remote_seid = params[1] >> 2
            self.remote_delay_reporting = CAT_DELAY_REPORTING in caps
            self._configure(dict(rate=p['rates'][0], mode=p['modes'][0], blocks=p['blocks'][0],
                                 subbands=p['subbands'][0], allocation=p['allocs'][0],
                                 bitpool=p['max_bitpool']))
            self.initiator = False
            accept()
        elif signal == GET_CONFIGURATION:
            accept(caps_bytes(self.config_caps(self.config)) if self.config else b'')
        elif signal == OPEN:
            if self.state != 'configured':
                return reject(bytes([BAD_STATE]))
            self._set_state('open')
            accept()
        elif signal == START:
            if self.state not in ('open', 'streaming'):
                return reject(bytes([self.SEID << 2, BAD_STATE]))
            accept()
            self._set_state('streaming')
        elif signal == SUSPEND:
            accept()
            if self.state == 'streaming':
                self._set_state('open')
        elif signal in (CLOSE, ABORT):
            accept()
            self._reset()
        elif signal == DELAYREPORT:
            self.delay_report = struct.unpack('>H', params[1:3])[0] if len(params) >= 3 else None
            self.say('AVDTP sink delay %s x0.1 ms' % self.delay_report)
            accept()
        elif signal == RECONFIGURE:
            reject(bytes([CAT_MEDIA_CODEC, BAD_STATE]))
        else:
            self._tx(label, GENERAL_REJECT, signal)

    def on_response(self, signal, ok, params):
        name = SIGNALS.get(signal, signal)
        self.say('AVDTP <- %s %s %s' % (name, 'accept' if ok else 'reject', params.hex()))
        if not ok:
            if signal == SET_CONFIGURATION or signal == OPEN:
                self._reset()
            return
        if signal == DISCOVER:
            self.remote_seps = [dict(seid=params[i] >> 2, in_use=(params[i] >> 1) & 1,
                                     media=params[i + 1] >> 4, tsep=(params[i + 1] >> 3) & 1)
                                for i in range(0, len(params) - 1, 2)]
            sink = next((s for s in self.remote_seps
                         if s['tsep'] == SINK and s['media'] == AUDIO and not s['in_use']), None)
            if sink:
                self.remote_seid = sink['seid']
                self.command(GET_ALL_CAPABILITIES, bytes([sink['seid'] << 2]))
        elif signal in (GET_CAPABILITIES, GET_ALL_CAPABILITIES):
            caps = parse_caps(params)
            codec = caps.get(CAT_MEDIA_CODEC, b'')
            if len(codec) < 6 or codec[1] != SBC_CODEC:
                self.say('A2DP: sink offers no SBC')
                return
            self.remote_delay_reporting = CAT_DELAY_REPORTING in caps
            cfg = self.choose_config(parse_sbc_info(codec[2:]))
            self.pending_config = cfg
            self.command(SET_CONFIGURATION, bytes([self.remote_seid << 2, self.SEID << 2]) +
                         caps_bytes(self.config_caps(cfg)))
        elif signal == SET_CONFIGURATION:
            self.initiator = True
            self._configure(self.pending_config)
            self.command(OPEN, bytes([self.remote_seid << 2]))
        elif signal == OPEN:
            self._set_state('open')
            if self.open_transport:
                self.open_transport()               # host opens the media channel, then transport_open()
            elif getattr(self, 'transport_up', False):
                self.transport_open()
        elif signal == START:
            self._set_state('streaming')
        elif signal == SUSPEND:
            self._set_state('open')
        elif signal in (CLOSE, ABORT):
            self._reset()

    def _configure(self, cfg):
        self.config = cfg
        self.encoder = sbc.SbcEncoder(rate=cfg['rate'], mode=cfg['mode'], blocks=cfg['blocks'],
                                      subbands=cfg['subbands'], allocation=cfg['allocation'],
                                      bitpool=cfg['bitpool'],
                                      channels=1 if cfg['mode'] == sbc.MONO else 2)
        self.say('A2DP configured %s' % cfg)
        self._set_state('configured')

    def _reset(self):
        self.config = self.encoder = None
        self.remote_seid = None
        self._set_state('idle')

    # ---- media ----
    def frames_per_packet(self):
        room = self.media_mtu - 12 - 1
        return max(1, min(15, room // self.encoder.frame_bytes))

    def media_packet(self, nframes=None):
        """Encode the next `nframes` SBC frames from the audio source into one RTP media packet."""
        enc = self.encoder
        nframes = nframes or self.frames_per_packet()
        nch = enc.channels
        frames = b''
        for _ in range(nframes):
            pcm = self.audio.read(enc.samples_per_frame, enc.rate, nch) if self.audio else \
                [[0] * enc.samples_per_frame for _ in range(nch)]
            frames += enc.encode(pcm)
        rtp = struct.pack('>BBHII', 0x80, 96, self.seq & 0xffff, self.timestamp & 0xffffffff, self.ssrc)
        self.seq += 1
        self.timestamp += nframes * enc.samples_per_frame
        self.frames_sent += nframes
        return rtp + bytes([nframes & 0x0f]) + frames

    def stream(self, ms):
        """Send the media packets due for `ms` milliseconds of audio. Returns the number of packets."""
        if self.state != 'streaming' or not self.send_media:
            return 0
        self.owed = getattr(self, 'owed', 0.0) + self.encoder.rate * ms / 1000.0
        per_packet = self.frames_per_packet() * self.encoder.samples_per_frame
        n = 0
        while self.owed >= per_packet:
            self.send_media(self.media_packet())
            self.owed -= per_packet
            n += 1
        return n
