// A2DP sink input of the HiFi4 stand-in (smf 0x24 a2dpdn, "src-a2dp"): the AP's bluetooth audio path pushes the
// phone's AAC into a Linux-style kfifo in AP PSRAM ({u8* buf; u32 size; u32 in; u32 out}, free-running counters,
// address in the Add string "kfifo=#<decimal>") as LATM AudioMuxElements (muxConfigPresent = 1, the LOAS 3-byte
// sync header already removed; FDK TT_MP4_LATM_MCP1, "pkg=#6"). See .local/research/audio/bt-audio.md 2.
// This class splits that byte stream into AudioMuxElements and returns the raw AAC access units plus the
// AudioSpecificConfig from the in-band StreamMuxConfig (which the decoder needs as its magic cookie).
using System;
using System.Collections.Generic;

namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public sealed class LatmDemuxer
    {
        public byte[] AudioSpecificConfig { get; private set; }
        public int SampleRate { get; private set; }
        public int Channels { get; private set; }

        public void Append(byte[] data) { buffer.AddRange(data); }

        // Next raw AAC access unit, or null when no complete AudioMuxElement is buffered yet.
        public byte[] Next()
        {
            while(buffer.Count > 0) {
                var bytes = buffer.ToArray();
                try {
                    var r = new Bits(bytes);
                    var au = Element(r);
                    int used = (r.Position + 7) / 8;   // AudioSyncStream pads every element to a byte
                    if(used > bytes.Length) return null;
                    buffer.RemoveRange(0, used);
                    if(au != null) return au;
                } catch(IndexOutOfRangeException) {
                    if(buffer.Count > 8192) buffer.Clear();   // not LATM: drop rather than grow
                    return null;
                }
            }
            return null;
        }

        private byte[] Element(Bits r)
        {
            if(r.Get(1) == 0) StreamMuxConfig(r);   // useSameStreamMux
            else if(!configured) throw new IndexOutOfRangeException();
            if(versionA != 0) return null;
            byte[] au = null;
            for(int i = 0; i <= numSubFrames; i++) {
                int len = 0, t;
                do { t = r.Get(8); len += t; } while(t == 255);   // PayloadLengthInfo (frameLengthType 0)
                var p = new byte[len];
                for(int k = 0; k < len; k++) p[k] = (byte)r.Get(8);
                if(au == null) au = p;
            }
            if(otherDataBits > 0) r.Skip(otherDataBits);
            return au;
        }

        private void StreamMuxConfig(Bits r)
        {
            int version = r.Get(1);
            versionA = version == 1 ? r.Get(1) : 0;
            if(versionA != 0) return;
            if(version == 1) LatmValue(r);   // taraBufferFullness
            r.Get(1);   // allStreamsSameTimeFraming
            numSubFrames = r.Get(6);
            int programs = r.Get(4) + 1;
            for(int p = 0; p < programs; p++) {
                int layers = r.Get(3) + 1;
                for(int l = 0; l < layers; l++) {
                    bool same = (p == 0 && l == 0) ? false : r.Get(1) == 1;
                    if(!same) {
                        if(version == 0) { int start = r.Position; AscFields(r); AudioSpecificConfig = r.Slice(start, r.Position - start); }
                        else {
                            int ascLen = LatmValue(r), start = r.Position; AscFields(r);
                            AudioSpecificConfig = r.Slice(start, r.Position - start); r.Seek(start + ascLen);
                        }
                    }
                    int frameLengthType = r.Get(3);
                    if(frameLengthType == 0) r.Get(8);   // latmBufferFullness
                    else if(frameLengthType == 1) r.Get(9);
                    else if(frameLengthType >= 3 && frameLengthType <= 5) r.Get(6);
                    else if(frameLengthType == 6 || frameLengthType == 7) r.Get(1);
                }
            }
            otherDataBits = 0;
            if(r.Get(1) == 1) {
                if(version == 1) otherDataBits = LatmValue(r);
                else { int esc; do { esc = r.Get(1); otherDataBits = (otherDataBits << 8) + r.Get(8); } while(esc == 1); }
            }
            if(r.Get(1) == 1) r.Get(8);   // crcCheckSum
            configured = true;
        }

        private void AscFields(Bits r)
        {
            int aot = r.Get(5); if(aot == 31) aot = 32 + r.Get(6);
            int fi = r.Get(4); int rate = fi == 15 ? r.Get(24) : Rates[Math.Min(fi, Rates.Length - 1)];
            int ch = r.Get(4);
            if(aot == 5 || aot == 29) {   // SBR/PS: extension sampling rate and the core object type
                int efi = r.Get(4); rate = efi == 15 ? r.Get(24) : Rates[Math.Min(efi, Rates.Length - 1)];
                aot = r.Get(5); if(aot == 31) aot = 32 + r.Get(6);
            }
            if(aot == 1 || aot == 2 || aot == 3 || aot == 4 || aot == 6 || aot == 7 || aot == 17 || aot == 19 || aot == 20 || aot == 21 || aot == 22 || aot == 23) {
                r.Get(1);   // frameLengthFlag
                if(r.Get(1) == 1) r.Get(14);   // dependsOnCoreCoder: coreCoderDelay
                int ext = r.Get(1);
                if(ch == 0) throw new NotSupportedException("program_config_element in LATM AudioSpecificConfig");
                if((aot == 6 || aot == 20)) r.Get(3);
                if(ext == 1) { if(aot == 22) r.Get(16); if(aot >= 17 && aot <= 23) r.Get(3); r.Get(1); }
            }
            SampleRate = rate; Channels = ch;
        }

        private static int LatmValue(Bits r) { int n = r.Get(2) + 1, v = 0; for(int i = 0; i < n; i++) v = (v << 8) + r.Get(8); return v; }

        // MP4 ES descriptor around the AudioSpecificConfig: the magic cookie AudioToolbox's AAC decoder takes.
        public static byte[] Esds(byte[] asc)
        {
            var dsi = new List<byte> { 0x05, (byte)asc.Length }; dsi.AddRange(asc);
            var dcd = new List<byte> { 0x04, (byte)(13 + dsi.Count), 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }; dcd.AddRange(dsi);
            var es = new List<byte> { 0x03, (byte)(3 + dcd.Count + 3), 0, 0, 0 }; es.AddRange(dcd); es.AddRange(new byte[] { 0x06, 0x01, 0x02 });
            return es.ToArray();
        }

        private static readonly int[] Rates = { 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350, 0, 0 };
        private readonly List<byte> buffer = new List<byte>();
        private bool configured; private int versionA, numSubFrames, otherDataBits;

        private sealed class Bits
        {
            public Bits(byte[] b) { bytes = b; }
            public int Position { get; private set; }
            public int Get(int n)
            {
                int v = 0;
                for(int i = 0; i < n; i++, Position++) {
                    if(Position / 8 >= bytes.Length) throw new IndexOutOfRangeException();
                    v = (v << 1) | ((bytes[Position / 8] >> (7 - Position % 8)) & 1);
                }
                return v;
            }
            public void Skip(int n) { Position += n; if((Position + 7) / 8 > bytes.Length) throw new IndexOutOfRangeException(); }
            public void Seek(int p) { Position = p; }
            public byte[] Slice(int start, int bits)
            {
                var o = new byte[(bits + 7) / 8]; int save = Position; Position = start;
                for(int i = 0; i < bits; i++) if(Get(1) == 1) o[i / 8] |= (byte)(0x80 >> (i % 8));
                Position = save; return o;
            }
            private readonly byte[] bytes;
        }
    }
}
