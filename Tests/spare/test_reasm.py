#!/usr/bin/env python3
"""虚拟手机 rnlink 拼帧自测（离线，不起仿真）：python3 Tests/spare/test_reasm.py [带 --raw 分片的 peer.log ...]

1. 构造用例：ctrl 98（385 B = 244 + 141）、ctrl 101（466 B = 244 + 222，内含 SGT1 114 记录）多片帧，与其他业务号
   （RNLINK 0x10、RECORD 0x0e、AI 字幕 0x13、提词器 0x14、VOICE_ASSISTANT 0x0d、0x11 文件）单帧 / 多片帧交错；尾片先于头片、
   中间片先于头片、相邻两片对调、两帧同时在途、单帧夹在大帧分片之间、30 片的大帧。逐帧断言：全部交付、CRC 正确、内容一致、
   零丢帧、零孤儿分片。
2. 随机压力：2000 个帧（1–4 片，业务号随机），各帧分片按到达顺序随机交错，再随机做不相交的相邻对调（仿真台实测的乱序形态）。
3. 给了 peer.log（ble-peer.py --raw 记的原始分片）就回放：报告帧数 / CRC-BAD / 丢弃，并在其中找 ctrl 98 / 101。
"""
import json, os, random, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'scripts'))
import rnlink                      # noqa: E402
import rnlink_reasm                # noqa: E402

CHUNK = 244                        # MTU 247 - 3


def chunks(frame):
    return [frame[i:i + CHUNK] for i in range(0, len(frame), CHUNK)]


def launcher(ctrl, cmd, data_hex, size):
    """LAUNCHER_CMD frame whose JSON is padded so that the whole frame is exactly `size` bytes."""
    def build(pad):
        js = json.dumps({'cmd': cmd, 'payload': {'value': 0, 'mode': 0, 'data': data_hex, 'pad': 'x' * pad}},
                        separators=(',', ':'))
        return rnlink.frame(0x0f, rnlink.pb_msg(6, message=js), ctrl=ctrl)
    pad = 0
    while len(build(pad)) < size:
        pad += 1
    f = build(pad)
    assert len(f) == size, (ctrl, len(f), size)
    return f


def other(ctrl, business, size, rnd=None):
    """A frame of exactly `size` bytes shaped like the real traffic: RNLINK (0x10) a command byte + TLV-ish text,
    the others PbMsg{type, message=JSON-ish text} (never 0xaa 0x55 at a chunk start)."""
    rnd = rnd or random.Random(ctrl)
    text = lambda n: bytes(rnd.randrange(0x20, 0x7f) for _ in range(max(0, n)))
    if business == 0x10:
        return rnlink.frame(business, bytes([0x11]) + text(size - 10), ctrl=ctrl)
    vlen = lambda v: 1 if v < 0x80 else 2 if v < 0x4000 else 3
    n = next((L for L in range(max(0, size - 16), size) if 13 + vlen(L) + L == size), max(0, size - 15))
    body = bytes([0x08, 0x01, 0x10, rnd.randrange(1, 100), 0x1a]) + rnlink._enc_varint(n) + text(n)
    return rnlink.frame(business, body, ctrl=ctrl)      # PbMsg{1: 1, 2: type, 3: text}


class Sink:
    def __init__(self):
        self.frames, self.log = [], []
        self.r = rnlink_reasm.Reassembler(self.frames.append, lambda *a: self.log.append(' '.join(map(str, a))))

    def feed(self, stream):
        for c in stream:
            self.r.on_chunk(c)
        self.r.flush()
        return self


def check(name, sent, stream):
    s = Sink().feed(stream)
    got = {}
    for f in s.frames:
        b, ctrl, fl, p, ok = rnlink.parse(f)
        assert ok, '%s: ctrl %d CRC-BAD' % (name, ctrl)
        got[ctrl] = f
    missing = [rnlink.parse(f)[1] for f in sent if rnlink.parse(f)[1] not in got]
    wrong = [rnlink.parse(f)[1] for f in sent if rnlink.parse(f)[1] in got and got[rnlink.parse(f)[1]] != f]
    st = s.r.stats
    assert not missing and not wrong and len(s.frames) == len(sent) and not s.log, (name, missing, wrong, s.log)
    assert st['dropped_chunks'] == 0 and st['dropped_heads'] == 0 and st['crc_bad'] == 0, (name, st)
    print('PASS %-58s frames %3d/%-3d chunks %4d dropped 0 crc_bad 0' % (name, len(s.frames), len(sent), len(stream)))
    return got


def sgt1(code, step, t, a, b, c):
    return b'SGT1' + bytes([1, code, step, 0]) + struct.pack('<IIII', t, a, b, c)


