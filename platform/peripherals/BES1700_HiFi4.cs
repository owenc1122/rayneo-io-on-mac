// Stand-in for the HiFi4 audio DSP (nuttx_audio.bin). That image is Xtensa HiFi4 code with FLIX
// bundles; Renode's only Xtensa core (sample_controller) cannot decode it, so the DSP is not
// executed. This model plays the DSP's side of the inter-CPU contract instead, as the stock AP
// firmware expects it (all offsets from the AP image, see .local/research/audio/*.md):
//   rmt_ipc  core 2 chan 0: mailbox bits in sys CMU +0x90/+0x94 (BES1700_ClockControl.Dsp*),
//            peer chan table published at 0x20afffa4, AP table read from 0x20afffa0.
//   rptun    "audio" resource table 0x23c00260: the remote fills vring0 (AP RX) and waits for
//            DRIVER_OK; notifies are 0xffffff00|notifyid over rmt_ipc.
//   rpmsg    legacy split virtqueues, NS service at 53; this side owns endpoint 1024
//            "smf_m55c0_hifi4" (the endpoint the stock DSP image announces).
//   smf      ICS block (0x23c1d000) ready bit 4, stream Add/Remove/Set/Get replies, pool alloc
//            (msgid 0x20/0x22) for named shared-memory FIFOs (magic 0x55aa5a5a) that carry the
//            audio frames between the DSP pipelines and the AP's src-shm/sink-shm elements.
// Audio: record streams get PCM from MicFile (raw s16le mono 16 kHz, or a WAV) and are encoded as the
// AP asks (pcm, or Opus through macOS AudioToolbox); played streams are decoded (mp3/aac/opus/pcm,
// AudioToolbox) and appended to SpeakerFile as 48 kHz stereo s16le, the DSP's apserver mix format. The DSP's own algorithms (Elevoc "up"
// NS/beamforming DLL, "wakeup" KWS DLL) are Xtensa code; in their places run a Wiener noise suppressor on the record
// path (BES1700_HiFi4Ns.cs) and a keyword classifier on the wakeup stream (BES1700_HiFi4KwsNet.cs). Bluetooth: SCO
// voice through "scodn"/"scoup" (mSBC/CVSD, BES1700_HiFi4Sco.cs) and A2DP AAC from the AP's kfifo (BES1700_HiFi4A2dp.cs).
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.Miscellaneous;
using Antmicro.Renode.Time;
using Antmicro.Renode.Peripherals.Timers;

namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public sealed class BES1700_HiFi4 : IDoubleWordPeripheral, IKnownSize
    {
        public BES1700_HiFi4(IMachine machine, BES1700_ClockControl mailbox)
        {
            this.machine = machine;
            this.mailbox = mailbox;
            mailbox.DspMailboxWritten += () => doorbell = true;
            timer = new LimitTimer(machine.ClockSource, 1000000, this, "hifi4", 1000, Direction.Descending,
                enabled: true, workMode: WorkMode.Periodic, eventEnabled: true, autoUpdate: true);
            timer.LimitReached += () => machine.ScheduleAction(TimeInterval.Empty, _ => Tick());   // off the clock-source lock
        }

        public long Size => 0x100;
        // +0 state, +4 frames written to the AP, +8 frames read from the AP, +0xc dropped frames.
        public uint ReadDoubleWord(long offset)
        {
            switch(offset) {
                case 0: return (uint)state;
                case 4: return (uint)framesOut;
                case 8: return (uint)framesIn;
                case 0xc: return (uint)framesDropped;
                default: return 0;
            }
        }
        public void WriteDoubleWord(long offset, uint value) { }
        public void Reset()
        {
            lock(sync) {
                state = 0; doorbell = false; ourRd = 0; ourWr = 0; outbox.Clear(); txValues.Clear();
                lastAvail0 = lastAvail1 = 0; smfApAddr = -1; ics = 0; streams.Clear(); blocks.Clear(); heapNext = HeapBase;
            }
        }

        // Host audio endpoints (monitor: hifi4 MicFile "/path/in.wav"; hifi4 SpeakerFile "/path/out.raw").
        public string MicFile { get { return micPath; } set { lock(micLock) { micPath = value; micStream?.Dispose(); micStream = null; } } }
        public bool MicLoop { get; set; } = true;
        // Live input (the Mac app appends the microphone to MicFile): no looping, and every record stream
        // starts at the newest audio instead of what accumulated before it was opened.
        public bool MicLive { get; set; }
        // Optional copy of every frame handed to the AP: <TapDirectory>/<stream>.<codec> (opus: u16 length + packet).
        public string TapDirectory { get; set; }
        public string SpeakerFile { get { return spkPath; } set { lock(sync) { spkPath = value; spkStream?.Dispose(); spkStream = null; } } }
        // Wake word: folder of 16 kHz enrolment WAVs (scripts/make-kws-templates.sh), match threshold.
        // The templates' features are computed here (at script time) rather than on the first use, where the
        // ~0.6 s of host time landed in the middle of the emulated double-click that opens the stream.
        public string KwsTemplates { get { return kwsDir; } set { lock(micLock) { kwsDir = value; spotters = null; LoadSpotters(); } } }
        public double KwsThreshold { get { return kwsThreshold; } set { lock(micLock) { kwsThreshold = value; spotters = null; } } }
        // 「小雷小雷」 classifier (platform/kws/xiaolei.model, scripts/train-kws.py); when set it decides event 4 and
        // the templates are only used for the English wake words.
        public string KwsModel { get { return kwsModel; } set { lock(micLock) { kwsModel = value; keywordNet = string.IsNullOrEmpty(value) ? null : new HiFi4KeywordNet(value); this.Log(LogLevel.Info, "hifi4: keyword classifier {0}", value); } } }
        public string KwsModelScan(string wav) { return keywordNet == null ? "no keyword model" : keywordNet.Scan(wav); }
        private string kwsModel; private HiFi4KeywordNet keywordNet;
        private double kwsThreshold = 16.5;
        // Offline check of the spotter on a WAV: hit times (s) and the best (lowest) score.
        public string KwsScan(string wav)
        {
            var all = LoadSpotters(); if(all.Count == 0) return "no templates in " + kwsDir;
            var x = HiFi4KeywordSpotter.ReadWav16(wav); if(x == null) return "cannot read " + wav;
            var sb = new StringBuilder();
            foreach(var kv in all) {
                var kws = kv.Value; kws.Reset(); var hits = new List<string>(); double best = double.PositiveInfinity;
                var chunk = new short[160];
                for(int i = 0; i + 160 <= x.Length; i += 160) {
                    Array.Copy(x, i, chunk, 0, 160);
                    long h = kws.Push(chunk, 160); best = Math.Min(best, kws.LastBest);
                    if(h >= 0) hits.Add((h / 16000.0).ToString("0.00"));
                }
                kws.Reset();
                sb.AppendFormat("event {0}: templates {1} best {2:0.0} hits [{3}] ", kv.Key, kws.TemplateCount, best, string.Join(",", hits));
            }
            return sb.ToString().TrimEnd();
        }
        // One spotter per sub-folder named after the hifi event it reports (4 小雷小雷, 2 ok rayneo, 3 hey rayneo);
        // WAVs in any other folder count as event 4.
        private SortedDictionary<uint, HiFi4KeywordSpotter> LoadSpotters()
        {
            if(spotters != null || string.IsNullOrEmpty(kwsDir) || !Directory.Exists(kwsDir)) return spotters ?? empty;
            spotters = new SortedDictionary<uint, HiFi4KeywordSpotter>();
            var groups = new Dictionary<uint, List<string>>();
            foreach(var f in Directory.GetFiles(kwsDir, "*.wav", SearchOption.AllDirectories)) {
                var dir = Path.GetFileName(Path.GetDirectoryName(f));
                uint ev = uint.TryParse(dir, out var e) && (e == 2 || e == 3 || e == 4) ? e : 4;
                if(!groups.TryGetValue(ev, out var l)) groups[ev] = l = new List<string>();
                l.Add(f);
            }
            foreach(var g in groups) {
                g.Value.Sort();
                var sp = new HiFi4KeywordSpotter(g.Value, KwsThreshold);
                if(sp.TemplateCount > 0) spotters[g.Key] = sp;
                this.Log(LogLevel.Info, "hifi4: keyword spotter for hifi event {0}: {1} templates", g.Key, sp.TemplateCount);
            }
            return spotters;
        }

        // ---- second-stage wake word (what the DSP "wakeup" library decides on stream 0x1b).
        // The AP opens 0x1b after the BTH first stage fired; the DSP then reports one hifi event via a
        // Notify: 4 = 小雷小雷 confirmed, 2/3 = ok/hey rayneo, 6 = rejected, 0 = history ("predata") pushed.
        // The decision is made on the stream's own audio, as the DSP library does: the spotter starts fresh,
        // scores the VAD history the stream opens with (the BTH keeps the last seconds before "vad ready";
        // 3 s here), then the live audio until it confirms or the window ends. A wake word recognised by
        // the Mac (KeywordAt) in that window counts as well.
        private void StartWakeDecision(Pipe s)
        {
            wakeStream = s.Index; wakeDeadline = MicNow() + 2 * MicRate;
            SendNotify(s.Index, 0x11, 0);   // the vad history was replayed into the stream
            this.Log(LogLevel.Info, "hifi4: t={0:0.000}s wakeup stream open, scoring {1:0.0} s of VAD history", MicNow() / (double)MicRate, WakeHistory / (double)MicRate);
            lock(micLock) {
                long now = MicNow();
                foreach(var sp in LoadSpotters().Values) sp.Reset();
                keywordNet?.Reset();
                var history = MicSamples(now - WakeHistory, WakeHistory);
                spotBase = now - WakeHistory;
                for(int at = 0; at < history.Length && wakeStream >= 0; at += 160) {
                    var block = new short[160]; Array.Copy(history, at, block, 0, Math.Min(160, history.Length - at));
                    Spot(block, block.Length, spotBase + at + 160);
                }
            }
            if(wakeStream >= 0 && lastKeyword > MicNow() - 3 * MicRate) {
                this.Log(LogLevel.Info, "hifi4: wake word (event {0}) recognised by the Mac in the history", lastKeywordEvent);
                DecideWake(lastKeywordEvent);
            }
        }

        private void OnKeyword() { if(wakeStream >= 0) DecideWake(lastKeywordEvent); }

        private void CheckWakeTimeout() { if(wakeStream >= 0 && MicNow() > wakeDeadline) DecideWake(6); }

        private void DecideWake(uint ev)
        {
            byte stream = (byte)wakeStream; wakeStream = -1;
            SendNotify(stream, 0x11, ev);
            this.Log(LogLevel.Info, "hifi4: t={0:0.000}s wake word {1} -> hifi event {2}", MicNow() / (double)MicRate, ev == 6 ? "not confirmed" : "confirmed", ev);
        }

        // ---- BTH life-log VAD (全天智记). The BTH's lifelog pipeline (smf 0x62: codec2 3 ch -> pil_algo_vad_demo
        // "vad" -> sink-shm sidx=1) runs the Elevoc VAD, which reports speech through a BTH event Notify on stream
        // 0x62: aux1 0x10, u32 0xb = "vad detected open", 0xc = "close" (AP: smf_message_callback ->
        // venus_map_bth_media_event +8 -> vad_event_callback 0x13/0x14 -> result 16/17 ->
        // AlwaysOnAudioAdapter::handleWakeupResult -> AlwaysOn VadStart/VadEnd). The emulated BTH runs that DLL,
        // but the Elevoc licence check fails without the device's factory licence, so it never reports speech.
        // In its place: an energy VAD on the microphone timeline while ADC2 runs with the lifelog's 3 channels
        // (the codec model sets BthVadChannels), its events sent as that Notify. The life-log audio itself is
        // the DSP stream 0x61 "vadrec" ([4,1], opened by the AP after VadStart), served by StreamAdd like any
        // other DSP->AP record stream.
        public int BthVadChannels { get { return bthVadChannels; } set { bthVadChannels = value; } }
        public bool BthVad { get; set; } = true;
        public int BthVadReleaseMs { get; set; } = 1500;
        public double BthVadMinDb { get; set; } = -50;
        private volatile int bthVadChannels;
        private bool vadSpeech, vadActive; private long vadNext; private int vadAbove, vadBelow; private double vadFloor = -70;
        private const int VadFrame = MicRate / 50, LifelogStream = 0x62;

        private void StepBthVad()
        {
            bool on = BthVad && bthVadChannels == 3 && !string.IsNullOrEmpty(micPath);
            if(!on) { if(vadActive) { vadActive = false; vadSpeech = false; } return; }
            long now = MicNow();
            if(!vadActive) { vadActive = true; vadSpeech = false; vadAbove = vadBelow = 0; vadFloor = -70; vadNext = now; }
            while(vadNext + VadFrame <= now) {
                var f = MicSamples(vadNext, VadFrame);
                vadNext += VadFrame;
                double e = 0; foreach(var x in f) e += (double)x * x;
                double db = 10 * Math.Log10(e / VadFrame / (32768.0 * 32768.0) + 1e-12);
                if(db < vadFloor) vadFloor = db; else vadFloor = Math.Min(db, vadFloor + 0.05);
                bool loud = db > Math.Max(BthVadMinDb, vadFloor + 12);
                if(loud) { vadAbove++; vadBelow = 0; } else { vadBelow++; vadAbove = 0; }
                if(!vadSpeech && vadAbove >= 3) {
                    vadSpeech = true;
                    SendNotify(LifelogStream, 0x10, 0xb);
                    this.Log(LogLevel.Info, "hifi4: t={0:0.000}s lifelog VAD speech start ({1:0.0} dBFS) -> bth event 0xb", vadNext / (double)MicRate, db);
                } else if(vadSpeech && vadBelow * 20 >= BthVadReleaseMs) {
                    vadSpeech = false;
                    SendNotify(LifelogStream, 0x10, 0xc);
                    this.Log(LogLevel.Info, "hifi4: t={0:0.000}s lifelog VAD speech end -> bth event 0xc", vadNext / (double)MicRate);
                }
            }
        }

        // StreamServer::Notify layout: msgid 0xff, size 0x88, aux0 stream, aux1 event, u16 datalen @0xa, data @0xc.
        private void SendNotify(byte stream, byte ev, uint value)
        {
            var n = new byte[0x88];
            BitConverter.GetBytes(0xffu | (4u << 12) | (0x88u << 16) | (1u << 28)).CopyTo(n, 0);
            n[4] = ++notifySeq == 0 ? (byte)1 : notifySeq; n[5] = stream; n[6] = ev;
            BitConverter.GetBytes((ushort)4).CopyTo(n, 0xa); BitConverter.GetBytes(value).CopyTo(n, 0xc);
            if(smfApAddr >= 0) SendRpmsg(SmfEpt, (uint)smfApAddr, n);
        }

        public string Status()
        {
            lock(sync) {
                var sb = new StringBuilder();
                sb.AppendFormat("state={0} smfAp={1} ics=0x{2:X} out={3} in={4} dropped={5}\n", state, smfApAddr, ics, framesOut, framesIn, framesDropped);
                foreach(var s in streams.Values) sb.AppendFormat("stream 0x{0:X2} {1} {2} frames={3}\n", s.Index, s.Name, s.Writer ? "dsp->ap" : "ap->dsp", s.Frames);
                foreach(var b in blocks) sb.AppendFormat("shm {0} @0x{1:X} size 0x{2:X}\n", b.Key, b.Value.Address, b.Value.Size);
                return sb.ToString();
            }
        }

        // ---------------------------------------------------------------- scheduling
        private void Tick()
        {
            lock(sync) {
                try {
                    Step();
                } catch(Exception e) {
                    if(errorBudget-- > 0) this.Log(LogLevel.Error, "hifi4: {0}", e);
                }
            }
        }

        private void Step()
        {
            now++;
            if(state == 0) {
                // AP has opened rmt_ipc (dsp_hifi4_ipc_open writes its table pointer) => the DSP was
                // released by dsp_open; do what the DSP's rptun/rmt_ipc init does.
                if(Rd32(ApLocalWord) == 0) return;
                InitRemote();
                state = 1;
            }
            ServiceRmtIpc();
            WatchIcs();
            if(state == 1) {
                if((Rd8(Rsc + 0x60) & 4) == 0) return;   // DRIVER_OK from the AP (rpmsg host)
                StartVirtio();
                state = 2;
            }
            if(!string.IsNullOrEmpty(micPath)) lock(micLock) Fill(MicNow());
            CheckWakeTimeout();
            if(state >= 2) StepBthVad();
            if(state >= 2) {
                ServiceVring1();
                foreach(var s in streams.Values) PumpStream(s);
                FlushOutbox();
            }
            FlushRmtTx();
        }

        // Logs the smf ICS power/ready bitmaps (cpu bits: 1 AP, 2 M55C1, 4 HiFi4, 6 BTH) with virtual time.
        private void WatchIcs()
        {
            if(Rd32(IcsBlock) != 0xbe5be5be) return;
            uint bits = Rd16(IcsBlock + 0x0e);
            if(bits == icsSeen) return;
            icsSeen = bits;
            this.Log(LogLevel.Info, "hifi4: t={0:0.000}s ICS power 0x{1:X2} ready 0x{2:X2}", machine.ElapsedVirtualTime.TimeElapsed.TotalSeconds, bits & 0xff, bits >> 8);
        }

        // ---------------------------------------------------------------- rmt_ipc (core 2, chan 0)
        private void InitRemote()
        {
            // Our tx chan table (0x18 per chan) and message lists live in the DSP DTCM window.
            for(uint i = 0; i < 0x30; i += 4) Wr32(ChanTable + i, 0);
            Wr16(ChanTable + 6, MsgCount); Wr32(ChanTable + 8, MsgList0);
            Wr16(ChanTable + 0x18 + 6, MsgCount); Wr32(ChanTable + 0x18 + 8, MsgList1);
            Wr32(ChanTable + 0x10, Rsc & ~0xfffu); Wr32(ChanTable + 0x14, Rsc + 0xd0);
            for(uint i = 0; i < MsgCount * 12; i += 4) { Wr32(MsgList0 + i, 0); Wr32(MsgList1 + i, 0); }
            Wr32(ApPeerWord, ChanTable);
            // rptun remote half of the resource table (BTH/remote branch of bes_rptun_setup_rsc_table):
            // vring0 = AP RX ring + RX buffer pool, provided by the remote; da written last.
            for(uint i = 0; i < VringBytes + Vring0Num * BufSize; i += 4) Wr32(Vring0 + i, 0);
            Wr32(Rsc + 0x68, VringAlign); Wr32(Rsc + 0x6c, Vring0Num); Wr32(Rsc + 0x70, 0xffffffff);
            Wr32(Rsc + 0x90, BufSize);
            Wr32(Rsc + 0x64, Vring0);
            this.Log(LogLevel.Info, "hifi4: rmt_ipc peer table 0x{0:X}, vring0 0x{1:X} published (AP table 0x{2:X})", ChanTable, Vring0, Rd32(ApLocalWord));
        }

        private void ServiceRmtIpc()
        {
            uint bits = mailbox.DspMailbox;
            if((bits & 0x01) != 0) mailbox.DspClear(0x01);          // AP consumed our messages
            if(!doorbell && (bits & 0x08) == 0) return;
            doorbell = false;
            uint apTab = Rd32(ApLocalWord); if(apTab == 0) return;
            uint rd = Rd16(apTab), wr = Rd16(apTab + 2), count = Rd16(apTab + 6), list = Rd32(apTab + 8);
            if(count == 0) return;
            bool any = false;
            while(rd != wr) {
                uint value = Rd32(list + rd * 12 + 8);
                if(rmtLogBudget-- > 0) this.Log(LogLevel.Info, "hifi4: rmt_ipc rx 0x{0:X8}", value);
                rd = (rd + 1) % count; any = true;
            }
            Wr16(apTab, rd);
            mailbox.DspClear(0x08);
            if(any) mailbox.DspSet(0x40);                           // tx-done for the AP (NVIC 79)
        }

        private void QueueNotify(uint value) { if(!txValues.Contains(value)) txValues.Enqueue(value); }

        private void FlushRmtTx()
        {
            if(txValues.Count == 0) return;
            ourRd = Rd16(ChanTable);
            bool sent = false;
            while(txValues.Count > 0 && (ourWr + 1) % MsgCount != ourRd) {
                uint slot = MsgList0 + ourWr * 12;
                Wr32(slot, 0); Wr32(slot + 4, 0); Wr32(slot + 8, txValues.Dequeue());
                ourWr = (ourWr + 1) % MsgCount; sent = true;
            }
            if(sent) { Wr16(ChanTable + 2, ourWr); mailbox.DspSet(0x200); }   // AP rx doorbell (NVIC 76)
        }

        // ---------------------------------------------------------------- virtio / rpmsg
        private void StartVirtio()
        {
            notify0 = Rd32(Rsc + 0x70) & 0xff; notify1 = Rd32(Rsc + 0x84) & 0xff;
            vring1 = Rd32(Rsc + 0x78); vring1Num = Rd32(Rsc + 0x80); vring1Align = Rd32(Rsc + 0x7c);
            lastAvail0 = 0; lastAvail1 = 0;
            this.Log(LogLevel.Info, "hifi4: DRIVER_OK, notify ids {0}/{1}, AP tx vring 0x{2:X} num {3}", notify0, notify1, vring1, vring1Num);
            SendNs(SmfEptName, SmfEpt, 0);
        }

        private static uint Align(uint v, uint a) { return (v + a - 1) & ~(a - 1); }
        private static uint AvailOff(uint num) { return 16 * num; }
        private static uint UsedOff(uint num, uint align) { return Align(16 * num + 2 * (num + 3), align); }

        private void ServiceVring1()
        {
            if(vring1 == 0 || vring1Num == 0) return;
            uint avail = vring1 + AvailOff(vring1Num), used = vring1 + UsedOff(vring1Num, vring1Align);
            ushort availIdx = (ushort)Rd16(avail + 2);
            bool any = false;
            while(lastAvail1 != availIdx) {
                uint head = Rd16(avail + 4 + 2 * (uint)(lastAvail1 % vring1Num));
                uint desc = vring1 + 16 * head;
                uint addr = Rd32(desc), len = Rd32(desc + 8);
                var frame = Rd(addr, (int)Math.Min(len, 0x1000));
                ushort usedIdx = (ushort)Rd16(used + 2);
                uint ue = used + 4 + 8 * (uint)(usedIdx % vring1Num);
                Wr32(ue, head); Wr32(ue + 4, len);
                Wr16(used + 2, (ushort)(usedIdx + 1));
                lastAvail1++; any = true;
                if(frame.Length >= 16) HandleRpmsg(frame);
            }
            if(any) QueueNotify(0xffffff00 | notify1);
        }

        private void HandleRpmsg(byte[] f)
        {
            uint src = BitConverter.ToUInt32(f, 0), dst = BitConverter.ToUInt32(f, 4);
            int len = Math.Min(BitConverter.ToUInt16(f, 12), f.Length - 16);
            var payload = new byte[len]; Array.Copy(f, 16, payload, 0, len);
            if(dst == NsAddr) {
                if(len < 40) return;
                string name = Encoding.ASCII.GetString(payload, 0, 32).TrimEnd('\0');
                uint addr = BitConverter.ToUInt32(payload, 32), flags = BitConverter.ToUInt32(payload, 36);
                if(nsLogBudget-- > 0) this.Log(LogLevel.Info, "hifi4: NS from AP {0} addr {1} flags {2}", name, addr, flags);
                if(name == SmfEptName && flags == 2) smfApAddr = (int)addr;
                return;
            }
            if(dst != SmfEpt) { if(nsLogBudget-- > 0) this.Log(LogLevel.Info, "hifi4: rpmsg to unknown ept {0} from {1} len {2}", dst, src, len); return; }
            if(smfApAddr < 0) smfApAddr = (int)src;
            if(len <= 7) { HandleSmfControl(payload); return; }
            int off = 0;
            while(off + 8 <= len) {
                int size = (int)((BitConverter.ToUInt32(payload, off) >> 16) & 0xfff);
                if(size < 8 || off + size > len) size = len - off;
                var msg = new byte[size]; Array.Copy(payload, off, msg, 0, size);
                HandleSmf(msg);
                off += size;
            }
        }

        private void SendRpmsg(uint src, uint dst, byte[] payload)
        {
            var f = new byte[16 + payload.Length];
            BitConverter.GetBytes(src).CopyTo(f, 0); BitConverter.GetBytes(dst).CopyTo(f, 4);
            BitConverter.GetBytes((ushort)payload.Length).CopyTo(f, 12);
            payload.CopyTo(f, 16);
            outbox.Enqueue(f);
        }

        private void SendNs(string name, uint addr, uint flags)
        {
            var p = new byte[40];
            Encoding.ASCII.GetBytes(name).CopyTo(p, 0);
            BitConverter.GetBytes(addr).CopyTo(p, 32); BitConverter.GetBytes(flags).CopyTo(p, 36);
            SendRpmsg(addr, NsAddr, p);
        }

        private void FlushOutbox()
        {
            if(outbox.Count == 0) return;
            uint avail = Vring0 + AvailOff(Vring0Num), used = Vring0 + UsedOff(Vring0Num, VringAlign);
            bool any = false;
            while(outbox.Count > 0) {
                ushort availIdx = (ushort)Rd16(avail + 2);
                if(lastAvail0 == availIdx) break;                    // AP has no free RX buffer
                uint head = Rd16(avail + 4 + 2 * (uint)(lastAvail0 % Vring0Num));
                uint desc = Vring0 + 16 * head;
                uint addr = Rd32(desc), cap = Rd32(desc + 8);
                var f = outbox.Peek();
                if(f.Length > cap) { this.Log(LogLevel.Warning, "hifi4: rpmsg frame {0} > buffer {1}, dropped", f.Length, cap); outbox.Dequeue(); continue; }
                outbox.Dequeue();
                Wr(addr, f);
                ushort usedIdx = (ushort)Rd16(used + 2);
                uint ue = used + 4 + 8 * (uint)(usedIdx % Vring0Num);
                Wr32(ue, head); Wr32(ue + 4, (uint)f.Length);
                Wr16(used + 2, (ushort)(usedIdx + 1));
                lastAvail0++; any = true;
            }
            if(any) QueueNotify(0xffffff00 | notify0);
        }

        // ---------------------------------------------------------------- smf
        private void HandleSmfControl(byte[] p)
        {
            if(p.Length < 5) return;
            uint arg = BitConverter.ToUInt32(p, 1);
            this.Log(LogLevel.Info, "hifi4: smf control cmd {0} arg 0x{1:X}", p[0], arg);
            if(p[0] != 0) return;
            // Non-master ics::Register: check magic, add our name and power/ready bits (cpu idx 4).
            if(Rd32(arg) != 0xbe5be5be) { this.Log(LogLevel.Warning, "hifi4: ICS 0x{0:X} has no magic", arg); return; }
            ics = arg;
            Wr(ics + 0x10 + 4 * 8, new byte[] { (byte)'h', (byte)'i', (byte)'f', (byte)'i', (byte)'4', 0, 0, 0 });
            Wr8(ics + 0x0e, (byte)(Rd8(ics + 0x0e) | 0x10));
            Wr8(ics + 0x0f, (byte)(Rd8(ics + 0x0f) | 0x10));
        }

        private void HandleSmf(byte[] m)
        {
            uint dw0 = BitConverter.ToUInt32(m, 0);
            uint msgid = dw0 & 0xfff;
            byte stream = m[5];
            if(smfLogBudget-- > 0) this.Log(LogLevel.Info, "hifi4: smf msg 0x{0:X3} size {1} stream 0x{2:X2} aux1 {3} flags 0x{4:X2}{5}", msgid, m.Length, stream, m[6], m[7], (m[7] & 0x40) != 0 && m.Length > 0x20 ? " \"" + CString(m, 0x20) + "\"" : "");
            if((msgid & 1) != 0) return;                             // a response; nothing waits here
            bool ok = true; bool reply = true;
            if(msgid == 0x20) ok = PoolAlloc(m);
            else if(msgid == 0x22) { PoolFree(m); reply = false; }
            else if((msgid & 0xf80) == 0x80) {
                uint op = msgid & 0xf;
                if(op == 0) ok = StreamAdd(m);
                else if(op == 2) StreamRemove(m);
                else if(op == 6 && m.Length >= 0x30) {
                    // Get (e.g. the elevoc licence exchange on setid 1 "algo/params"): a 0x40-byte all-zero
                    // block, which the AP accepts; the licence itself is not checked here.
                    var r = new byte[0x30 + 0x40]; Array.Copy(m, r, 0x30);
                    uint dw = BitConverter.ToUInt32(r, 0); dw = (dw & ~0x0fff0000u) | ((uint)r.Length << 16);
                    BitConverter.GetBytes(dw).CopyTo(r, 0); Wr32Array(r, 0x2c, 0x40);
                    m = r;
                }
            }
            if(reply) Reply(m, ok);
        }

        private void Reply(byte[] req, bool ok)
        {
            var r = (byte[])req.Clone();
            uint dw0 = BitConverter.ToUInt32(r, 0);
            uint src = (dw0 >> 12) & 0xf, dst = (dw0 >> 28) & 0xf;
            dw0 = (dw0 & ~0xf000f000u) | 1 | (dst << 12) | (src << 28);
            BitConverter.GetBytes(dw0).CopyTo(r, 0);
            r[7] = (byte)(ok ? (r[7] | 0x20) : (r[7] & ~0x20));
            if(smfApAddr >= 0) SendRpmsg(SmfEpt, (uint)smfApAddr, r);
        }

        private static void Wr32Array(byte[] a, int off, uint v) { BitConverter.GetBytes(v).CopyTo(a, off); }
        private static string CString(byte[] a, int off)
        {
            int e = off; while(e < a.Length && a[e] != 0) e++;
            return Encoding.ASCII.GetString(a, off, e - off);
        }
        private static string KeyName(ulong key)
        {
            var b = BitConverter.GetBytes(key); int n = 0; while(n < 8 && b[n] != 0) n++;
            return Encoding.ASCII.GetString(b, 0, n).ToLowerInvariant();
        }

        private bool PoolAlloc(byte[] m)
        {
            if(m.Length < 0x30) return false;
            string key = KeyName(BitConverter.ToUInt64(m, 0x18));
            uint size = BitConverter.ToUInt32(m, 0x20);
            if(!blocks.TryGetValue(key, out var blk)) {
                if(size == 0) { this.Log(LogLevel.Info, "hifi4: pool lookup {0}: not found", key); return false; }
                blk = Allocate(key, size);
                if(blk == null) return false;
            }
            Wr32Array(m, 0x20, blk.Size);
            BitConverter.GetBytes((ulong)blk.Address).CopyTo(m, 0x28);
            this.Log(LogLevel.Info, "hifi4: pool alloc {0} size 0x{1:X} -> 0x{2:X}", key, size, blk.Address);
            return true;
        }

        private void PoolFree(byte[] m)
        {
            if(m.Length < 0x18) return;
            uint addr = (uint)BitConverter.ToUInt64(m, 0x10);
            string found = null;
            foreach(var b in blocks) if(b.Value.Address == addr || b.Value.Address == (addr & ~0x04000000u)) found = b.Key;
            if(found == null) return;
            foreach(var s in streams.Values) if(s.Name == found) return;   // still used by a running DSP pipeline
            Release(found);
        }

        private Block Allocate(string key, uint size)
        {
            size = Align(Math.Max(size, 0x40), 0x40);
            uint addr = 0;
            foreach(var f in freeList) if(f.Size >= size) { addr = f.Address; freeList.Remove(f); break; }
            if(addr == 0) {
                if(heapNext + size > HeapEnd) { this.Log(LogLevel.Error, "hifi4: shm heap exhausted ({0})", key); return null; }
                addr = heapNext; heapNext += size;
            }
            for(uint i = 0; i < size; i += 4) Wr32(addr + i, 0);
            var blk = new Block { Address = addr, Size = size };
            blocks[key] = blk;
            return blk;
        }

        private void Release(string key)
        {
            var b = blocks[key]; blocks.Remove(key);
            Wr32(b.Address, 0);
            freeList.Add(b);
            this.Log(LogLevel.Info, "hifi4: pool free {0}", key);
        }

        // Pipe table in the ICS block (StreamConfig): cfg bytes at base+0x400+2*i, cpu0 bits 0-2, cpu1 bits 4-6.
        private bool StreamAdd(byte[] m)
        {
            byte index = m[5];
            string name = m.Length >= 0x20 ? KeyName(BitConverter.ToUInt64(m, 0x18)) : "";
            string param = (m[7] & 0x40) != 0 && m.Length > 0x20 ? CString(m, 0x20) : "";
            uint cpu0 = 0, cpu1 = 0;
            if(ics != 0) { byte cfg = Rd8(ics + 0x2a0 + 0x400 + 2 * (uint)index); cpu0 = (uint)(cfg & 7); cpu1 = (uint)((cfg >> 4) & 7); }
            if(streams.TryGetValue(index, out var running)) { running.Refs++; return true; }
            var s = new Pipe { Index = index, Name = name, Param = param, Refs = 1 };
            // DSP produces for the AP (arec*, wakeup, ...): [4,1]. AP produces for the DSP (aplay*): [1,4].
            if(cpu0 == 4 && cpu1 == 1) s.Writer = true;
            else if(cpu0 == 1 && cpu1 == 4) s.Reader = true;
            // Bluetooth voice (smf 0x28/0x29, cpus [4,0]): the AP's ScoService writes the controller's frames into
            // "scodn" and sends what the DSP writes to "scoup"; the AP allocates both FIFOs (possibly after the Add).
            if(name == "scodn") s.Reader = true;
            if(name == "scoup") s.Writer = true;
            // A2DP sink (smf 0x24, cpus [4,0]): "a2dp=[omediaScript=[codec=aac,pkg=#6],kfifo=#<AP address>,vol=#..]".
            if(param.Contains("kfifo=#") && param.Contains("omediaScript")) {
                s.Reader = true; s.Kfifo = ParamNumber(param, "kfifo", 0); s.Codec = ParamWord(param, "codec", "aac"); s.Latm = new LatmDemuxer();
            }
            if(s.Writer) {
                ParseFormat(s);
                if(s.FrameUs == 0) s.FrameUs = s.FrameMs * 1000;
                if(s.Sco == null) {
                    var blk = blocks.TryGetValue(name, out var b) ? b : Allocate(name, FifoSize(8192, 16));
                    if(blk == null) return false;
                    s.Fifo = blk.Address;
                    FifoInitialize(s.Fifo, 8192, 16);
                    FifoInitWrite(s.Fifo);
                    FifoWriteMedia(s);
                }
                s.NextTickUs = now * 1000;
                s.NextSample = MicNow();
                if(name == "wakeup") s.NextSample -= MicRate / 5;   // pcm-preset htime=200: replay the last 200 ms
            }
            streams[index] = s;
            if(name == "wakeup") StartWakeDecision(s);
            this.Log(LogLevel.Info, "hifi4: stream add 0x{0:X2} {1} cpus [{2},{3}] {4} {5}", index, name, cpu0, cpu1, s.Writer ? "dsp->ap" : s.Reader ? "ap->dsp" : "dsp-local", param);
            return true;
        }

        private void StreamRemove(byte[] m)
        {
            byte index = m[5];
            if(!streams.TryGetValue(index, out var s)) return;
            if(--s.Refs > 0) return;
            streams.Remove(index);
            if(wakeStream == index) wakeStream = -1;
            s.Encoder?.Dispose(); s.Decoder?.Dispose();
            if(s.Reader && s.PlayStart >= 0 && s.SpeakerBytes > s.SegmentStart) SpeakerEvent("end " + s.Name);
            this.Log(LogLevel.Info, "hifi4: stream remove 0x{0:X2} {1} after {2} frames", index, s.Name, s.Frames);
        }

        private static uint ParamNumber(string p, string key, uint dflt)
        {
            int i = p.IndexOf(key + "=#", StringComparison.Ordinal);
            if(i < 0) return dflt;
            i += key.Length + 2; int e = i; while(e < p.Length && char.IsDigit(p[e])) e++;
            return uint.TryParse(p.Substring(i, e - i), out var v) ? v : dflt;
        }
        private static string ParamWord(string p, string key, string dflt)
        {
            int i = p.IndexOf(key + "=", StringComparison.Ordinal);
            if(i < 0) return dflt;
            i += key.Length + 1; int e = i; while(e < p.Length && (char.IsLetterOrDigit(p[e]) || p[e] == '_')) e++;
            return p.Substring(i, e - i);
        }

        private void ParseFormat(Pipe s)
        {
            string p = s.Param;
            int fmt = p.IndexOf("fmt=[", StringComparison.Ordinal), enc = p.IndexOf("enc=[", StringComparison.Ordinal);
            string f = fmt >= 0 ? p.Substring(fmt) : "", e = enc >= 0 ? p.Substring(enc) : "";
            s.Rate = ParamNumber(f, "rate", 16000); s.Channels = ParamNumber(f, "ch", 1); s.Bits = ParamNumber(f, "bits", 16);
            s.Codec = ParamWord(e, "keys", "pcm");
            uint bytesPerMs = s.Rate * s.Channels * (s.Bits / 8) / 1000;
            if(s.Codec == "msbc" || s.Codec == "cvsd") {
                // one encoded frame per 7.5 ms (mSBC 57 bytes from 120 samples at 16 kHz, CVSD 60 bytes at 8 kHz)
                s.Sco = s.Codec == "msbc" ? (object)new MsbcCodec() : new CvsdCodec();
                s.FrameUs = 7500; s.FrameMs = 7;
                return;
            }
            if(s.Codec == "pcm") {
                s.FrameBytes = ParamNumber(e, "imin", s.Name == "wakeup" ? 640u : 1920u);
                s.FrameMs = Math.Max(1, s.FrameBytes / Math.Max(1, bytesPerMs));
            } else {
                // dms = frame duration in 0.1 ms (600 = 60 ms). Encoded by the host's AudioToolbox.
                s.FrameMs = ParamNumber(e, "dms", 200) / 10; if(s.FrameMs == 0) s.FrameMs = 20;
                s.FrameBytes = s.FrameMs * bytesPerMs;
                s.Bitrate = ParamNumber(e, "br", 32000);
                s.Application = ParamNumber(e, "application", 2048);
                // haveHead=1: each FIFO frame is an 8-byte head + one constant-size packet (the AP's KWS reader
                // skips 8 bytes and only accepts 0xf0-byte packets).
                s.Head = ParamNumber(e, "haveHead", 0) != 0 ? 8u : 0u;
                if(s.Codec == "opus") {
                    try { s.Encoder = new HostOpusEncoder(s.Rate, s.Channels, s.Rate * s.FrameMs / 1000, s.Bitrate, s.Head != 0); }
                    catch(Exception x) { this.Log(LogLevel.Warning, "hifi4: no host Opus encoder ({0}); delivering PCM", x.Message); }
                }
                if(s.Encoder == null) {
                    this.Log(LogLevel.Warning, "hifi4: stream {0} asks for {1}; delivering PCM frames ({2} ms)", s.Name, s.Codec, s.FrameMs);
                    s.Codec = "pcm";
                }
            }
        }

        // ---------------------------------------------------------------- shared-memory FIFO
        private static uint FifoSize(uint bmax, uint fmax) { return Align(bmax, 64) + Align(0x28 * fmax, 64) + 0x180; }

        private void FifoInitialize(uint b, uint bmax, uint fmax)
        {
            if(Rd32(b) == FifoMagic) return;
            for(uint i = 0; i < 0x40; i += 4) Wr32(b + i, 0);
            uint size = FifoSize(bmax, fmax), desc = Align(0x28 * fmax, 64);
            Wr32(b + 4, size); Wr32(b + 8, fmax); Wr32(b + 0xc, size - 0x80); Wr32(b + 0x10, bmax);
            Wr32(b + 0x14, desc); Wr32(b + 0x18, 0x180 + desc); Wr32(b + 0x1c, 0x180);
            Wr32(b + 0x20, 0x7c); Wr32(b + 0x24, 0x100); Wr8(b + 0x28, 0x84); Wr8(b + 0x29, 0x40);
            Wr32(b + 0x94, b + 0x100);
            Wr32(b, FifoMagic);
        }

        private void FifoInitWrite(uint b)
        {
            for(uint i = 0x144; i < 0x180; i += 4) Wr32(b + i, 0);
            Wr32(b + 0x140, FifoMagic);
            Wr8(b + 0x152, 2);          // cacheable, copy mode, not a ring
            Wr32(b + 0x158, b);
            Wr16(b + 0x168, 0x8000);
        }

        private void FifoWriteMedia(Pipe s)
        {
            uint b = s.Fifo, m = b + 0x7c;
            for(uint i = 4; i < 0x84; i += 4) Wr32(m + i, 0);
            bool opus = s.Codec == "opus";
            Wr32(m + 4, 0x30); Wr32(m + 8, opus ? 0x7375706fu : 0x6d6370u); Wr32(m + 0xc, 0);   // MediaOpus / MediaPcm
            Wr32(m + 0x10, 1);                                                // audio
            if(opus) Wr32(m + 0x1c, s.Bitrate);
            Wr32(m + 0x20, s.Rate); Wr8(m + 0x24, (byte)s.Channels);
            Wr16(m + 0x26, (ushort)(s.FrameBytes / (s.Channels * s.Bits / 8)));
            if(opus) Wr16(m + 0x2a, (ushort)s.Application);
            else { Wr8(m + 0x28, (byte)s.Bits); Wr8(m + 0x29, (byte)(s.Bits / 8)); }
            Wr16(b + 0x150, (ushort)(Rd16(b + 0x150) + 1));
            Wr32(b + 0x170, FifoMagic);
        }

        private bool FifoWrite(Pipe s, byte[] data)
        {
            uint b = s.Fifo;
            uint fmax = Rd32(b + 8), bmax = Rd32(b + 0x10), descOff = Rd32(b + 0x1c), dataOff = Rd32(b + 0x18);
            uint wrCnt = Rd32(b + 0x144), rdCnt = Rd32(b + 0x44);
            if(wrCnt - rdCnt >= fmax) return false;
            ulong pos = Rd64(b + 0x148), rdBytes = Rd64(b + 0x48);
            uint size = (uint)data.Length;
            ulong rem = bmax - pos % bmax; if(rem < size) pos += rem;
            ulong next = pos + size;
            if(bmax + rdBytes < next) return false;
            uint d = b + descOff + (wrCnt % fmax) * 0x28;
            uint payload = b + dataOff + (uint)(pos % bmax);
            Wr(payload, data);
            Wr32(d, size); Wr16(d + 4, 0); Wr16(d + 6, 0); Wr32(d + 8, s.Frames); Wr32(d + 0xc, (uint)((ulong)s.Frames * s.FrameUs / 1000));
            Wr32(d + 0x10, 0); Wr32(d + 0x14, dataOff + (uint)(pos % bmax)); Wr64(d + 0x18, pos); Wr32(d + 0x20, 0); Wr32(d + 0x24, 0);
            Wr64(b + 0x148, next);
            Wr32(b + 0x144, wrCnt + 1);
            return true;
        }

        // Reader side for AP->DSP streams: returns null when empty.
        private byte[] FifoRead(Pipe s)
        {
            uint b = s.Fifo;
            if(Rd32(b) != FifoMagic || Rd32(b + 0x140) != FifoMagic) return null;
            if(!s.ReaderReady) {
                for(uint i = 0x44; i < 0x80; i += 4) Wr32(b + i, 0);
                Wr8(b + 0x52, 2); Wr32(b + 0x58, b); Wr32(b + 0x40, FifoMagic);
                s.ReaderReady = true;
            }
            if(Rd32(b + 0x170) == FifoMagic && Rd16(b + 0x150) != s.MediaSeq) {
                s.MediaSeq = (ushort)Rd16(b + 0x150);
                uint m = b + 0x7c;
                s.Codec = KeyName(Rd64(m + 8)); s.Rate = Rd32(m + 0x20); s.Channels = Rd8(m + 0x24); s.Bits = Rd8(m + 0x28);
                s.FrameSamples = Rd16(m + 0x26);
                uint extraSize = Rd32(m + 0x14);
                s.Cookie = extraSize > 0 && extraSize <= 0x40 ? Rd(b + 0x100, (int)extraSize) : null;
                s.Decoder?.Dispose(); s.Decoder = null; s.DecoderFailed = false;
                this.Log(LogLevel.Info, "hifi4: {0} media {1} {2} Hz {3} ch {4} bit, {5} samples/frame", s.Name, s.Codec, s.Rate, s.Channels, s.Bits, s.FrameSamples);
            }
            uint fmax = Rd32(b + 8), descOff = Rd32(b + 0x1c);
            uint wrCnt = Rd32(b + 0x144), rdCnt = Rd32(b + 0x44);
            if(wrCnt == rdCnt) return null;
            uint d = b + descOff + (rdCnt % fmax) * 0x28;
            uint size = Rd32(d), ptr = Rd32(d + 0x10);
            uint data = ptr != 0 ? ptr : b + Rd32(d + 0x14);
            var bytes = Rd(data, (int)Math.Min(size, 0x20000));
            s.LastFlags = (ushort)Rd16(d + 4);   // 1 = bad frame (ScoService: CRC/header error or CVSD idle pattern)
            Wr64(b + 0x48, Rd64(d + 0x18) + size);
            Wr32(b + 0x44, rdCnt + 1);
            Wr16(b + 0x50, s.MediaSeq);
            return bytes;
        }

        private void PumpStream(Pipe s)
        {
            if(s.Writer) {
                if(s.Sco != null && s.Fifo == 0) {
                    // scoup: the AP allocates and opens the FIFO; write into it once it exists
                    if(!blocks.TryGetValue(s.Name, out var blk)) { s.NextTickUs = now * 1000; return; }
                    s.Fifo = blk.Address; FifoInitWrite(s.Fifo); FifoWriteMedia(s);
                }
                while(now * 1000 >= s.NextTickUs) {
                    s.NextTickUs += s.FrameUs;
                    var pcm = s.Sco != null ? null : MicFrame(s);
                    var frame = s.Sco != null ? ScoEncode(s) : s.Encoder != null ? s.Encoder.Encode(pcm) : pcm;
                    if(pcm == null) pcm = frame;
                    if(frame == null || frame.Length == 0) continue;
                    if(s.Head != 0) {
                        // head: u16 packet length, u16 0, u32 timestamp (ms since the stream started)
                        var h = new byte[s.Head + frame.Length];
                        BitConverter.GetBytes((ushort)frame.Length).CopyTo(h, 0); BitConverter.GetBytes(s.Frames * s.FrameMs).CopyTo(h, 4);
                        frame.CopyTo(h, (int)s.Head); frame = h;
                    }
                    if(FifoWrite(s, frame)) { s.Frames++; framesOut++; Tap(s, frame); }
                    else if(framesDropped++ % 100 == 0) this.Log(LogLevel.Info, "hifi4: {0} FIFO full (AP not reading), {1} frames dropped", s.Name, framesDropped);
                    if(s.Frames == 1 || s.Frames == 10 || (s.Frames % 100) == 0) this.Log(LogLevel.Info, "hifi4: {0} -> AP frame {1} ({2} bytes {3}, input peak {4})", s.Name, s.Frames, frame.Length, s.Codec, Peak(pcm));
                }
            } else if(s.Reader) {
                if(s.Fifo == 0 && s.Kfifo == 0 && blocks.TryGetValue(s.Name, out var blk)) s.Fifo = blk.Address;
                if(s.Fifo == 0 && s.Kfifo == 0) return;
                // The DSP plays in real time: take a frame only while less than 200 ms of decoded audio is
                // queued ahead of the (virtual) playback clock, so the AP is paced as by the real speaker DMA.
                // a pause of 300 ms ends the current utterance (the player keeps utterances whole)
                if(s.PlayStart >= 0 && s.SpeakerBytes > s.SegmentStart && now > s.LastAudio + 300) { SpeakerEvent("end " + s.Name); s.PlayStart = -1; }
                for(int i = 0; i < 16; i++) {
                    long played = s.PlayStart < 0 ? 0 : (long)(now - (ulong)s.PlayStart) * 48 * 4;   // bytes due by now
                    if(s.PlayStart >= 0 && s.SpeakerBytes - s.PlayedBase > played + 48 * 4 * 200) break;
                    var data = s.Kfifo != 0 ? A2dpRead(s) : FifoRead(s);
                    if(data == null) break;
                    if(s.PlayStart < 0) { s.PlayStart = (long)now; s.SegmentStart = s.SpeakerBytes; s.PlayedBase = s.SpeakerBytes; SpeakerEvent("start " + s.Name); }
                    s.LastAudio = now;
                    s.Frames++; framesIn++;
                    Speaker(s, data);
                    if(s.Frames == 1 || s.Frames == 10 || (s.Frames % 100) == 0) this.Log(LogLevel.Info, "hifi4: AP -> {0} frame {1} ({2} bytes {3}), {4} bytes 48 kHz stereo to the speaker", s.Name, s.Frames, data.Length, s.Codec, s.SpeakerBytes);
                }
            }
        }

        private static int Peak(byte[] pcm)
        {
            int peak = 0;
            for(int i = 0; i + 1 < pcm.Length; i += 2) peak = Math.Max(peak, Math.Abs((int)BitConverter.ToInt16(pcm, i)));
            return peak;
        }

        // ---------------------------------------------------------------- host audio
        // ---- microphone timeline: one 16 kHz mono signal indexed by virtual time, shared by every
        // consumer (DSP record streams, codec ADC2 for the BTH, the wake-word spotter), like the real mics.
        public long MicNow() { return (long)(machine.ElapsedVirtualTime.TimeElapsed.TotalSeconds * MicRate); }
        public short[] MicSamples(long start, int count) { return MicSamples(start, count, ring); }
        private short[] MicSamples(long start, int count, short[] source)
        {
            lock(micLock) {
                Fill(start + count);
                var r = new short[Math.Max(0, count)];
                for(int i = 0; i < r.Length; i++) {
                    long idx = start + i;
                    if(idx >= 0 && idx < ringEnd && idx >= ringEnd - Ring) r[i] = source[idx % Ring];
                }
                return r;
            }
        }
        // Noise suppression in the record path (the stand-in for the "up" library); off = raw microphone.
        public bool NoiseSuppression { get; set; } = true;
        // A wake word recognised by the host (the Mac app's on-device speech recogniser) that ends at byte
        // <offset> of MicFile; it counts when the timeline reaches that audio. event: 4 小雷小雷, 2 ok, 3 hey rayneo.
        public void KeywordAt(long offset, uint ev) { lock(micLock) hostKeywords.Add(new KeyValuePair<long, uint>(offset, ev)); }

        // Restart a file input "now" (scenarios: the WAV is spoken from this moment).
        public void MicRestart() { lock(micLock) { Fill(MicNow()); srcPos = -1; this.Log(LogLevel.Info, "hifi4: t={0:0.000}s microphone file restarted", MicNow() / (double)MicRate); } }

        private void Fill(long upTo)
        {
            if(ringEnd < upTo - Ring) ringEnd = upTo - Ring;
            while(ringEnd < upTo) {
                int n = (int)Math.Min(upTo - ringEnd, 160);
                var block = ReadSource(n);
                for(int i = 0; i < n; i++) ring[(ringEnd + i) % Ring] = block[i];
                // the "up" library's output (noise suppressed, 32 ms later), same indexing
                var clean = (short[])block.Clone();
                if(NoiseSuppression) ns.Process(clean, n);
                for(int i = 0; i < n; i++) nsRing[(ringEnd + i) % Ring] = clean[i];
                ringEnd += n;
                Spot(block, n, ringEnd);
                if(hostReported) {
                    hostReported = false;
                    this.Log(LogLevel.Info, "hifi4: t={0:0.000}s wake word (event {1}) recognised by the Mac", ringEnd / (double)MicRate, lastKeywordEvent);
                    OnKeyword();
                }
            }
        }

        private short[] ReadSource(int n)
        {
            var r = new short[n];
            if(string.IsNullOrEmpty(micPath)) return r;
            try {
                if(micStream == null) {
                    micStream = new FileStream(micPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 1);   // unbuffered: the file grows
                    micDataStart = WavDataOffset(micStream);
                    srcPos = MicLive ? micStream.Length & ~1L : micDataStart;
                    this.Log(LogLevel.Info, "hifi4: microphone input {0}{1}", micPath, MicLive ? " (live)" : "");
                }
                if(srcPos < 0) srcPos = micDataStart;
                long length = micStream.Length & ~1L;
                if(MicLive) {
                    // The emulator runs slower than real time: keep the backlog short by dropping silence
                    // (speech is always delivered whole); a long run of speech is cut only past 20 s.
                    long backlog = (length - srcPos) / 2;
                    // continuous sound cannot be delivered whole 8x slower: keep at most 4 s of latency
                    if(backlog > 4 * MicRate) { long jump = (backlog - MicRate) * 2; srcPos += jump; skipped += jump / 2; backlog = MicRate; }
                    // Only long pauses (> 0.4 s) are shortened, to 0.2 s: speech keeps its natural gaps,
                    // which the stock VAD needs.
                    if(backlog > MicRate / 2) {
                        var probe = new byte[320]; int quiet = 0; long scan = srcPos;
                        while((length - scan) / 2 > MicRate / 4) {
                            micStream.Position = scan; micStream.Read(probe, 0, 320);
                            double e = 0; for(int i = 0; i < 160; i++) { double v = BitConverter.ToInt16(probe, 2 * i); e += v * v; }
                            double rms = Math.Sqrt(e / 160);
                            noiseFloor = rms < noiseFloor ? 0.9 * noiseFloor + 0.1 * rms : 0.99 * noiseFloor + 0.01 * rms;   // ~1 s up
                            if(rms > Math.Max(400, noiseFloor * 4)) break;
                            quiet++; scan += 320;
                        }
                        if(quiet > 40) { long drop = (quiet - 20) * 320L; srcPos += drop; skipped += drop / 2; }
                    }
                }
                var buf = new byte[n * 2];
                int got = 0;
                while(got < buf.Length) {
                    micStream.Position = srcPos;
                    int k = micStream.Read(buf, got, buf.Length - got);
                    if(k > 0) { got += k; srcPos += k; continue; }
                    if(MicLoop && !MicLive && length > micDataStart + 2) srcPos = micDataStart; else break;
                }
                for(int i = 0; i < got / 2; i++) r[i] = BitConverter.ToInt16(buf, 2 * i);
                if(MicLive) {
                    double e = 0; for(int i = 0; i < got / 2; i++) e += (double)r[i] * r[i];
                    bool loud = got > 0 && Math.Sqrt(e / (got / 2)) > 800;
                    if(loud && !liveSpeech && liveLogBudget-- > 0)
                        this.Log(LogLevel.Info, "hifi4: t={0:0.000}s live speech reaches the microphone timeline (backlog {1:0.00} s, {2:0.0} s of silence dropped so far)",
                            ringEnd / (double)MicRate, (length - srcPos) / 2.0 / MicRate, skipped / (double)MicRate);
                    if(loud) { liveSpeech = true; quietBlocks = 0; } else if(++quietBlocks > 100) liveSpeech = false;
                }
                for(int k = hostKeywords.Count - 1; k >= 0; k--) {
                    if(hostKeywords[k].Key > srcPos) continue;
                    if(hostKeywords[k].Key > srcPos - got - 32000) {
                        lastKeyword = ringEnd + got / 2; lastKeywordEvent = hostKeywords[k].Value; hostReported = true;
                    }
                    hostKeywords.RemoveAt(k);
                }
            } catch(Exception e) {
                if(errorBudget-- > 0) this.Log(LogLevel.Warning, "hifi4: microphone {0}: {1}", micPath, e.Message);
            }
            return r;
        }

        private void Spot(short[] block, int n, long end)
        {
            if(wakeStream < 0) return;   // the "wakeup" library only runs on the open wakeup stream
            // The AP accepts 小雷小雷 (4) in word mode 1 and OK/Hey RayNeo (2/3) in word mode 2
            // (rayneo_audio_kws_use_eng_word_only flag 0x19d0e4c8); listen for that set only.
            bool english = Rd8(WordModeFlag) != 0;
            if(!english && keywordNet != null) {
                if(keywordNet.Push(block, n) < 0) return;
                this.Log(LogLevel.Info, "hifi4: t={0:0.000}s wake word 「小雷小雷」 found in the wakeup stream audio (classifier {1:0.000})", end / (double)MicRate, keywordNet.LastScore);
                DecideWake(4);
                return;
            }
            foreach(var kv in LoadSpotters()) {
                if((kv.Key == 4) == english) continue;
                if(kv.Value.Push(block, n) < 0) continue;
                this.Log(LogLevel.Info, "hifi4: t={0:0.000}s wake word {1} found in the wakeup stream audio (score {2:0.0})", end / (double)MicRate,
                    kv.Key == 4 ? "「小雷小雷」" : kv.Key == 2 ? "\"OK RayNeo\"" : "\"Hey RayNeo\"", kv.Value.LastBest);
                DecideWake(kv.Key);
                return;
            }
        }

        private byte[] MicFrame(Pipe s)
        {
            int frameSamples = (int)(s.FrameBytes / (s.Channels * 2));
            // Record streams get the "up" output (noise suppressed); the wakeup stream (0x1b) is fed from the
            // BTH VAD history, which does not go through "up" (smf.json arserver sink 0x1b: pcm-preset keys=vad).
            var mono = MicSamples(s.NextSample, frameSamples, s.Index == WakeupStream ? ring : nsRing);
            s.NextSample += frameSamples;
            // Every channel of the requested layout carries the same signal (one talker).
            var frame = new byte[s.FrameBytes];
            for(int i = 0; i < frameSamples; i++)
                for(int c = 0; c < s.Channels; c++) { frame[(i * s.Channels + c) * 2] = (byte)mono[i]; frame[(i * s.Channels + c) * 2 + 1] = (byte)(mono[i] >> 8); }
            return frame;
        }

        private void Tap(Pipe s, byte[] frame)
        {
            if(string.IsNullOrEmpty(TapDirectory)) return;
            try {
                using(var f = new FileStream(Path.Combine(TapDirectory, s.Name + "." + s.Codec), FileMode.Append, FileAccess.Write, FileShare.ReadWrite)) {
                    if(s.Codec != "pcm") { f.WriteByte((byte)frame.Length); f.WriteByte((byte)(frame.Length >> 8)); }
                    f.Write(frame, 0, frame.Length);
                }
            } catch(Exception e) { if(errorBudget-- > 0) this.Log(LogLevel.Warning, "hifi4: tap: {0}", e.Message); }
        }

        private static long WavDataOffset(FileStream f)
        {
            var h = new byte[12];
            if(f.Read(h, 0, 12) < 12 || Encoding.ASCII.GetString(h, 0, 4) != "RIFF") return 0;
            var c = new byte[8];
            while(f.Read(c, 0, 8) == 8) {
                string id = Encoding.ASCII.GetString(c, 0, 4); uint len = BitConverter.ToUInt32(c, 4);
                if(id == "data") return f.Position;
                f.Position += len + (len & 1);
            }
            return 0;
        }

        // speaker.events: "<byte offset in speaker.raw> start|end <stream>" so a player can keep utterances whole.
        private void SpeakerEvent(string what)
        {
            if(string.IsNullOrEmpty(spkPath)) return;
            try {
                long offset = spkStream != null ? spkStream.Length : (File.Exists(spkPath) ? new FileInfo(spkPath).Length : 0);
                File.AppendAllText(spkPath.Substring(0, spkPath.Length - Path.GetExtension(spkPath).Length) + ".events", offset + " " + what + "\n");
            } catch(Exception e) { if(errorBudget-- > 0) this.Log(LogLevel.Warning, "hifi4: speaker events: {0}", e.Message); }
        }

        private void Speaker(Pipe s, byte[] data)
        {
            if(string.IsNullOrEmpty(spkPath)) return;
            try {
                if(spkStream == null) spkStream = new FileStream(spkPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
                if(s.Latm != null) {
                    // A2DP: one AAC access unit (AudioToolbox, cookie = the in-band AudioSpecificConfig)
                    if(s.Decoder == null && !s.DecoderFailed) {
                        try {
                            s.Decoder = new HostDecoder("aac", (uint)s.Latm.SampleRate, (uint)s.Latm.Channels, 1024, LatmDemuxer.Esds(s.Latm.AudioSpecificConfig));
                            this.Log(LogLevel.Info, "hifi4: {0}: AAC {1} Hz {2} ch from the LATM stream", s.Name, s.Latm.SampleRate, s.Latm.Channels);
                        } catch(Exception x) { s.DecoderFailed = true; this.Log(LogLevel.Warning, "hifi4: {0}: no AAC decoder ({1})", s.Name, x.Message); }
                    }
                    if(s.Decoder == null) return;
                    var music = s.Decoder.Decode(data);
                    s.SpeakerBytes += music.Length;
                    spkStream.Write(music, 0, music.Length); spkStream.Flush();
                    return;
                }
                if(s.Codec == "msbc" || s.Codec == "cvsd") {
                    // call audio: decode (bad frames concealed), 16/8 kHz mono -> the 48 kHz stereo mix
                    if(s.Sco == null || (s.Sco is MsbcCodec) != (s.Codec == "msbc")) s.Sco = s.Codec == "msbc" ? (object)new MsbcCodec() : new CvsdCodec();
                    bool bad = s.LastFlags != 0;
                    var voice = s.Sco is MsbcCodec m ? m.Decode(data, bad) : ((CvsdCodec)s.Sco).Decode(data, bad);
                    var mix = Upsample(s, voice, s.Codec == "msbc" ? 3 : 6);
                    s.SpeakerBytes += mix.Length;
                    spkStream.Write(mix, 0, mix.Length); spkStream.Flush();
                    return;
                }
                if(s.Decoder == null && !s.DecoderFailed) {
                    try { s.Decoder = new HostDecoder(s.Codec, s.Rate == 0 ? 48000 : s.Rate, s.Channels == 0 ? 2 : s.Channels, s.FrameSamples, s.Cookie); }
                    catch(Exception x) { s.DecoderFailed = true; this.Log(LogLevel.Warning, "hifi4: {0}: no decoder for {1} ({2}); frames written undecoded to {3}.{1}", s.Name, s.Codec, x.Message, spkPath); }
                }
                if(s.Decoder == null) {
                    using(var raw = new FileStream(spkPath + "." + s.Codec, FileMode.Append, FileAccess.Write, FileShare.ReadWrite)) raw.Write(data, 0, data.Length);
                    return;
                }
                var pcm = s.Decoder.Decode(data);
                s.SpeakerBytes += pcm.Length;
                spkStream.Write(pcm, 0, pcm.Length); spkStream.Flush();
            } catch(Exception e) {
                if(errorBudget-- > 0) this.Log(LogLevel.Warning, "hifi4: speaker {0}: {1}", spkPath, e.Message);
            }
        }

        // Next AAC access unit from the A2DP kfifo (the AP advances "in", the DSP "out"), or null.
        private byte[] A2dpRead(Pipe s)
        {
            uint k = s.Kfifo;
            var au = s.Latm.Next();
            if(au != null) return au;
            uint buf = Rd32(k), size = Rd32(k + 4), inCnt = Rd32(k + 8), outCnt = Rd32(k + 0xc);
            if(size == 0 || (size & (size - 1)) != 0) return null;
            uint len = Math.Min(inCnt - outCnt, 4096u);
            if(len == 0) return null;
            uint off = outCnt & (size - 1), first = Math.Min(len, size - off);
            var data = new byte[len];
            Rd(buf + off, (int)first).CopyTo(data, 0);
            if(len > first) Rd(buf, (int)(len - first)).CopyTo(data, (int)first);
            Wr32(k + 0xc, outCnt + len);
            if(s.Codec != "aac") {
                if(errorBudget-- > 0) this.Log(LogLevel.Warning, "hifi4: {0}: {1} in the A2DP kfifo is not supported (only AAC LATM framing is known); dropped", s.Name, s.Codec);
                return null;
            }
            s.Latm.Append(data);
            return s.Latm.Next();
        }

        // 7.5 ms of the uplink microphone (the "up" output, as the call path uses it) encoded for scoup.
        private byte[] ScoEncode(Pipe s)
        {
            var mic = MicSamples(s.NextSample, 120, nsRing); s.NextSample += 120;
            if(s.Sco is MsbcCodec m) return m.Encode(mic);
            var narrow = new short[60];
            for(int i = 0; i < 60; i++) narrow[i] = (short)((mic[2 * i] + mic[2 * i + 1]) / 2);
            return ((CvsdCodec)s.Sco).Encode(narrow);
        }

        // Mono voice at 48000/factor Hz -> 48 kHz stereo s16le (linear interpolation).
        private static byte[] Upsample(Pipe s, short[] x, int factor)
        {
            var o = new byte[x.Length * factor * 4];
            for(int i = 0, k = 0; i < x.Length; i++) {
                for(int j = 1; j <= factor; j++, k += 4) {
                    short v = (short)(s.LastSample + (x[i] - s.LastSample) * j / factor);
                    o[k] = (byte)v; o[k + 1] = (byte)(v >> 8); o[k + 2] = (byte)v; o[k + 3] = (byte)(v >> 8);
                }
                s.LastSample = x[i];
            }
            return o;
        }

        // ---------------------------------------------------------------- bus helpers
        // AP SRAM 0x20000000-0x20bfffff is mapped per CPU; the device alias 0x21000000 is global.
        private static ulong G(uint a) { return a >= 0x20000000 && a < 0x20c00000 ? a + 0x01000000UL : a; }
        private IBusController Bus => machine.GetSystemBus(this);
        private uint Rd32(uint a) { return Bus.ReadDoubleWord(G(a)); }
        private uint Rd16(uint a) { return Bus.ReadWord(G(a)); }
        private byte Rd8(uint a) { return Bus.ReadByte(G(a)); }
        private ulong Rd64(uint a) { return Rd32(a) | ((ulong)Rd32(a + 4) << 32); }
        private byte[] Rd(uint a, int n) { return n <= 0 ? new byte[0] : Bus.ReadBytes(G(a), n); }
        private void Wr32(uint a, uint v) { Bus.WriteDoubleWord(G(a), v); }
        private void Wr16(uint a, ushort v) { Bus.WriteWord(G(a), v); }
        private void Wr16(uint a, uint v) { Bus.WriteWord(G(a), (ushort)v); }
        private void Wr8(uint a, byte v) { Bus.WriteByte(G(a), v); }
        private void Wr64(uint a, ulong v) { Wr32(a, (uint)v); Wr32(a + 4, (uint)(v >> 32)); }
        private void Wr(uint a, byte[] d) { if(d.Length > 0) Bus.WriteBytes(d, G(a)); }

        private sealed class Block { public uint Address; public uint Size; }
        private sealed class Pipe
        {
            public byte Index; public string Name; public string Param; public int Refs;
            public bool Writer, Reader, ReaderReady; public uint Fifo; public ushort MediaSeq;
            public uint Rate = 16000, Channels = 1, Bits = 16, FrameBytes = 1920, FrameMs = 60; public string Codec = "pcm";
            public uint Kfifo; public LatmDemuxer Latm;
            public ulong NextTickUs; public uint FrameUs; public object Sco; public ushort LastFlags; public short LastSample; public uint Frames; public long NextSample; public uint Bitrate, Application, FrameSamples, Head; public long SpeakerBytes; public byte[] Cookie;
            public HostOpusEncoder Encoder;
            public HostDecoder Decoder; public bool DecoderFailed; public long PlayStart = -1, SegmentStart, PlayedBase; public ulong LastAudio;
        }

        // Opus via macOS AudioToolbox (kAudioFormatOpus), one packet per FIFO frame (haveHead=0: raw packets).
        public sealed class HostOpusEncoder : IDisposable
        {
            public HostOpusEncoder(uint rate, uint channels, uint frameSamples, uint bitrate, bool constant = false)
            {
                var src = new ASBD { SampleRate = rate, FormatID = 0x6c70636d /* lpcm */, FormatFlags = 0xc /* signed int, packed */,
                    BytesPerPacket = 2 * channels, FramesPerPacket = 1, BytesPerFrame = 2 * channels, ChannelsPerFrame = channels, BitsPerChannel = 16 };
                var dst = new ASBD { SampleRate = rate, FormatID = 0x6f707573 /* opus */, ChannelsPerFrame = channels, FramesPerPacket = frameSamples };
                int st = AudioConverterNew(ref src, ref dst, out conv);
                if(st != 0) throw new InvalidOperationException("AudioConverterNew " + st);
                uint br = bitrate; AudioConverterSetProperty(conv, 0x62726174 /* brat */, 4, ref br);
                // constant bit rate: every 60 ms packet is exactly br*60ms/8 bytes (32 kbps -> 240 B)
                if(constant) { uint mode = 0; AudioConverterSetProperty(conv, 0x61636266 /* acbf */, 4, ref mode); }
                this.channels = channels;
                pcm = Marshal.AllocHGlobal(0x10000); outBuf = Marshal.AllocHGlobal(4096); list = Marshal.AllocHGlobal(24); desc = Marshal.AllocHGlobal(16);
                proc = Input;
            }
            public byte[] Encode(byte[] samples)
            {
                Marshal.Copy(samples, 0, pcm, Math.Min(samples.Length, 0x10000)); pending = (uint)samples.Length; offset = 0;
                Marshal.WriteInt32(list, 0, 1); Marshal.WriteInt32(list, 8, (int)channels); Marshal.WriteInt32(list, 12, 4096); Marshal.WriteIntPtr(list, 16, outBuf);
                uint packets = 1;
                int st = AudioConverterFillComplexBuffer(conv, proc, IntPtr.Zero, ref packets, list, desc);
                if((st != 0 && st != 1) || packets == 0) return null;
                var r = new byte[Marshal.ReadInt32(list, 12)]; Marshal.Copy(outBuf, r, 0, r.Length);
                return r;
            }
            private int Input(IntPtr c, ref uint packets, IntPtr io, IntPtr outDesc, IntPtr user)
            {
                uint frameBytes = 2 * channels, avail = (pending - offset) / frameBytes;
                if(avail == 0) { packets = 0; return 1; }     // "no more data for now"; the converter keeps its state
                if(packets > avail) packets = avail;
                Marshal.WriteInt32(io, 0, 1); Marshal.WriteInt32(io, 8, (int)channels); Marshal.WriteInt32(io, 12, (int)(packets * frameBytes));
                Marshal.WriteIntPtr(io, 16, pcm + (int)offset);
                offset += packets * frameBytes;
                return 0;
            }
            public void Dispose()
            {
                if(conv != IntPtr.Zero) AudioConverterDispose(conv);
                conv = IntPtr.Zero;
                Marshal.FreeHGlobal(pcm); Marshal.FreeHGlobal(outBuf); Marshal.FreeHGlobal(list); Marshal.FreeHGlobal(desc);
            }
            [StructLayout(LayoutKind.Sequential)]
            private struct ASBD { public double SampleRate; public uint FormatID, FormatFlags, BytesPerPacket, FramesPerPacket, BytesPerFrame, ChannelsPerFrame, BitsPerChannel, Reserved; }
            private delegate int InputProc(IntPtr conv, ref uint packets, IntPtr bufferList, IntPtr packetDesc, IntPtr user);
            private const string AT = "/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox";
            [DllImport(AT)] private static extern int AudioConverterNew(ref ASBD src, ref ASBD dst, out IntPtr conv);
            [DllImport(AT)] private static extern int AudioConverterSetProperty(IntPtr conv, uint id, uint size, ref uint data);
            [DllImport(AT)] private static extern int AudioConverterFillComplexBuffer(IntPtr conv, InputProc proc, IntPtr user, ref uint packets, IntPtr list, IntPtr desc);
            [DllImport(AT)] private static extern int AudioConverterDispose(IntPtr conv);
            private IntPtr conv, pcm, outBuf, list, desc;
            private readonly InputProc proc;
            private readonly uint channels;
            private uint pending, offset;
        }

        // Decoder for AP->DSP streams (what the DSP "dec" + "fmt-pcm" elements do): any AudioToolbox codec
        // (mp3, aac, opus, pcm) to the apserver mix format, 48 kHz stereo s16le.
        public sealed class HostDecoder : IDisposable
        {
            public HostDecoder(string codec, uint rate, uint channels, uint framesPerPacket, byte[] cookie)
            {
                var dst = new ASBD { SampleRate = 48000, FormatID = 0x6c70636d, FormatFlags = 0xc, BytesPerPacket = 4, FramesPerPacket = 1, BytesPerFrame = 4, ChannelsPerFrame = 2, BitsPerChannel = 16 };
                var src = new ASBD { SampleRate = rate, ChannelsPerFrame = Math.Max(1u, channels) };
                switch(codec) {
                    case "pcm": src.FormatID = 0x6c70636d; src.FormatFlags = 0xc; src.BytesPerPacket = src.BytesPerFrame = 2 * src.ChannelsPerFrame; src.FramesPerPacket = 1; src.BitsPerChannel = 16; pcm = true; break;
                    case "mp3": src.FormatID = 0x2e6d7033; src.FramesPerPacket = 1152; break;
                    case "aac": src.FormatID = 0x61616320; src.FramesPerPacket = 1024; break;
                    case "opus": src.FormatID = 0x6f707573; src.FramesPerPacket = framesPerPacket != 0 ? framesPerPacket : 960; break;
                    default: throw new NotSupportedException(codec);
                }
                int st = AudioConverterNew(ref src, ref dst, out conv);
                if(st != 0) throw new InvalidOperationException("AudioConverterNew " + codec + " " + st);
                if(cookie != null && cookie.Length > 0) {
                    var c = Marshal.AllocHGlobal(cookie.Length); Marshal.Copy(cookie, 0, c, cookie.Length);
                    AudioConverterSetPropertyPtr(conv, 0x646d6763 /* dmgc */, (uint)cookie.Length, c); Marshal.FreeHGlobal(c);
                }
                bytesPerSrcFrame = 2 * src.ChannelsPerFrame;
                inBuf = Marshal.AllocHGlobal(0x20000); outBuf = Marshal.AllocHGlobal(OutBytes); list = Marshal.AllocHGlobal(24); desc = Marshal.AllocHGlobal(16);
                proc = Input;
            }
            public byte[] Decode(byte[] packet)
            {
                int n = Math.Min(packet.Length, 0x20000);
                Marshal.Copy(packet, 0, inBuf, n); pending = (uint)n; consumed = false;
                var result = new List<byte>();
                for(int guard = 0; guard < 16; guard++) {
                    Marshal.WriteInt32(list, 0, 1); Marshal.WriteInt32(list, 8, 2); Marshal.WriteInt32(list, 12, OutBytes); Marshal.WriteIntPtr(list, 16, outBuf);
                    uint frames = OutBytes / 4;
                    int st = AudioConverterFillComplexBuffer(conv, proc, IntPtr.Zero, ref frames, list, IntPtr.Zero);
                    int bytes = Marshal.ReadInt32(list, 12);
                    if(frames > 0 && bytes > 0) { var chunk = new byte[bytes]; Marshal.Copy(outBuf, chunk, 0, bytes); result.AddRange(chunk); }
                    if(st != 0 || frames == 0) break;
                }
                return result.ToArray();
            }
            private int Input(IntPtr c, ref uint packets, IntPtr io, IntPtr outDesc, IntPtr user)
            {
                if(consumed || pending == 0) { packets = 0; return 1; }
                Marshal.WriteInt32(io, 0, 1); Marshal.WriteInt32(io, 8, 0); Marshal.WriteInt32(io, 12, (int)pending); Marshal.WriteIntPtr(io, 16, inBuf);
                if(pcm) packets = pending / bytesPerSrcFrame;
                else {
                    packets = 1;
                    // AudioStreamPacketDescription { SInt64 start; UInt32 variableFrames; UInt32 size }
                    Marshal.WriteInt64(desc, 0, 0); Marshal.WriteInt32(desc, 8, 0); Marshal.WriteInt32(desc, 12, (int)pending);
                    if(outDesc != IntPtr.Zero) Marshal.WriteIntPtr(outDesc, desc);
                }
                consumed = true;
                return 0;
            }
            public void Dispose()
            {
                if(conv != IntPtr.Zero) AudioConverterDispose(conv);
                conv = IntPtr.Zero;
                Marshal.FreeHGlobal(inBuf); Marshal.FreeHGlobal(outBuf); Marshal.FreeHGlobal(list); Marshal.FreeHGlobal(desc);
            }
            [StructLayout(LayoutKind.Sequential)]
            private struct ASBD { public double SampleRate; public uint FormatID, FormatFlags, BytesPerPacket, FramesPerPacket, BytesPerFrame, ChannelsPerFrame, BitsPerChannel, Reserved; }
            private delegate int InputProc(IntPtr conv, ref uint packets, IntPtr bufferList, IntPtr packetDesc, IntPtr user);
            private const string AT = "/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox";
            private const int OutBytes = 0x10000;
            [DllImport(AT)] private static extern int AudioConverterNew(ref ASBD src, ref ASBD dst, out IntPtr conv);
            [DllImport(AT, EntryPoint = "AudioConverterSetProperty")] private static extern int AudioConverterSetPropertyPtr(IntPtr conv, uint id, uint size, IntPtr data);
            [DllImport(AT)] private static extern int AudioConverterFillComplexBuffer(IntPtr conv, InputProc proc, IntPtr user, ref uint packets, IntPtr list, IntPtr desc);
            [DllImport(AT)] private static extern int AudioConverterDispose(IntPtr conv);
            private IntPtr conv, inBuf, outBuf, list, desc;
            private readonly InputProc proc;
            private readonly bool pcm;
            private readonly uint bytesPerSrcFrame;
            private uint pending; private bool consumed;
        }

        // DSP DTCM as seen by the AP (DSP-local 0x20880000-0x208fffff).
        private const uint ApLocalWord = 0x20afffa0, ApPeerWord = 0x20afffa4;
        private const uint ChanTable = 0x20afff00, MsgList0 = 0x20afff40, MsgList1 = 0x20affe00, MsgCount = 5;
        private const uint Rsc = 0x23c00260, IcsBlock = 0x23c1d000, WordModeFlag = 0x19d0e4c8;
        private const uint Vring0 = 0x20af0000, Vring0Num = 8, VringAlign = 8, BufSize = 0x200, VringBytes = 0xe0;
        private const uint HeapBase = 0x20a80000, HeapEnd = 0x20af0000;
        private const uint NsAddr = 53, SmfEpt = 1024;
        private const string SmfEptName = "smf_m55c0_hifi4";
        private const uint FifoMagic = 0x55aa5a5a;

        private readonly IMachine machine;
        private readonly BES1700_ClockControl mailbox;
        private readonly LimitTimer timer;
        private readonly object sync = new object();
        private readonly Queue<byte[]> outbox = new Queue<byte[]>();
        private readonly Queue<uint> txValues = new Queue<uint>();
        private readonly Dictionary<byte, Pipe> streams = new Dictionary<byte, Pipe>();
        private readonly Dictionary<string, Block> blocks = new Dictionary<string, Block>();
        private readonly List<Block> freeList = new List<Block>();
        private volatile bool doorbell;
        private int state, smfApAddr = -1;
        private uint ourRd, ourWr, ics, notify0 = 1, notify1 = 2, vring1, vring1Num, vring1Align = 8, heapNext = HeapBase;
        private ushort lastAvail0, lastAvail1;
        private ulong now; private uint icsSeen = 0xffffffff;
        private long framesOut, framesIn, framesDropped;
        private int errorBudget = 20, rmtLogBudget = 12, nsLogBudget = 40, smfLogBudget = 200;
        private string micPath, spkPath, kwsDir;
        private SortedDictionary<uint, HiFi4KeywordSpotter> spotters;
        private static readonly SortedDictionary<uint, HiFi4KeywordSpotter> empty = new SortedDictionary<uint, HiFi4KeywordSpotter>();
        private int wakeStream = -1; private long wakeDeadline; private uint lastKeywordEvent = 4; private byte notifySeq;
        private FileStream micStream, spkStream;
        private long micDataStart, srcPos = -1, ringEnd, skipped, lastKeyword = long.MinValue, spotBase;
        private double noiseFloor = 200;
        private readonly short[] ring = new short[Ring], nsRing = new short[Ring];
        private readonly HiFi4NoiseSuppressor ns = new HiFi4NoiseSuppressor();
        private readonly object micLock = new object();
        private readonly List<KeyValuePair<long, uint>> hostKeywords = new List<KeyValuePair<long, uint>>();
        private bool hostReported, liveSpeech; private int quietBlocks, liveLogBudget = 50;
        private const int MicRate = 16000, Ring = 60 * MicRate;
        private const byte WakeupStream = 0x1b;
        private const int WakeHistory = 3 * MicRate;
    }
}
