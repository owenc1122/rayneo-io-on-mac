"""rnlink wire codec for the virtual phone (derived from the stock AP firmware).

Frame on the GATT link (handle 0x8002 notify from glasses, write to 0x8005 to glasses):
    aa55 | len:u16be | ctrl:u16be | business:u8 | payload... | crc16:u16be
len counts [ctrl .. end of payload] (= total - 6); crc16 is CRC16/XMODEM (poly 0x1021,
init 0, MSB-first, no reflection) over those same bytes [offset 4 : -2].
An ACK frame is the special case business/ctrl where the whole thing is 'aa55 0004 <seq> <flag> <busid> crc'.

Inside an RNLINK (business 0x10) payload the first byte is a command; dev-info / auth use
TLV items: tag:u8 | length:u16be | value. Business ids (BUSINESS_ID_*) from the firmware table.
"""
import os
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


# ---- File transfer (core/file_transfer in the AP firmware) ---------------------------------------
# Rides rnlink business 0x11 (file_bt_send -> rnlink_send_payload(0x11, ...); handle_complete_packet
# routes 0x11 straight to ft_on_file_transfer_recv). Payload = protobuf filetransfer.TransferMessage
# (field numbers from the protobuf-c descriptors, rnlink-proto/filetransfer.proto):
#   TransferMessage { 1 file_info_sync, 2 file_info_ack, 3 file_chunk_req, 4 file_chunk, 5 file_recv_state }
#   FileInfoSync  { 1 uuid, 2 file_name, 3 file_size:u64, 4 md5 (lowercase hex), 5 bus_id }
#   FileInfoAck   { 1 uuid }
#   FileChunkReq  { 1 uuid, 2 chunk_id, 3 chunk_start:u64, 4 chunk_size }
#   FileChunk     { 1 uuid, 2 chunk_id, 3 chunk_start:u64, 4 chunk_size, 5 chunk_data }
#   FileRecvState { 1 uuid, 2 state (0 SUCCESS, 1 FAIL), 3 reason }
# PULL model, the glasses' file_receiver drives it: phone FileInfoSync -> glasses FileInfoAck +
# FileChunkReq (<= 0x5000 B each) -> phone FileChunk (chunk_size must equal len(chunk_data)) -> ...
# -> glasses md5-checks the whole buffer -> FileRecvState SUCCESS -> rnlink_if_on_file_recv hands
# {content, size, file_name, uuid, bus_id} to every feature's onFileRecv (bus_id picks the feature:
# 0x14 prompter, 9 FOTA). The prompter uses file_name as the script's did.
FT_BUSINESS = 0x11
FT_MSG = {1: 'file_info_sync', 2: 'file_info_ack', 3: 'file_chunk_req', 4: 'file_chunk',
          5: 'file_recv_state'}


class FileSender:
    """Phone side of the rnlink file transfer: offers one file at a time and serves chunk requests."""

    def __init__(self, phone):
        self.phone = phone
        self.cur = None             # dict(uuid, name, data, bus_id, on_done)
        self.queue = []
        self.done = []              # (uuid, state, reason) of finished transfers

    def send_file(self, bus_id, name, data, uuid=None, on_done=None):
        import hashlib, uuid as _uuid
        f = {'uuid': uuid or str(_uuid.uuid4()), 'name': name, 'data': data, 'bus_id': bus_id,
             'md5': hashlib.md5(data).hexdigest(), 'on_done': on_done, 'served': 0}
        if self.cur:
            self.queue.append(f); return f['uuid']
        self._start(f)
        return f['uuid']

    def _start(self, f):
        self.cur = f
        info = pb_encode({1: f['uuid'], 2: f['name'], 3: len(f['data']), 4: f['md5'], 5: f['bus_id']})
        self.phone.say('ft -> file_info_sync uuid=%s name=%s size=%d md5=%s bus=0x%02x' % (
            f['uuid'], f['name'], len(f['data']), f['md5'], f['bus_id']))
        self._tx({1: info})

    def _tx(self, msg):
        self.phone.tx(FT_BUSINESS, pb_encode(msg), ctrl=self.phone._pctrl())

    def on_message(self, payload):
        tm = pb_decode(payload)
        for num, body in tm.items():
            m = pb_decode(body) if isinstance(body, bytes) else {}
            name = FT_MSG.get(num, 'msg%d' % num)
            uuid = m.get(1, b'').decode('latin1') if isinstance(m.get(1), bytes) else ''
            f = self.cur
            if num == 3:                            # chunk request
                cid, start, size = m.get(2, 0), m.get(3, 0), m.get(4, 0)
                self.phone.say('ft <- file_chunk_req uuid=%s id=%d start=%d size=%d' % (uuid, cid, start, size))
                if not f or f['uuid'] != uuid:
                    self.phone.say('ft   (no such transfer)'); continue
                data = f['data'][start:start + size]
                f['served'] = max(f['served'], start + len(data))
                self._tx({4: pb_encode({1: uuid, 2: cid, 3: start, 4: len(data), 5: data})})
            elif num == 5:                          # receive state
                state, reason = m.get(2, 0), m.get(3, b'').decode('utf8', 'replace') if m.get(3) else ''
                self.phone.say('ft <- file_recv_state uuid=%s state=%s %s' % (
                    uuid, 'SUCCESS' if state == 0 else 'FAIL', reason))
                self.done.append((uuid, state, reason))
                if f and f['uuid'] == uuid:
                    self.cur = None
                    if f['on_done']:
                        f['on_done'](state == 0, reason)
                    if self.queue:
                        self._start(self.queue.pop(0))
            else:
                self.phone.say('ft <- %s %s' % (name, {k: (v if isinstance(v, int) else v[:64])
                                                       for k, v in m.items()}))


