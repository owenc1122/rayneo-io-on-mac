#!/usr/bin/env python3
"""Stand in for the Mac app's microphone in headless runs: append real-time audio to a growing mic.raw.
    live-mic-feed.py <mic.raw> <boot.log> <trigger-regexp> <delay-s> <utterance.wav> [<duration-s>]
Writes low-level noise at 16 kHz (s16le mono) in 20 ms steps of wall-clock time; once <trigger-regexp>
appears in boot.log, waits <delay-s> wall seconds and inserts the utterance (logging the wall time and
mic.raw offset), then keeps writing noise until <duration-s>. Used with MIC=<mic.raw> MIC_LIVE=1."""
import random, re, struct, sys, time, wave
mic, log, trig, delay, wav = sys.argv[1:6]
duration = float(sys.argv[6]) if len(sys.argv) > 6 else 900
w = wave.open(wav); speech = w.readframes(w.getnframes())
rnd = random.Random(1)
noise = lambda n: struct.pack('<%dh' % n, *[rnd.randint(-60, 60) for _ in range(n)])
start = time.time(); written = 0; fired_at = None; done = False
with open(mic, 'ab') as f:
    while time.time() - start < duration:
        target = int((time.time() - start) * 16000)
        if target > written:
            f.write(noise(target - written)); f.flush(); written = target
        if fired_at is None:
            try:
                if re.search(trig, open(log, errors='replace').read()): fired_at = time.time(); print('trigger seen at %.1f s' % (fired_at - start), flush=True)
            except FileNotFoundError: pass
        elif not done and time.time() - fired_at >= float(delay):
            print('utterance at wall %.1f s, mic.raw offset %d' % (time.time() - start, f.tell()), flush=True)
            f.write(speech); f.flush(); written += len(speech) // 2; done = True
            start -= len(speech) / 32000.0 * 0   # keep wall pacing (speech is "spoken" instantly here)
        time.sleep(0.02)
