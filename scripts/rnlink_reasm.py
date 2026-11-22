"""rnlink frame reassembly for the virtual phone (glasses -> phone GATT notifications).

The glasses send one rnlink frame (aa55 | len | ctrl | flags | business | payload | crc16) as one or more
GATT notifications of at most MTU-3 bytes. Seen on the emulator (2.1.74-2.1.76, peer.log --raw):

  * several frames can be in flight at once: heads of frames N, N+1, N+2 arrive before any of their tails;
  * a frame's tail notification can arrive BEFORE its own head (ctrl 98 / 101 of the 942-byte notice run:
    tail 141 B, then head 244 B of ctrl 98);
  * small complete frames land between the chunks of a big one.

So the order of continuation chunks says little about which frame they belong to. What is reliable:
  * a chunk that starts with aa55 is a head (payloads are protobuf/JSON text, never 0xaa 0x55 at a chunk start);
  * every chunk of a multi-chunk frame except the last is exactly one full notification (the largest chunk
    length seen, MTU-3 = 244 at MTU 247); the last one carries the remainder;
  * the CRC16 over the frame body verifies a candidate assembly.

The old code (Central.on_rnlink_chunk before 2026-11-22) kept continuations only for heads already seen: a tail
that came first found no matching head and was appended to the OLDEST pending head (a long-dead frame), which
produced a CRC-BAD frame from garbage and left the real frame (ctrl 98, ctrl 101) waiting forever.

Here continuations wait in a pool until a head they complete (CRC-checked) shows up, in either order.
Frames that no CRC-valid assembly completes fall back to an arrival-order assembly (logged CRC-BAD by the
caller, as before) or, when a chunk never arrived, are reported with 'rnlink incomplete frame dropped'.
"""
import binascii
import itertools
import struct

import rnlink

MAX_POOL = 1024           # unassigned continuation chunks kept (a 28 KB analytics bulk frame is ~115 chunks)
MAX_HEADS = 64            # incomplete frames kept
FALLBACK_AFTER = 48       # chunks after which an incomplete frame may use arrival-order assembly (CRC-BAD)
FALLBACK_SETTLE = 8       # a chunk this young is never taken by the fallback
FALLBACK_BEFORE = 2       # the fallback may take chunks that came this many chunks before the head
DEAD_AFTER = 256          # chunks past its expected end after which an unfillable frame is dropped
SMALL_K = 3               # frames with up to this many middle chunks: try every pick of NEAR candidates
NEAR = 12                 # full-size chunks nearest the head considered for those picks
ORPHAN_AGE = 2048         # chunks after which an unassigned continuation is dropped


def _strict_pb(buf):
    """True if buf is a sequence of protobuf fields (wire types 0 / 1 / 2 / 5) ending exactly at its end."""
    i, n = 0, len(buf)
    while i < n:
        key = 0; sh = 0
        while True:
            if i >= n or sh > 63:
                return False
            c = buf[i]; i += 1; key |= (c & 0x7f) << sh; sh += 7
            if not c & 0x80:
                break
        wt = key & 7
        if key >> 3 == 0:
            return False
        if wt == 0:
            while True:
                if i >= n:
                    return False
                c = buf[i]; i += 1
                if not c & 0x80:
                    break
        elif wt == 2:
            ln = 0; sh = 0
            while True:
                if i >= n or sh > 63:
                    return False
                c = buf[i]; i += 1; ln |= (c & 0x7f) << sh; sh += 7
                if not c & 0x80:
                    break
            i += ln
        elif wt == 1:
            i += 8
        elif wt == 5:
            i += 4
        else:
            return False
    return i == n


def _total(head):
    return ((head[2] << 8) | head[3]) + 6