def fixed_cases():
    # ctrl 98: analytics_log 385 B; ctrl 101: spare_trace_v1 466 B with the 114 notification-card record.
    rec = sgt1(114, 60, 73720, 0x3ae003c, 0x410, 0xa1081e59) + sgt1(50, 10, 73720, 0xbc, 4, 0)
    f98 = launcher(98, 'analytics_log', '', 385)
    f101 = launcher(101, 'spare_trace_v1', (rec * 3).hex(), 466)
    f99, f100 = launcher(99, 'analytics_log', '', 384), launcher(100, 'analytics_log', '', 399)
    f97 = launcher(97, 'screen_status', '', 100)
    r10 = other(10, 0x10, 60)                     # RNLINK
    e11 = other(11, 0x0e, 70)                     # RECORD_CMD
    s12 = other(12, 0x13, 120)                    # AiSubtitle
    p13 = other(13, 0x14, 520)                    # prompter, 3 chunks
    v14 = other(14, 0x0d, 300)                    # VOICE_ASSISTANT, 2 chunks
    x15 = other(15, 0x11, 55)                     # file channel
    a98, b98 = chunks(f98); a101, b101 = chunks(f101)
    a99, b99 = chunks(f99); a100, b100 = chunks(f100)
    p0, p1, p2 = chunks(p13); v0, v1 = chunks(v14)

    check('single frames, several business ids', [f97, r10, e11, s12, x15], [f97, r10, e11, s12, x15])
    check('ctrl 98 / 101 in order', [f98, f101], [a98, b98, a101, b101])
    # the 942-byte notice run (fb130-2, 2.1.76): tail of 98 first, three heads in flight, tail of 101 first
    sent = [f97, f98, f99, f100, f101, r10, e11]
    got = check('ctrl 98 / 101 tails before heads (run 2.1.76)',
                sent, [f97, b98, a98, a99, a100, b99, b100, r10, b101, a101, e11])
    js = json.loads(rnlink.pb_decode(rnlink.parse(got[101])[3])[3])
    raw = bytes.fromhex(js['payload']['data'])
    assert raw[5] == 114 and raw[6] == 60, raw[:8].hex()
    print('     ctrl 101 carries SGT1 code 114 step 60 a=0x%x' % struct.unpack_from('<I', raw, 12))
    check('ctrl 98 / 101 interleaved with other business ids',
          [f98, f101, r10, e11, s12, p13, v14, x15],
          [a98, r10, a101, p0, e11, b101, v1, p1, s12, v0, b98, x15, p2])
    check('3-chunk frame, middles swapped, singles in between', [p13, r10, e11], [p0, r10, p2, p1, e11])
    check('3-chunk frame, middle before head', [p13, f97], [p1, p0, f97, p2])
    check('two 2-chunk frames, tails crossed', [f98, f99], [a98, a99, b99, b98])
    check('two 2-chunk frames, both tails first', [f98, f99], [b99, b98, a98, a99])
    big = other(16, 0x0f, 30 * CHUNK + 100)
    bc = chunks(big)
    check('31-chunk frame, singles between its chunks', [big, r10, e11, f97],
          bc[:5] + [r10] + bc[5:20] + [e11, f97] + bc[20:])
    check('31-chunk frame, head/first middle and last middle/tail swapped', [big, s12],
          [bc[1], bc[0]] + bc[2:-2] + [bc[-1], s12, bc[-2]])


def random_cases(seed, n=2000):
    rnd = random.Random(seed)
    bus = [0x0f, 0x10, 0x0e, 0x13, 0x14, 0x0d, 0x11, 0x17, 0x0c]
    frames, queues = [], []
    for i in range(n):
        size = rnd.choice([rnd.randrange(12, CHUNK), rnd.randrange(CHUNK + 1, 4 * CHUNK)])
        f = other(i, rnd.choice(bus), size, rnd)
        frames.append(f); queues.append(chunks(f))
    # interleave: at most 4 frames in flight, each frame's chunks in order
    stream, active, nxt = [], [], 0
    while nxt < n or active:
        while nxt < n and len(active) < rnd.randint(1, 4):
            active.append(queues[nxt]); nxt += 1
        q = rnd.choice(active)
        stream.append(q.pop(0))
        if not q:
            active.remove(q)
    # disjoint adjacent swaps (the order seen on the emulated link)
    i = 0
    while i < len(stream) - 1:
        if rnd.random() < 0.3:
            stream[i], stream[i + 1] = stream[i + 1], stream[i]; i += 2
        else:
            i += 1
    check('random seed %d: %d frames, interleaved + adjacent swaps' % (seed, n), frames, stream)


def replay(path):
    import re
    s = Sink()
    n = 0
    for line in open(path, errors='replace'):
        m = re.search(r'raw chunk len=\d+ ([0-9a-f]+)', line)
        if m:
            s.r.on_chunk(bytes.fromhex(m.group(1))); n += 1
    s.r.flush()
    ctrls = {rnlink.parse(f)[1]: rnlink.parse(f)[4] for f in s.frames}
    print('REPLAY %s: chunks %d frames %d crc_bad %d dropped_chunks %d dropped_heads %d | ctrl 98 %s, ctrl 101 %s' % (
        path, n, len(s.frames), s.r.stats['crc_bad'], s.r.stats['dropped_chunks'], s.r.stats['dropped_heads'],
        'ok' if ctrls.get(98) else 'MISSING', 'ok' if ctrls.get(101) else 'MISSING'))
    for l in s.log:
        print('   ', l[:120])


if __name__ == '__main__':
    fixed_cases()
    for seed in (1, 2, 3, 4, 5):
        random_cases(seed)
    for p in sys.argv[1:]:
        replay(p)
    print('ALL PASS')