class RnlinkPhone:
    """Phone-side rnlink logic: completes the dev-info + auth handshake, then services features.

    `send` writes a raw frame (bytes) to the glasses; `say` logs; `central` exposes glasses_addr.
    """

    def __init__(self, say, send, central):
        import os
        self.say, self.send, self.central = say, send, central
        self.notif_demo = bool(os.environ.get('NOTIF_DEMO'))
        self.call_demo = bool(os.environ.get('CALL_DEMO'))
        self.record_demo = bool(os.environ.get('RECORD_DEMO'))
        self.settings_demo = bool(os.environ.get('SETTINGS_DEMO'))
        self.todo_demo = bool(os.environ.get('TODO_DEMO'))
        self.prompt_probe = bool(os.environ.get('PROMPT_PROBE'))
        self.prompt_demo = bool(os.environ.get('PROMPT_DEMO'))
        _lt = os.environ.get('PROMPT_LTYPE')
        self.prompter_list_type = int(_lt) if _lt else None
        self.started = False
        self.dev_info_done = False
        self.authed = False
        self.evt = 0; self.later = []             # (connection event number, raw business-15 payload): timed sends
        self.rand = bytes.fromhex('a5b4c3d2')
        self.glasses_dev_addr = b''
        self.ft = FileSender(self)
        self.ota_dir = os.environ.get('OTA_DIR')          # OTA "files" set to offer (OtaFileInfo.json)
        self.ota_files = [n for n in os.environ.get('OTA_FILES', '').split(',') if n]  # subset; empty = all

    # ---- outbound ----
    def tick(self):
        """Called once per BLE connection event (30 ms of emulated time): sends what is due."""
        self.evt += 1
        while self.later and self.later[0][0] <= self.evt:
            self.tx(0x0f, self.later.pop(0)[1])
        while getattr(self, 'later_files', None) and self.later_files[0][0] <= self.evt:
            _, name, data = self.later_files.pop(0)
            self.ft.send_file(0x12, name, data)
        while getattr(self, 'bench_q', None) and self.bench_q[0][0] <= self.evt:
            self.bench_step(self.bench_q.pop(0)[1])

    # ---- SPARE_SCRIPT: timed phone actions for the Spare verification bench (Tests/spare/) ----
    # SPARE_SCRIPT=<json list>; each step {"at": <seconds of emulated time after auth>, ...} and one of
    #   "notif": {title, content, app, appid, subtitle, uid, type(1 add / 2 remove / 3 update), category}
    #            -> rnlink business 0x15 (the Android-role notification channel the stock card renders)
    #   "raw":  "<hex>" or "@<file>"   -> raw business-15 message (SGA1 / SGN1 / SGI1 ... as the Spare App bridge sends)
    #   "file": {"name": "spare-nav.sgn", "path": "<file>"} -> rnlink file channel (business 0x12)
    #   "setting": {"key": ..., "value"/"data": ...} -> general_setting push
    # Each step is logged as "BENCH t=<s> evt=<n> ..." so frames can be lined up with it.
    def bench_load(self):
        import json
        path = os.environ.get('SPARE_SCRIPT')
        if not path:
            return
        steps = json.load(open(path))
        self.bench_q = sorted([(self.evt + 1 + int(float(st['at']) * 1000 / 30), st) for st in steps], key=lambda x: x[0])
        self.bench_evt0 = self.evt
        self.say('BENCH loaded %d steps from %s' % (len(steps), path))

    def bench_step(self, st):
        t = (self.evt - self.bench_evt0) * 0.03
        if 'notif' in st:
            n = dict(st['notif'])
            self.say('BENCH t=%.2f evt=%d notif uid=%s type=%s' % (t, self.evt, n.get('uid'), n.get('type', 1)))
            self.push_notification(0x15, n.get('title', ''), n.get('content', ''), app=n.get('app', 'WhatsApp'),
                                   appid=n.get('appid', 'com.whatsapp'), subtitle=n.get('subtitle', ''),
                                   uid=str(n.get('uid', '1')), category=int(n.get('category', 0)),
                                   ntype=int(n.get('type', 1)), phone_number=n.get('phone', ''))
        elif 'raw' in st:
            r = st['raw']
            data = open(r[1:], 'rb').read() if r.startswith('@') else bytes.fromhex(r)
            self.say('BENCH t=%.2f evt=%d raw b15 %d B %s' % (t, self.evt, len(data), data[:8].hex()))
            self.tx(0x0f, data)
        elif 'file' in st:
            f = st['file']
            self.say('BENCH t=%.2f evt=%d file %s' % (t, self.evt, f['name']))
            self.ft.send_file(0x12, f['name'], open(f['path'], 'rb').read())
        elif 'setting' in st:
            g = dict(st['setting']); k = g.pop('key')
            self.say('BENCH t=%.2f evt=%d setting %s %s' % (t, self.evt, k, g))
            self.push_general_setting(k, **g)
        else:
            self.say('BENCH t=%.2f evt=%d marker %s' % (t, self.evt, st.get('mark', '')))

    def tx(self, business, payload, ctrl=0):
        self.send(frame(business, payload, ctrl=ctrl))

    def _pctrl(self):
        self._pctrl_n = getattr(self, '_pctrl_n', -1) + 1
        return self._pctrl_n

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
                tlv(0x13, bytes([2])) + tlv(0x14, b'RayNeo') + tlv(0x16, b'VirtualPhone') +
                # Strix OS 1.0.6.11 parses 7 TLVs in a row and silently drops a shorter version request
                # (the official Android app adds 0x1b=0); 1.0.4.12 ignores the extra tag.
                tlv(0x1b, bytes([0])))

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
            # life-log audio batches (VOICE_ASSISTANT_CMD 163, ~7.5 KB) arrive whole but fail the CRC check
            # here; their protobuf decodes cleanly, so count them anyway
            if business == 0x0d and pb_decode(payload).get(2) == self.ALWAYS_ON_AUDIO:
                self.on_assistant(payload)
            return                              # skip fragmented/partial frames for now
        if business == 0x10 and len(payload) >= 3:
            cmd = payload[0]; data = payload[3:]
            self.on_rnlink_cmd(cmd, data)
        elif business == 0x13:
            self.sub_bus = 0x13
            self.on_aisubtitle(payload)
        elif business == 0x17 and os.environ.get('QA_SCRIPT'):
            # 有问必答 (ConversationAssist) speaks the same PbMsg/JSON shapes as AiSubtitle on business 0x17.
            self.sub_bus = 0x17
            os.environ['SUB_SCRIPT'] = os.environ['QA_SCRIPT']
            self.on_aisubtitle(payload)
        elif business == 0x0d:
            self.on_assistant(payload)
        elif business == 0x14:
            self.on_prompter(payload)
        elif business == FT_BUSINESS:
            self.ft.on_message(payload)
        elif business == 0x09:
            self.on_ota(payload)
        elif business in (0x0f, 0x0e, 0x0c, 0x18):
            self.on_feature(business, payload)

    # ---- AiSubtitle (live captions / translation), business 0x13 ----
    # PbMsg{type, message=JSON}: type 1 START_REQUEST, 2 START_REPLY, 3 END_REQUEST, 5 DISPLAY_TEXT,
    # 6 RETRY_REQUEST, 7/8 SETTINGS_SYNC. The phone accepts a start and streams DISPLAY_TEXT {sid,src,dst}.
    def on_aisubtitle(self, payload):
        import json
        pb = pb_decode(payload); typ = pb.get(2)
        try:
            msg = json.loads(pb.get(3, b'{}').decode())
        except Exception:
            msg = {}
        self.say('rnlink AiSubtitle type=%s %s' % (typ, msg))
        sid = msg.get('sid', '')
        if typ == 1:                      # START_REQUEST -> accept (code 1), then stream a caption
            # DomainConverter::jsonToMessage classifies by JSON KEYS, not the PbMsg type:
            # START_REPLY needs both "code" and "final_settings". code 1 = accepted.
            st = msg.get('settings', {})
            reply = {'sid': sid, 'code': 1, 'text': '',
                     'final_settings': {
                         'mode': st.get('mode', 'classic'),
                         'source_language': st.get('source_language', 'en-US'),
                         'target_language': st.get('target_language', 'zh-CN'),
                         'save_audio': st.get('save_audio', False),
                         'direction': st.get('direction', 'ahead')}}
            self.tx(getattr(self, 'sub_bus', 0x13), pb_msg(2, message=json.dumps(reply)))
            self.say('rnlink AiSubtitle -> START_REPLY (accept) sid=%s' % sid)
            self.caption_sid = sid
            # Stream a short scripted transcript; re-pushed on each weather tick so a caption is
            # always freshly on-screen when a frame is captured (a real session streams continuously).
            self.caption_lines = [
                ('Hello from the virtual phone.', '来自虚拟手机的字幕'),
                ('Live captions are working now.', '实时字幕现在可以用了'),
                ('This text comes over Bluetooth.', '这段文字通过蓝牙传来'),
            ]
            self.caption_idx = 0
            self.caption_seq = 1
            self.caption_tick = 0
            # SUB_SCRIPT=<json>: replay a timed caption script instead of the demo lines (research runs).
            # [{"at": seconds after START_REPLY, "type": PbMsg type, "msg": {...}}]; "$sid" is replaced.
            if os.environ.get('SUB_SCRIPT'):
                self.caption_lines = None
                self.sub_script = json.load(open(os.environ['SUB_SCRIPT']))
                self.sub_t0 = None
                self.sub_i = 0
                self.say('rnlink AiSubtitle script: %d steps' % len(self.sub_script))
                return
            # mode 2 = bilingual (source + translation both shown); status 1 = ongoing, so the
            # caption stays on screen (status 2 is "final" and reverts the view to listening).
            self.push_caption(*self.caption_lines[0], seq=self.caption_seq, mode=2, status=1)
        elif typ == 7:                    # SETTINGS_SYNC_REQUEST -> reply (code + effective_config)
            self.tx(0x13, pb_msg(8, message=json.dumps({'sid': sid, 'code': 0, 'effective_config': {}})))

    def push_caption(self, src, dst='', seq=0, mode=2, status=1):
        import json
        # DISPLAY_TEXT is classified by keys "mode"+"status"; the text lives in the nested
        # "content" object (source_transcript / target_translation). "mode" is the translationMode
        # the view switches on (0 = Unknown -> reverts to listening); bilingual/transcription.
        # status: 1 = partial/ongoing (keeps the caption on screen), 2 = final.
        sid = getattr(self, 'caption_sid', '')
        msg = {'sid': sid, 'mode': mode, 'status': status,
               'content': {'source_transcript': src, 'target_translation': dst,
                           'speaker_label': '', 'label': ''}}
        self.say('rnlink AiSubtitle -> DISPLAY_TEXT mode=%s status=%s %r / %r' % (mode, status, src, dst))
        self.tx(0x13, pb_msg(5, message=json.dumps(msg), sequence=seq))

    # ---- AI voice assistant, business 0x0d (VOICE_ASSISTANT_CMD) ----
    # Glasses send type 1 WAKEUP {"rc","linkType"} on double-click. The phone answers the voice
    # request: ASR text (handleAsrText, keys {text, final}) then the NLP answer
    # (handleNlpIntentResult / NLP text). We use a local stand-in for the recognized query + answer.
    def on_assistant(self, payload):
        import json, os
        pb = pb_decode(payload); typ = pb.get(2)
        try:
            msg = json.loads(pb.get(3, b'{}').decode())
        except Exception:
            msg = {}
        if typ == self.ALWAYS_ON_AUDIO:   # life-log audio (Opus frames), logged sparsely
            self.on_alwayson_audio(pb, msg)
            return
        self.say('rnlink VOICE_ASSISTANT_CMD type=%s %s' % (typ, msg))
        if typ == self.ALWAYS_ON_WAKEUP:  # 全天智记 VAD session start -> accept it as the phone app does
            self.alwayson_task = getattr(self, 'alwayson_task', 0) + 1
            reply = {'taskId': 'emu-lifelog-%d' % self.alwayson_task,
                     'idleTimeoutSec': int(os.environ.get('LIFELOG_IDLE_SEC', '30'))}
            self.tx(0x0d, pb_msg(self.ALWAYS_ON_WAKEUP_RECV, message=json.dumps(reply)))
            self.say('rnlink VOICE_ASSISTANT -> ALWAYS_ON_WAKEUP_RECV %s' % reply)
            return
        if typ == 1:                      # WAKEUP -> start a stand-in voice session
            if os.environ.get('ASSIST_PROBE'):
                for t in range(2, 60):    # map type numbers: glasses log the received type name
                    self.tx(0x0d, pb_msg(t, message=json.dumps({'text': 'probe-%d' % t, 'final': True})))
                return
            self.assist_answer()

    # 全天智记 / life-log (AlwaysOnMessageProcessor), message-type table at 0x104975c4 in the stock AP:
    # 161 ALWAYS_ON_WAKEUP_SEND (glasses: VAD heard speech), 162 ALWAYS_ON_WAKEUP_RECV (phone: {taskId,
    # idleTimeoutSec} -> recording starts), 163 ALWAYS_ON_AUDIO_SEND (glasses: audio), 165/166 ABORT, 168 page state.
    ALWAYS_ON_WAKEUP, ALWAYS_ON_WAKEUP_RECV, ALWAYS_ON_AUDIO = 161, 162, 163

    def on_alwayson_audio(self, pb, msg):
        import os
        data = pb.get(4, b'') or pb.get(3, b'')
        if not isinstance(data, (bytes, bytearray)): data = str(data).encode()
        self.alwayson_frames = getattr(self, 'alwayson_frames', 0) + 1
        self.alwayson_bytes = getattr(self, 'alwayson_bytes', 0) + len(data)
        n = self.alwayson_frames
        if n <= 3 or n % 50 == 0:
            self.say('rnlink VOICE_ASSISTANT_CMD ALWAYS_ON_AUDIO_SEND #%d %d bytes (total %d) %s' % (
                n, len(data), self.alwayson_bytes, msg))
        path = os.environ.get('LIFELOG_AUDIO')   # optional: append each message's audio payload
        if path:
            with open(path, 'ab') as f: f.write(len(data).to_bytes(4, 'little') + bytes(data))

    # Assistant message types (probed from the glasses' dispatchMessage log):
    ASSIST_ASR = 5          # ASR_TEXT {text, final} -> shows the recognized query
    ASSIST_THINKING = 10    # THINKING_STATUS
    ASSIST_DOMAIN = 32      # DOMAIN (NLP answer content routed to DomainRuntime)
    ASSIST_NLP_DONE = 11    # NLP_TEXT_DISPLAY_COMPLETE

    ASSIST_STATE = 9        # STATE_CHANGE {rc} -> drives the session state machine

    def assist_answer(self, query='今天天气怎么样？', answer='上海今天多云，23°C，适合外出，记得带把伞。'):
        import json
        # Drive the session out of IdleState: STATE_CHANGE event (5) with rc 4 switches
        # Idle -> Listening (IdleState::onEvent, given wakeupType 8 from the crown wakeup).
        self.tx(0x0d, pb_msg(self.ASSIST_STATE, message=json.dumps({'rc': 4})))
        self.say('rnlink VOICE_ASSISTANT -> STATE_CHANGE listening')
        # Stand-in voice session: recognized query (ASR final), then the NLP answer text.
        self.tx(0x0d, pb_msg(self.ASSIST_ASR, message=json.dumps({'text': query, 'final': True})))
        self.say('rnlink VOICE_ASSISTANT -> ASR_TEXT %r' % query)
        # Listening -> next state (rc 3) so the session moves past listening to show the answer.
        self.tx(0x0d, pb_msg(self.ASSIST_STATE, message=json.dumps({'rc': 3})))
        self.say('rnlink VOICE_ASSISTANT -> STATE_CHANGE answering')
        # DOMAIN answer (handleDomainMessage schema): "answer" is a NESTED object {text, isFinal};
        # the glasses read answer.text / answer.isFinal and render it via dispatchNlpTextAction.
        # sid + round tie it to the session.
        self.assist_sid = 'standin-sid-1'
        self.assist_text = answer
        self.send_assist_answer()
        # Re-send the answer on the next few connection events: on a fast emulator the first DOMAIN
        # can race the Listening->Processing transition and be dropped before ChatDomain is ready.
        self.assist_resend = 4

    def send_assist_answer(self):
        import json
        sid, answer = self.assist_sid, self.assist_text
        self.tx(0x0d, pb_msg(self.ASSIST_STATE, message=json.dumps({'rc': 3})))   # ensure Processing
        self.tx(0x0d, pb_msg(self.ASSIST_DOMAIN, message=json.dumps(
            {'domain': 'chat', 'intent': 'chat', 'sid': sid, 'round': 1,
             'answer': {'text': answer, 'isFinal': True}})))
        self.say('rnlink VOICE_ASSISTANT -> DOMAIN answer %r' % answer)
        self.tx(0x0d, pb_msg(self.ASSIST_NLP_DONE, message=json.dumps(
            {'sid': sid, 'text': answer, 'isFinal': True, 'final': True})))

    @staticmethod
    def sge1_line(text):
        """`SGE1 event=<n> caps=<b12>.<b16..b19> len=<n> raw=<hex>` for a glasses event (docs/peer-log.md), else None.

        Any LAUNCHER_CMD JSON whose payload.data is hex starting with 'SGE1' (cmd spare_ai_v1 today). Capability
        bytes as the Spare app reads them (ios-next Assistant.swift): byte 12 (capability one; on events 4-6 it is
        the echoed seq), 16 (two), 17 (three), 18 / 19 (event 16: extended / extended 2); '--' past the end."""
        import json
        try:
            m = json.loads(text)
            raw = bytes.fromhex(m['payload']['data'])
        except Exception:
            return None
        if raw[:4] != b'SGE1' or len(raw) < 6:
            return None
        cap = lambda i: '%02x' % raw[i] if i < len(raw) else '--'
        return 'SGE1 event=%d caps=%s.%s len=%d raw=%s' % (
            raw[5], cap(12), ''.join(cap(i) for i in range(16, 20)), len(raw), raw.hex())

    def log_sge1(self, text):
        if 'SGE1' in text or '53474531' in text:
            line = self.sge1_line(text)
            if line:
                self.say(line)

    def on_feature(self, business, payload):
        pb = pb_decode(payload)
        typ = pb.get(2)
        msg = pb.get(3, b'')
        try:
            text = msg.decode()
        except Exception:
            text = msg.hex()
        self.say('rnlink %s type=%s msg=%s' % (BUSINESS.get(business, hex(business)), typ, text))
        if business == 0x0f:
            self.log_sge1(text)
        if business == 0x0e and typ == 1 and __import__('os').environ.get('REC_ACK'):
            # REC_ACK=<type>: research probe, acknowledge the glasses' recorder start (RECORD_CMD) like a phone would.
            import json
            try:
                m = json.loads(text)
            except Exception:
                m = {}
            if m.get('action') == 1 and m.get('code') == 1:
                ack = {'uuid': m.get('uuid', ''), 'action': 1, 'mode': m.get('mode', 1), 'code': int(__import__('os').environ.get('REC_ACK_CODE', '1')),
                       'sid': m.get('sid', ''), 'type': m.get('type', 1), 'text': ''}
                self.say('rnlink RECORD_CMD -> ack type=%s %s' % (__import__('os').environ['REC_ACK'], ack))
                self.tx(0x0e, pb_msg(int(__import__('os').environ['REC_ACK']), message=json.dumps(ack)))
        if business != 0x0f:
            return
        # SPARE_SGD1=<json file {arg: {key: value}}>: answer a Spare app's data request (SGE1 event 12 op 3) with a
        # raw SGD1 business-15 message, as the Spare iPhone app's bridge would (docs/PROTOCOL-apps.md).
        if 'spare_ai_v1' in text and __import__('os').environ.get('SPARE_SGD1'):
            import json, struct
            try:
                raw = bytes.fromhex(json.loads(text)['payload']['data'])
            except Exception:
                raw = b''
            if raw[:4] == b'SGE1' and raw[5] == 12:
                self.say('spare-app SGE1 event 12 op=%d a=%d b=%d tail=%s' % (raw[13], raw[14], raw[15], raw[17:32].hex()))
            if raw[:4] == b'SGE1' and raw[5] == 12 and raw[13] == 3:
                import os
                h, n = raw[17:21], raw[21]
                arg = raw[22:22 + n].decode('utf8', 'replace')
                table = json.load(open(__import__('os').environ['SPARE_SGD1']))
                # key "<request index>:<arg>" first, then "<arg>"; a list = several replies in order (e.g. dictation partials)
                replies = table.get('%d:%s' % (raw[14], arg), table.get(arg, {}))
                # list entries: {key: value} = one reply; {"_after": s} = wait s seconds (emulated, 30 ms per connection
                # event); {"_sgb1": png} = send that picture as SGB1 chunks (one per event); "_seq0": true = push (seq 0)
                due = self.evt + 1
                for vals in (replies if isinstance(replies, list) else [replies]):
                    if '_after' in vals:
                        due += int(float(vals['_after']) * 1000 / 30); continue
                    if '_sgb1' in vals:
                        from PIL import Image
                        im = Image.open(os.path.join(os.path.dirname(os.environ['SPARE_SGD1']), vals['_sgb1'])).convert('L')
                        w, hh = im.size; px = [v >> 4 for v in im.getdata()]
                        data = bytes(px[i] << 4 | px[i + 1] for i in range(0, len(px), 2))
                        for k in range(0, (len(data) + 199) // 200):
                            part = data[k * 200:(k + 1) * 200]
                            last = 1 if (k + 1) * 200 >= len(data) else 0
                            self.later.append((due, b'SGB1\x01' + bytes([last]) + h + struct.pack('<HHH', w, hh, k) + part)); due += 1
                        self.say('spare-app -> SGB1 %s %dx%d (%d chunks)' % (vals['_sgb1'], w, hh, (len(data) + 199) // 200)); continue
                    seq = 0 if vals.get('_seq0') else raw[15]
                    pairs = [bytes([len(k)]) + k.encode() + bytes([len(v.encode())]) + v.encode() for k, v in vals.items() if not k.startswith('_')]
                    msgs, cur = [], []
                    for p in pairs:                      # SGD1 <= 240 bytes: split, final flag on the last one
                        if cur and (12 + sum(map(len, cur)) + len(p) > 240 or len(cur) == 16):   # <= 240 B, <= 16 keys
                            msgs.append(cur); cur = []
                        cur.append(p)
                    msgs.append(cur)
                    for i, m in enumerate(msgs):
                        self.later.append((due, b'SGD1\x01' + bytes([len(m)]) + h + bytes([seq, 1 if i == len(msgs) - 1 else 0]) + b''.join(m)))
                    self.say('spare-app -> SGD1 seq=%d k=%d arg=%s %s (%d msgs)' % (seq, raw[14], arg, vals, len(msgs)))
        # Answer the glasses' time request with the current wall-clock + timezone.
        if 'sync_time' in text:
            import json, time as _t
            off = -_t.timezone if not _t.daylight else -_t.altzone
            payload_json = json.dumps({'cmd': 'sync_time', 'payload': {
                'utc': int(_t.time()), 'offset': off, 'timezone': 'Asia/Shanghai'}})
            self.say('rnlink -> sync_time reply %s' % payload_json)
            self.tx(0x0f, pb_msg(typ or 6, message=payload_json))
        # Only an explicit request gets a weather push. The glasses answer every push with an ack
        # {"cmd":"current_weather_update","payload":{"value":0}} (type 19); answering that ack with
        # another push was an endless ping-pong (~1000 round trips per scenario) that floods the AP
        # until its analytics uploader races ("pack size mismatch", heap assert in rayneo_analyticslog).
        if 'current_weather_request' in text:
            self.push_weather()

    def on_event(self, n):
        """Every BLE connection event (SUB_EVENT_S seconds of virtual time each): timed caption script."""
        script = getattr(self, 'sub_script', None)
        if not script:
            return
        import json
        if self.sub_t0 is None:
            self.sub_t0 = n
        dt = float(os.environ.get('SUB_EVENT_S', '0.03'))
        while self.sub_i < len(script) and (n - self.sub_t0) * dt >= script[self.sub_i]['at']:
            st = script[self.sub_i]; self.sub_i += 1
            text = json.dumps(st['msg'], ensure_ascii=False).replace('$sid', getattr(self, 'caption_sid', ''))
            self.caption_seq = getattr(self, 'caption_seq', 0) + 1
            self.say('rnlink AiSubtitle script[%d] t=%.2f type=%d %s' % (self.sub_i - 1, st['at'], st['type'], text[:160]))
            self.tx(getattr(self, 'sub_bus', 0x13), pb_msg(st['type'], message=text, sequence=self.caption_seq))

    def on_tick(self):
        """Periodic phone-side work, called by the BLE central every few connection events (virtual
        time, independent of host speed); a no-op until the rnlink link is authenticated."""
        if not self.authed:
            return
        # Re-send the assistant answer a few times (spaced in time) so it lands after the glasses
        # have fully entered ProcessingState, even on a fast emulator.
        if getattr(self, 'assist_resend', 0) > 0:
            self.assist_resend -= 1
            self.send_assist_answer()
        # A few more notifications (new UIDs, so they are not de-duplicated), spaced like a real
        # phone's, so a banner is on screen when a frame is captured.
        if getattr(self, 'notif_demo', False):
            self.notif_tick = getattr(self, 'notif_tick', 0) + 1
            if self.notif_tick % 6 == 0 and getattr(self, 'notif_uid', 1) < 6:
                self.notif_uid = getattr(self, 'notif_uid', 1) + 1
                self.push_notification(0x15, 'Alice', 'Hello from the virtual phone!',
                                       app='WhatsApp', uid=str(self.notif_uid), ntype=1)
        # Incoming-call notification: raise it once, then re-assert it a few times (like a phone
        # keeps the call ringing) so the call UI is on screen when a frame is captured.
        if getattr(self, 'call_demo', False):
            self.call_tick = getattr(self, 'call_tick', 0) + 1
            if self.call_tick == 2 or (self.call_tick > 2 and self.call_tick % 6 == 0):
                self.push_call('+15550123', name='Virtual Phone')
        # Caption stream: keeps a line on screen.
        if getattr(self, 'caption_lines', None):
            # Advance to the next distinct line every 8 ticks (a few seconds apart);
            # push each line once so the caption reads cleanly instead of accumulating repeats.
            self.caption_tick += 1
            if self.caption_tick % 8 == 0:
                if self.caption_idx < len(self.caption_lines) - 1:
                    self.caption_idx += 1
                self.caption_seq += 1
                self.push_caption(*self.caption_lines[self.caption_idx],
                                  seq=self.caption_seq, mode=2, status=1)

    # ---- phone-driven features ----
    # ---- Prompter / teleprompter, business 0x14 (PROMPTER) ----
    # PbMsg type -> glasses handler (probed): 1 handleFileListUpdate, 2 handleFileTransfer,
    # 3 handleRemoteStart, 4 pause, 6 stop, 10 stateQuery. Schema (JsonHelper parsers):
    #   file-list (type 1): {type, total, chunkinfo:{chunkid,total_items,islast}, items:[...]}
    #     NB: chunkid/total_items/islast live INSIDE chunkinfo (JsonHelper::parseFileListUpdateMsg
    #     reads them from the chunkinfo object). "type" is the updateFileList switch: 1 FullSync.
    #     item: {did,pin,title,offset,timestamp,timezone,preview}
    #   file-transfer (type 2): {action,did,total,chunkid,islast,offset}; action 1 = request (opens
    #     the prompter, PrompterAPI::requestStartUi), 2 = cancel. No content in it: the glasses reply
    #     type 2 {action:2,...,code:1} = ready, and the script BYTES then go over the rnlink file
    #     transfer (business 0x11, FileSender) with bus_id 0x14 and file_name = did. Once
    #     notifyFileRecv has built the preview the glasses send type 2 code 7.
    #   remote-start (type 3): {action:2,code,did,pageOffset,highLightOffset,total}; on a loaded
    #     preview code 1 starts it (0x17 confirm / 0x18 cancel a pending start).
    #   mode setting (type 7): {action:1,did,countdown,scroll,speed,gear,depth,size,width,leading};
    #     scroll 2 = auto scroll at `speed` (the reading highlight advances and lines scroll up).
    # Flow: list -> transfer request -> (code 1) file transfer -> (code 7) mode setting + start.
    # The glasses ack the list with type 1 {action,type,code,chunkid} and report progress as type 8.
    def on_prompter(self, payload):
        import json
        pb = pb_decode(payload); typ = pb.get(2)
        raw = pb.get(3, b'')
        try:
            msg = json.loads(raw.decode()) if raw else {}
        except Exception:
            msg = {}
        self.say('rnlink PROMPTER <- type=%s %s' % (typ, msg))
        # The glasses reply to the transfer request with type 2 {action:2, total, code:1} = "ready, send
        # the content": the did is now the active receive session, so push the script file.
        if typ == 2 and msg.get('code') == 1 and not getattr(self, 'prompter_sent_content', False):
            self.prompter_sent_content = True
            self.send_prompter_file()
            return
        # type 2 code 7 = the script content arrived over the file transfer and the preview is ready
        # (notifyFileRecv -> notifyPreviewReady): now the remote start can actually start scrolling.
        if typ == 2 and msg.get('code') == 7 and not getattr(self, 'prompter_started', False):
            self.prompter_started = True
            self.set_prompter_mode()
            self.remote_start_prompter(code=1)
            return
        # The glasses pull the list on connect (requestFileListSync). Only the prompter demo answers
        # with a script: a pushed script now really opens and runs the prompter, which would take
        # over the screen in every other phone scenario.
        if self.prompt_demo and not getattr(self, 'prompter_sent', False):
            self.push_prompter()

    def push_prompter(self, text=None, title='演示提词稿'):
        import json, time as _t
        if text is None:
            text = ('欢迎使用提词器。\n'
                    '这是一段通过蓝牙从虚拟手机推送的演示文稿。\n'
                    '文稿内容经由文件传输通道发送到眼镜，并通过校验。\n'
                    '文字会自动向上滚动，方便你在演讲时朗读。\n'
                    '你可以在手机上调整滚动速度、字号和行距。\n'
                    '现在字幕、通知、语音助手都已经可以在模拟器里使用。\n'
                    '天气、待办事项和设置同步也都由虚拟手机驱动。\n'
                    '固件升级同样走蓝牙分片传输，并在眼镜上校验每个文件。\n'
                    '演讲之前，记得先把文稿完整地读一遍。\n'
                    '保持语速平稳，眼神自然地看向观众。\n'
                    '遇到停顿也不要紧张，提词器会等你。\n'
                    '祝你演讲顺利！')
        did = getattr(self, 'prompter_did', '1792240000777')
        content = text.encode('utf-8')
        now = int(_t.time() * 1000)
        self.prompter_did = did
        self.prompter_content = content
        lst = {'type': 3, 'total': 1,
               'chunkinfo': {'chunkid': 0, 'total_items': 1, 'islast': True},
               'items': [{'did': did, 'pin': 0, 'title': title, 'offset': 0,
                          'timestamp': now, 'timezone': 8, 'preview': text[:24]}]}
        if getattr(self, 'prompter_list_type', None) is not None:
            lst['type'] = self.prompter_list_type
        self.say('rnlink PROMPTER -> file-list (type=%s) %s' % (lst['type'], did))
        self.tx(0x14, pb_msg(1, message=json.dumps(lst)), ctrl=self._pctrl())
        # Request the transfer right behind the list; the content and the start follow the glasses'
        # type-2 replies (code 1 ready, code 7 preview loaded).
        self.send_prompter_transfer()
        self.prompter_sent = True

    def send_prompter_transfer(self):
        import json
        did, content = self.prompter_did, self.prompter_content
        # type 2: file transfer, action 1 = request/send (triggers PrompterAPI::requestStartUi and
        # launches the prompter view). The bytes follow over the file transfer once the glasses are ready.
        meta = {'action': 1, 'did': did, 'total': len(content), 'chunkid': 0, 'islast': True, 'offset': 0}
        self.say('rnlink PROMPTER -> file-transfer request (action=1) %d bytes' % len(content))
        self.tx(0x14, pb_msg(2, message=json.dumps(meta)), ctrl=self._pctrl())

    def send_prompter_file(self):
        # The script bytes travel over the rnlink file transfer (business 0x11), bus_id 0x14, with
        # file_name = the script's did (PrompterRnLinkMsgProcessor::notifyFileRecv matches it).
        self.say('rnlink PROMPTER -> script via file transfer, %d bytes' % len(self.prompter_content))
        self.ft.send_file(0x14, self.prompter_did, self.prompter_content)

    def set_prompter_mode(self, scroll=None, speed=None, gear=None):
        import json
        # type 7 ModeSetting (handleModeSetting): action 1 = apply the reading settings for a did.
        # PROMPT_SCROLL / PROMPT_SPEED / PROMPT_GEAR override (scroll 0 is the stored default).
        env = lambda k, d: int(os.environ.get(k, d))
        msg = {'action': 1, 'did': self.prompter_did, 'countdown': 0,
               'scroll': env('PROMPT_SCROLL', 2) if scroll is None else scroll,
               'speed': env('PROMPT_SPEED', 40) if speed is None else speed,
               'gear': env('PROMPT_GEAR', 3) if gear is None else gear,
               'depth': 0, 'size': 0, 'width': 0, 'leading': 0}
        self.say('rnlink PROMPTER -> mode setting %s' % msg)
        self.tx(0x14, pb_msg(7, message=json.dumps(msg)), ctrl=self._pctrl())

    def remote_start_prompter(self, code=0):
        import json
        did = getattr(self, 'prompter_did', '1792240000777')
        total = len(getattr(self, 'prompter_content', b''))
        # handleRemoteStart: "action" (bStack_38) must be 2 to enter the start logic; "code"
        # (bStack_1c) 0x17 confirms a pending start, 0x18 cancels; on a loaded preview code 1 approves
        # the start ("cache local preview start approval until countdown ends"), any other code just
        # keeps the preview.
        msg = {'action': 2, 'code': code, 'did': did, 'pageOffset': 0, 'highLightOffset': 0, 'total': total}
        self.say('rnlink PROMPTER -> remote-start (action=2) %s' % did)
        self.tx(0x14, pb_msg(3, message=json.dumps(msg)), ctrl=self._pctrl())

    # ---- OTA, business 0x09 (FOTA_MODULE; OtaTransferRnLinkMsgProcessor) ----
    # PbMsg{type, message=JSON[, data]}. The phone starts the session, then the glasses drive it with
    # requests the phone answers with the same type (OtaTransferRnLinkMsgProcessor::receiveMessage):
    #   1 GetGlassOsVersion, 2 BatteryLevel, 3 HasEnoughNandFlash {OtaSize}, 0xb IsIdle  (phone prechecks)
    #   4 StartGlassTransferPage {Mode:1..4}       phone -> glasses: launches com.rayneo.liteos.ota
    #   5 glasses asks the package version  -> phone {OtaVersion}
    #   6 glasses asks the package info {OtaVersion} -> phone: legacy "files" mode = the OtaFileInfo.json
    #     array [{Name,Size,Md5,BurnMode,BurnAddr,BurnPath}] (or {PackageInfoVersion,PackageType:"zip",Files})
    #   7 glasses requests a slice {Name,Start,Size} (Size <= 0xc800) -> phone echoes the JSON with the
    #     slice bytes in PbMsg.data (len must equal Size). Each finished file is MD5-checked
    #     ("file %s MD5 OK"); after the last: "FILES all files verified" and type 9 GOTO_INSTALL ->
    #     reboot into the installer.
    # Slices go inline in PbMsg.data; the business-0x11 file transfer is not used by OTA.
    def ota_package(self):
        import json
        files = json.load(open(os.path.join(self.ota_dir, 'OtaFileInfo.json')))
        if self.ota_files:
            files = [f for f in files if f['Name'] in self.ota_files]
        return files

    def ota_version(self):
        import json
        try:
            return json.load(open(os.path.join(self.ota_dir, 'baseline.json')))['versionLabel']
        except Exception:
            return '1.0.4.12'

    def start_ota(self):
        import json
        size = sum(f['Size'] for f in self.ota_package())
        self.say('rnlink OTA -> prechecks + start transfer page (%d files, %d bytes)' % (
            len(self.ota_package()), size))
        self.tx(0x09, pb_msg(1, message='{}'))
        self.tx(0x09, pb_msg(2, message='{}'))
        self.tx(0x09, pb_msg(3, message=json.dumps({'OtaSize': size})))
        self.tx(0x09, pb_msg(0xb, message='{}'))
        self.tx(0x09, pb_msg(4, message=json.dumps({'Mode': 1})))

    def on_ota(self, payload):
        import json
        pb = pb_decode(payload); typ = pb.get(2); raw = pb.get(3, b'')
        try:
            msg = json.loads(raw.decode()) if raw else {}
        except Exception:
            msg = {'raw': raw[:80]}
        self.say('rnlink OTA <- type=%s %s' % (typ, msg))
        if not self.ota_dir:
            return
        if typ == 5:
            self.tx(0x09, pb_msg(5, message=json.dumps({'OtaVersion': self.ota_version()})))
        elif typ == 6:
            pkg = self.ota_package()
            self.say('rnlink OTA -> package info: %s' % [f['Name'] for f in pkg])
            self.tx(0x09, pb_msg(6, message=json.dumps(pkg)))
        elif typ == 7:
            name, start, size = msg.get('Name'), int(msg.get('Start', 0)), int(msg.get('Size', 0))
            with open(os.path.join(self.ota_dir, os.path.basename(name)), 'rb') as f:
                f.seek(start); data = f.read(size)
            self.ota_sent = getattr(self, 'ota_sent', 0) + len(data)
            self.say('rnlink OTA -> slice %s @%d +%d' % (name, start, len(data)))
            self.tx(0x09, pb_msg(7, message=json.dumps({'Name': name, 'Start': start, 'Size': len(data)}),
                                 data=data), ctrl=self._pctrl())

    def push_todo(self, events=None):
        import json, time as _t
        # TodoLink (business 0x16) is a PbMsg: type 2 = single add/modify (single_upsert), message = JSON
        # {eventList:[...], hasMoreTodo}. TodoProtocol_HandleSingleAddModify parses it.
        if events is None:
            now = int(_t.time() * 1000)
            events = [{'eventID': '1792240000001', 'title': '10:00 产品评审会', 'content': '产品评审会',
                       'startTime': now + 3600000, 'endTime': now + 7200000,
                       'isCompleted': False, 'allDay': False, 'reminder': 0}]
        msg = json.dumps({'eventList': events, 'hasMoreTodo': False})
        self.say('rnlink -> TODO %s' % msg)
        self.tx(0x16, pb_msg(2, message=msg))

    def push_weather(self, temp=23, location='Shanghai', icon=1):
        import json
        # Dashboard command (launcher receiveMessage type 0x12 -> DashboardProtocolController::decode,
        # which cJSON-parses {"cmd","payload":{value,mode,data}}; data is a nested JSON string).
        # applyCurrentWeatherUpdate reads data.icon (number), data.temp (number), data.location
        # (string). cmd current_weather_update; glasses ack payload.value 0 = accepted, 1 = rejected.
        data = json.dumps({'icon': icon, 'temp': temp, 'location': location})
        msg = json.dumps({'cmd': 'current_weather_update', 'payload': {'value': 0, 'mode': 0, 'data': data}})
        self.say('rnlink -> weather %s' % msg)
        self.tx(0x0f, pb_msg(0x12, message=msg))

    def push_general_setting(self, cmd, value=0, mode=0, data=''):
        import json
        # GeneralSetting = LAUNCHER_CMD (0x0f) PbMsg type 5 -> RnLinkMsgProcessor::handleGeneralSettingCommand.
        # JSON {cmd, payload:{value, mode, data}}; data is a nested JSON string. Sub-commands: crown_config,
        # head_gestures, wakeup_config, display_config, auto_lock_time, device_name_change, ...
        if not isinstance(data, str):
            data = json.dumps(data)
        msg = json.dumps({'cmd': cmd, 'payload': {'value': value, 'mode': mode, 'data': data}})
        self.say('rnlink -> GeneralSetting %s' % msg)
        self.tx(0x0f, pb_msg(5, message=msg))

    def set_crown_config(self, double=0, long_press=1, direction=1):
        # crown_config: payload.value=direction, data.double / data.longPress. The double-click action
        # maps via InputEventMonitor::handleQuickLaunch: 0 assistant, 2 focus mode, 3 start recording, ...
        self.push_general_setting('crown_config', value=direction,
                                  data={'double': double, 'longPress': long_press})

    def set_wakeup_config(self, headup=1, headup_degree=20, crown=1):
        # wakeup_config -> SysStateMonitor::setWakeupConfig: headup_switch enables head-up (raise-to-wake)
        # via the IMU; headup_degree is the pitch threshold; crown_switch enables crown wake.
        self.push_general_setting('wakeup_config',
                                  data={'headup_switch': headup, 'headup_degree': headup_degree,
                                        'crown_switch': crown})

    def on_rnlink_cmd(self, cmd, data):
        if cmd == 0x11:                        # glasses dev-info reply
            info = {tag: val for tag, val in tlv_iter(data)}
            self.say('rnlink glasses dev-info %s' % {hex(t): v.hex() for t, v in info.items()})
            if 0x11 in info and len(info[0x11]) == 6:
                self.glasses_dev_addr = info[0x11]
            self.dev_info_done = True
            self.send_auth()
        elif cmd in (0x18, 0x19):              # glasses auth reply (0x19 = wrapped success response)
            if not self.authed:
                self.authed = True
                self.say('rnlink AUTH OK, glasses reply %s' % data.hex())
                self.push_weather()           # proactively fill the home-screen weather
                # Declare the phone app's AI-assistant compatibility version so the glasses treat the
                # voice assistant as available (otherwise it shows "连接手机 App 后重试").
                import json as _j
                self.tx(0x0d, pb_msg(31, message=_j.dumps({'major': 5, 'minor': 0})))
                if os.environ.get('REC_PHONE_START'):     # research probe: phone-initiated recording (fresh uuid)
                    import json as _jp, uuid as _uu, time as _tt
                    _m = {'uuid': _uu.uuid4().hex, 'action': 1, 'mode': 1, 'code': int(os.environ.get('REC_PHONE_CODE', '1')),
                          'sid': str(int(_tt.time())), 'type': 1, 'text': ''}
                    self.tx(0x0e, pb_msg(1, message=_jp.dumps(_m)))
                    self.say('rnlink -> RECORD_CMD phone start %s' % _m)
                if os.environ.get('MIC_PERM'):            # research probe: phone grants the glasses microphone
                    self.push_general_setting('microphone_permission', value=1)
                if os.environ.get('RECO_JSON'):           # research probe: 智能推荐看板 (航班/打车) cards
                    import json as _jr
                    for _k, _d in enumerate(_jr.load(open(os.environ['RECO_JSON']))):
                        _p = _d['__payload'] if '__payload' in _d else {'value': 0, 'mode': 0, 'data': _jr.dumps(_d, ensure_ascii=False)}
                        self.tx(0x0f, pb_msg(int(os.environ.get('RECO_TYPE', '19')), message=_jr.dumps(
                            {'cmd': 'recommend_update', 'payload': _p}, ensure_ascii=False)))
                        self.say('rnlink -> recommend_update %s' % list(_d))
                if os.environ.get('LIFELOG_ON'):          # research probe: phone turns 全天智记 on
                    import json as _jj
                    # LAUNCHER_CMD type 21 carries the lifelog commands both ways (glasses report lifelog_switch on 0x15)
                    self.tx(0x0f, pb_msg(int(os.environ.get('LIFELOG_TYPE', '21')), message=_jj.dumps(
                        {'cmd': 'life_log_switch', 'payload': {'value': 1, 'mode': 0, 'data': ''}})))
                    self.say('rnlink -> life_log_switch on (LAUNCHER_CMD type %s)' % os.environ.get('LIFELOG_TYPE', '21'))
                if getattr(self, 'record_demo', False):
                    # Bind the crown double-click to "start recording" (action 3) so a double-click
                    # starts an on-glasses recording (default double-click is the AI assistant).
                    self.set_crown_config(double=3)
                if getattr(self, 'settings_demo', False):
                    # Settings sync (phone -> glasses): enable head-up (raise-to-wake) via wakeup_config.
                    self.set_wakeup_config(headup=1, headup_degree=20, crown=1)
                if getattr(self, 'todo_demo', False):
                    self.push_todo()
                if getattr(self, 'prompt_demo', False):
                    # Push a teleprompter script and remote-start it (scrolling text on screen).
                    self.push_prompter()
                if getattr(self, 'prompt_probe', False):
                    # Map the prompter (business 0x14) message types: the glasses log each received
                    # type name ("PrompterRnLinkMsgProcessor ... receive rnlink message type: N").
                    import json as _j
                    for t in range(1, 40):
                        self.tx(0x14, pb_msg(t, message=_j.dumps({'probe': t})))
                # SPARE_FILES=name=path,...: push these files over the rnlink file channel after auth, in
                # order (Spare apps runtime install parts spare-app.spi / spare-rt.cfg, docs/PROTOCOL-apps.md).
                # SPARE_FILES_EVERY=<s>: one file every s seconds of emulated time (30 ms per connection event), the
                # way the phone streams SGN1 scenes (spare-nav.sgn), instead of all at once.
                every = float(__import__('os').environ.get('SPARE_FILES_EVERY', '0') or 0)
                self.later_files = getattr(self, 'later_files', [])
                for k, item in enumerate([x for x in __import__('os').environ.get('SPARE_FILES', '').split(',') if x]):
                    name, path = item.split('=', 1)
                    if every > 0:
                        self.later_files.append((self.evt + 1 + int(k * every * 1000 / 30), name, open(path, 'rb').read()))
                    else:
                        self.ft.send_file(0x12, name, open(path, 'rb').read())
                self.bench_load()
                if self.ota_dir:
                    self.start_ota()
                if getattr(self, 'notif_demo', False):
                    # Notification channel = business 0x15; "type" 1 = add/display (2 remove, 3 update).
                    self.push_notification(0x15, 'Alice', 'Hello from the virtual phone!',
                                           app='WhatsApp', appid='com.whatsapp', uid='1', ntype=1)
        else:
            self.say('rnlink cmd 0x%02x data %s (unhandled)' % (cmd, data.hex()))

    def push_notification(self, business, title, content, app='WhatsApp', appid='com.whatsapp',
                          subtitle='', uid='1', category=0, ntype=1, phone_number=''):
        import json, time as _t
        msg = {'notificationUID': uid, 'appId': appid, 'appName': app, 'title': title,
               'subtitle': subtitle, 'content': content, 'category': category, 'type': ntype,
               'timestamp': int(_t.time() * 1000), 'phoneNumber': phone_number}
        self.say('rnlink -> NOTIFICATION business=0x%02x %r / %r' % (business, title, content))
        self.tx(business, pb_msg(2, message=json.dumps(msg)))

    def push_call(self, number='+15550123', name='', uid='call1', ntype=1):
        # Incoming-call notification: ANCS category 1 (IncomingCall) drives the glasses'
        # CallNotification UI (NotificationService::onCallNotificationReceived). type 1 = show,
        # 2 = remove (call ended/answered elsewhere).
        self.push_notification(0x15, name or number, 'Incoming call', app='Phone',
                               appid='com.android.phone', uid=uid, category=1, ntype=ntype,
                               phone_number=number)