class Reassembler:
    def __init__(self, deliver, say=None):
        self.deliver = deliver            # deliver(frame_bytes)
        self.say = say or (lambda *a: None)
        self.heads = []                   # [seq, bytearray head, total]
        self.pool = []                    # [seq, bytes] continuation chunks not yet assigned
        self.seq = 0
        self.full = 0                     # full notification length (largest chunk seen)
        self._final = False
        self._tried = {}                  # head seq -> pool state of the last failed multi-chunk search
        self.stats = {'frames': 0, 'crc_bad': 0, 'dropped_chunks': 0, 'dropped_heads': 0}

    # ---- input ------------------------------------------------------------------------------
    def on_chunk(self, data):
        data = bytes(data)
        self.seq += 1
        self.full = max(self.full, len(data))
        if data[:2] == b'\xaa\x55':
            buf = data
            while len(buf) >= 6 and buf[0] == 0xaa and buf[1] == 0x55:
                total = _total(buf)
                if len(buf) >= total:
                    self._emit(buf[:total]); buf = buf[total:]
                else:
                    self.heads.append([self.seq, bytearray(buf), total])   # start of a multi-chunk frame
                    if len(self.heads) > MAX_HEADS:
                        self._drop_head(0)
                    self._resolve()
                    return
            if not buf:
                return
            data = bytes(buf)             # trailing bytes after complete frames: a continuation
        self.pool.append([self.seq, data])
        if len(self.pool) > MAX_POOL:
            s, d = self.pool.pop(0)
            self.stats['dropped_chunks'] += 1
            self.say('rnlink resync, dropping %s' % d.hex())
        self._resolve()

    def flush(self):
        """End of session: last arrival-order fallback, then report what never completed."""
        self._final = True
        while self.heads and self._fallback():
            pass
        for h in list(self.heads):
            self._drop_head(0)
        for s, d in self.pool:
            self.stats['dropped_chunks'] += 1
            self.say('rnlink resync, dropping %s' % d.hex())
        self.pool = []

    # ---- assembly ---------------------------------------------------------------------------
    def _emit(self, frame):
        self.stats['frames'] += 1
        p = rnlink.parse(frame)
        if p and not p[4]:
            self.stats['crc_bad'] += 1
        self.deliver(frame)

    def _drop_head(self, i):
        s, h, total = self.heads.pop(i)
        self.stats['dropped_heads'] += 1
        ctrl = struct.unpack_from('>H', h, 4)[0] if len(h) >= 6 else -1
        self.say('rnlink incomplete frame dropped ctrl=%d have=%d total=%d' % (ctrl, len(h), total))

    def _resolve(self):
        progress = True
        while progress and self.heads and self.pool:
            progress = False
            for i, (s, h, total) in enumerate(self.heads):
                used = self._complete(h, total, s)
                if used is None:
                    continue
                frame = bytes(h) + b''.join(self.pool[j][1] for j in used)
                for j in sorted(used, reverse=True):
                    del self.pool[j]
                del self.heads[i]
                self._emit(frame)
                progress = True
                break
        self._fallback()

    def _complete(self, h, total, hseq):
        """Indices into self.pool (in frame order) whose chunks complete head h validly, or None.

        Chunk order on the emulated link is only roughly kept: a middle chunk can come just before its own head
        and the tail just before the last middle (adjacent swaps), and the middles of two frames in flight
        interleave. Candidates, nearest the head first: for up to SMALL_K middles every ordered pick of k of the
        NEAR full-size chunks nearest the head (arrival order, then with one adjacent pair swapped); for bigger
        frames contiguous runs of full-size chunks (same swaps). The tail is a chunk of exactly the remaining
        length. _valid() (CRC16 + protobuf shape) decides."""
        need = total - len(h)
        if need <= 0:
            return []
        full = max(self.full, len(h))
        near = lambda j: abs(self.pool[j][0] - hseq)
        if need <= full:                                  # single last chunk
            for j in sorted(range(len(self.pool)), key=near):
                if len(self.pool[j][1]) == need and self._valid(h, [j]):
                    return [j]
            return None
        k, r = divmod(need, full)                         # k full middles + last chunk of r bytes
        if r == 0:
            k, r = k - 1, full
        fulls = [j for j in range(len(self.pool)) if len(self.pool[j][1]) == full]
        lasts = [j for j in range(len(self.pool)) if len(self.pool[j][1]) == r]
        if not lasts or len(fulls) < k + (1 if r == full else 0):
            return None
        key = (len(self.pool), self.pool[-1][0])
        if self._tried.get(hseq) == key:                  # nothing new since the last failed search
            return None
        self._tried[hseq] = key
        tries = 0
        for last in sorted(lasts, key=near):
            mids = [j for j in fulls if j != last]
            if len(mids) < k:
                continue
            if k <= SMALL_K:
                picks = itertools.combinations(sorted(sorted(mids, key=near)[:NEAR]), k)
            else:
                starts = sorted(range(len(mids) - k + 1), key=lambda st: near(mids[st]))[:16]
                picks = (mids[st:st + k] for st in starts)
            for win in picks:
                for sw in range(-1, k - 1):               # -1 = as arrived, else swap win[sw], win[sw + 1]
                    cand = list(win)
                    if sw >= 0:
                        cand[sw], cand[sw + 1] = cand[sw + 1], cand[sw]
                    tries += 1
                    if self._valid(h, cand + [last]):
                        return cand + [last]
                    if tries >= 4096:
                        return None
        return None

    def _valid(self, h, idx):
        frame = bytes(h) + b''.join(self.pool[j][1] for j in idx)
        if len(frame) < 8 or binascii.crc_hqx(frame[4:-2], 0) != struct.unpack_from('>H', frame, len(frame) - 2)[0]:
            return False
        # CRC16 alone lets about 1 in 65536 wrong assemblies through; with many candidates per search that is
        # not negligible. Payloads that start like a protobuf message (field 1 varint, 0x08) must also parse as
        # one to exactly their end, which a wrong assembly practically never does.
        p = rnlink.parse(frame)
        return not (p and p[3][:1] == b'\x08') or _strict_pb(p[3])

    def _fallback(self):
        """Old heads nothing CRC-valid completes: arrival-order assembly (logged CRC-BAD by the caller), or drop.

        Only chunks from FALLBACK_BEFORE before the head on that have themselves waited FALLBACK_SETTLE chunks are
        used (a younger chunk may still be claimed by its own frame's CRC): full-size chunks in arrival order as
        middles, then a chunk of exactly the remaining length as the tail. Big frames (14 KB analytics bulk, life-log
        audio) have many adjacent swaps that CRC16 cannot tell apart, so they come out here, CRC-BAD, as before. A head that cannot be filled even so is dropped once it is
        DEAD_AFTER chunks past the point where it should have completed (a chunk lost upstream); orphan chunks
        older than ORPHAN_AGE are dropped with the old 'resync' line."""
        for i, (s, h, total) in enumerate(self.heads):
            if self.seq - s < FALLBACK_AFTER and not self._final:
                continue
            need, full, got = total - len(h), max(self.full, len(h)), []
            ready = [j for j, (ps, d) in enumerate(self.pool)
                     if ps >= s - FALLBACK_BEFORE and (self.seq - ps >= FALLBACK_SETTLE or self._final)]
            for j in ready:                               # middles: full-size chunks in arrival order
                if need <= full:
                    break
                if len(self.pool[j][1]) == full:
                    got.append(j); need -= full
            if 0 < need <= full:                          # tail: a chunk of exactly the rest, wherever it came
                tail = [j for j in ready if j not in got and len(self.pool[j][1]) == need]
                if tail:
                    got.append(tail[0]); need = 0
            if need == 0 and got:
                frame = bytes(h) + b''.join(self.pool[j][1] for j in got)
                for j in sorted(got, reverse=True):
                    del self.pool[j]
                del self.heads[i]
                self._emit(frame)
                return True
            chunks = -(-(total - len(h)) // full)
            if self.seq - s > 2 * chunks + DEAD_AFTER:
                self._drop_head(i)
                return True
        while self.pool and self.seq - self.pool[0][0] > ORPHAN_AGE:
            s, d = self.pool.pop(0)
            self.stats['dropped_chunks'] += 1
            self.say('rnlink resync, dropping %s' % d.hex())
