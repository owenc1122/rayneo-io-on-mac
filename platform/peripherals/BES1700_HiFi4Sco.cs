// Bluetooth voice codecs for the HiFi4 stand-in's SCO streams (smf 0x28 scodn: decode -> speaker, 0x29 scoup:
// microphone -> encode). The AP's ScoService moves one frame per 7.5 ms between the controller and the shm
// FIFOs "scodn"/"scoup" (see .local/research/audio/bt-audio.md):
//   mSBC (HFP wide band): 57-byte frames (syncword 0xAD, two reserved zero bytes, CRC), 16 kHz mono,
//         8 subbands, 15 blocks, loudness allocation, bitpool 26 = 120 samples. A2DP SBC, Bluetooth HFP 1.6+.
//   CVSD (HFP narrow band): 60-byte bitstream at 64 kbit/s (LSB first) = 60 samples at 8 kHz, Bluetooth Core
//         Vol 2 Part B 9.2 (h = 1-1/32, beta = 1-1/1024, J = K = 4, step 10..1280); 0x55 bytes are silence.
using System;

namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public sealed class MsbcCodec
    {
        public const int FrameBytes = 57, Samples = 120;
        const int Subbands = 8, Blocks = 15, Bitpool = 26;
        static readonly int[] Offset16k = { -2, 0, 0, 0, 0, 0, 0, 1 };

        // ---- encoder
        public byte[] Encode(short[] pcm)
        {
            var sb = new double[Blocks, Subbands];
            for(int blk = 0; blk < Blocks; blk++) {
                for(int i = 79; i >= 8; i--) ax[i] = ax[i - 8];
                for(int i = 7; i >= 0; i--) ax[i] = pcm[blk * 8 + (7 - i)];
                var y = new double[16];
                for(int i = 0; i < 16; i++) for(int j = 0; j < 5; j++) y[i] += C[i + 16 * j] * ax[i + 16 * j];
                for(int k = 0; k < Subbands; k++) { double s = 0; for(int i = 0; i < 16; i++) s += M[k, i] * y[i]; sb[blk, k] = s; }
            }
            var sf = new int[Subbands];
            for(int k = 0; k < Subbands; k++) {
                double max = 0; for(int b = 0; b < Blocks; b++) max = Math.Max(max, Math.Abs(sb[b, k]));
                int f = 0; while(f < 15 && max >= (1 << (f + 1))) f++;
                sf[k] = f;
            }
            var bits = Allocate(sf);
            var w = new BitWriter(FrameBytes);
            w.Put(0xAD, 8); w.Put(0, 8); w.Put(0, 8); w.Put(0, 8);   // CRC filled in below
            for(int k = 0; k < Subbands; k++) w.Put(sf[k], 4);
            for(int b = 0; b < Blocks; b++)
                for(int k = 0; k < Subbands; k++) {
                    if(bits[k] == 0) continue;
                    int levels = (1 << bits[k]) - 1;
                    double scale = 1 << (sf[k] + 1);
                    int q = (int)Math.Floor((sb[b, k] / scale + 1) * levels / 2);
                    w.Put(Math.Max(0, Math.Min(levels - 1, q)), bits[k]);
                }
            var frame = w.Bytes;
            frame[3] = Crc(frame);
            return frame;
        }

        // ---- decoder (a bad or missing frame repeats the last output, faded: packet loss concealment)
        public short[] Decode(byte[] frame, bool bad = false)
        {
            if(bad || frame == null || frame.Length < FrameBytes || frame[0] != 0xAD) return Conceal();
            var r = new BitReader(frame); r.Skip(32);
            var sf = new int[Subbands];
            for(int k = 0; k < Subbands; k++) sf[k] = r.Get(4);
            var bits = Allocate(sf);
            var outp = new short[Samples];
            for(int b = 0; b < Blocks; b++) {
                var s = new double[Subbands];
                for(int k = 0; k < Subbands; k++) {
                    if(bits[k] == 0) { s[k] = 0; continue; }
                    int levels = (1 << bits[k]) - 1, q = r.Get(bits[k]);
                    s[k] = (1 << (sf[k] + 1)) * ((2.0 * q + 1) / levels - 1);
                }
                for(int i = 159; i >= 16; i--) v[i] = v[i - 16];
                for(int k = 0; k < 16; k++) { double a = 0; for(int i = 0; i < Subbands; i++) a += N[k, i] * s[i]; v[k] = a; }
                var u = new double[80];
                for(int i = 0; i < 5; i++) for(int j = 0; j < 8; j++) { u[i * 16 + j] = v[i * 32 + j]; u[i * 16 + 8 + j] = v[i * 32 + 24 + j]; }
                for(int j = 0; j < 8; j++) {
                    double x = 0; for(int i = 0; i < 10; i++) x += D[j + 8 * i] * u[j + 8 * i];
                    outp[b * 8 + j] = (short)Math.Max(-32768, Math.Min(32767, Math.Round(x)));
                }
            }
            last = outp; fade = 1;
            return outp;
        }

        private short[] Conceal()
        {
            fade *= 0.5;
            var o = new short[Samples];
            if(last != null) for(int i = 0; i < Samples; i++) o[i] = (short)(last[i] * fade);
            return o;
        }

        static int[] Allocate(int[] sf)
        {
            var need = new int[Subbands]; int maxNeed = 0;
            for(int k = 0; k < Subbands; k++) {
                if(sf[k] == 0) need[k] = -5;
                else { int loud = sf[k] - Offset16k[k]; need[k] = loud > 0 ? loud / 2 : loud; }
                maxNeed = Math.Max(maxNeed, need[k]);
            }
            int bitcount = 0, slicecount = 0, bitslice = maxNeed + 1;
            do {
                bitslice--; bitcount += slicecount; slicecount = 0;
                for(int k = 0; k < Subbands; k++) {
                    if(need[k] > bitslice + 1 && need[k] < bitslice + 16) slicecount++;
                    else if(need[k] == bitslice + 1) slicecount += 2;
                }
            } while(bitcount + slicecount < Bitpool);
            if(bitcount + slicecount == Bitpool) { bitcount += slicecount; bitslice--; }
            var bits = new int[Subbands];
            for(int k = 0; k < Subbands; k++) bits[k] = need[k] < bitslice + 2 ? 0 : Math.Min(need[k] - bitslice, 16);
            for(int k = 0; bitcount < Bitpool && k < Subbands; k++) {
                if(bits[k] >= 2 && bits[k] < 16) { bits[k]++; bitcount++; }
                else if(need[k] == bitslice + 1 && Bitpool > bitcount + 1) { bits[k] = 2; bitcount += 2; }
            }
            for(int k = 0; bitcount < Bitpool && k < Subbands; k++) if(bits[k] < 16) { bits[k]++; bitcount++; }
            return bits;
        }

        // CRC-8 (x^8+x^4+x^3+x^2+1, initial 0x0F) over header bytes 1-2 and the scale factors.
        static byte Crc(byte[] f)
        {
            int crc = 0x0F;
            int[] covered = { f[1], f[2], f[4], f[5], f[6], f[7] };
            foreach(var b in covered)
                for(int i = 7; i >= 0; i--) {
                    int bit = ((b >> i) & 1) ^ ((crc >> 7) & 1);
                    crc = ((crc << 1) & 0xff) ^ (bit != 0 ? 0x1D : 0);
                }
            return (byte)crc;
        }

        // Prototype window of the 8-subband filter bank (A2DP spec), symmetric: built from its first 41 taps.
        static readonly double[] ProtoHalf = {
            0.00000000E+00, 1.56575398E-04, 3.43256425E-04, 5.54620202E-04, 8.23919506E-04, 1.13992507E-03, 1.47640169E-03, 1.78371725E-03,
            2.01182542E-03, 2.10371989E-03, 1.99454554E-03, 1.61656283E-03, 9.02154502E-04, -1.78805361E-04, -1.64973098E-03, -3.49717454E-03,
            -5.65949473E-03, -8.02941163E-03, -1.04584443E-02, -1.27472335E-02, -1.46525263E-02, -1.59045603E-02, -1.62208471E-02, -1.53184106E-02,
            -1.29371806E-02, -8.85757540E-03, -2.92408442E-03, 4.91578024E-03, 1.46404076E-02, 2.61098752E-02, 3.90751381E-02, 5.31873032E-02,
            6.79989431E-02, 8.29847578E-02, 9.75753918E-02, 1.11196689E-01, 1.23264548E-01, 1.33264415E-01, 1.40753505E-01, 1.45389847E-01,
            1.46955068E-01 };
        // analysis window C[i] = p[i] * (-1)^floor(i/16); synthesis D = 8 * C (scaled for unity gain)
        static readonly double[] C = Window(1), D = Window(SynthesisGain);
        const double SynthesisGain = -8;
        static double[] Window(double g)
        {
            var w = new double[80];
            for(int i = 0; i < 80; i++) { double p = ProtoHalf[i <= 40 ? i : 80 - i]; w[i] = g * p * (((i / 16) & 1) == 0 ? 1 : -1); }
            return w;
        }
        static readonly double[,] M = Matrix((k, i) => Math.Cos((k + 0.5) * (i - 4) * Math.PI / 8), 8, 16);
        static readonly double[,] N = Matrix((k, i) => Math.Cos((i + 0.5) * (k + 4) * Math.PI / 8), 16, 8);
        static double[,] Matrix(Func<int, int, double> f, int rows, int cols) { var m = new double[rows, cols]; for(int a = 0; a < rows; a++) for(int b = 0; b < cols; b++) m[a, b] = f(a, b); return m; }

        readonly double[] ax = new double[80], v = new double[160];
        short[] last; double fade;
    }

    public sealed class CvsdCodec
    {
        public const int FrameBytes = 60, Samples = 60;   // 7.5 ms: 480 bits at 64 kbit/s, 60 samples at 8 kHz

        public byte[] Encode(short[] pcm)
        {
            var o = new byte[FrameBytes];
            for(int n = 0; n < Samples; n++) {
                double from = prevIn, to = pcm[n];
                for(int u = 0; u < 8; u++) {
                    double x = from + (to - from) * (u + 1) / 8;   // 64 kHz by linear interpolation
                    int bit = x >= enc.Estimate ? 1 : 0;
                    enc.Step(bit);
                    if(bit != 0) o[(n * 8 + u) / 8] |= (byte)(1 << ((n * 8 + u) % 8));
                }
                prevIn = pcm[n];
            }
            return o;
        }

        public short[] Decode(byte[] frame, bool bad = false)
        {
            var o = new short[Samples];
            if(bad || frame == null || frame.Length < FrameBytes) return o;
            for(int n = 0; n < Samples; n++) {
                double acc = 0;
                for(int u = 0; u < 8; u++) { int bit = (frame[(n * 8 + u) / 8] >> ((n * 8 + u) % 8)) & 1; dec.Step(bit); acc += dec.Estimate; }
                // 8:1 decimation: average of the 64 kHz estimate
                lp = acc / 8;
                o[n] = (short)Math.Max(-32768, Math.Min(32767, Math.Round(lp)));
            }
            return o;
        }

        private sealed class State
        {
            public double Estimate, Delta = DeltaMin; int history;
            public void Step(int bit)
            {
                history = ((history << 1) | bit) & 0xf;
                bool run = history == 0 || history == 0xf;   // J = K = 4 equal bits
                Delta = run ? Math.Min(Delta + DeltaMin, DeltaMax) : Math.Max(Beta * Delta, DeltaMin);
                double y = Estimate + (bit != 0 ? Delta : -Delta);
                y = Math.Max(-32768, Math.Min(32767, y));
                Estimate = H * y;
            }
        }
        const double H = 1 - 1.0 / 32, Beta = 1 - 1.0 / 1024, DeltaMin = 10, DeltaMax = 1280;
        readonly State enc = new State(), dec = new State();
        double prevIn, lp;
    }

    sealed class BitWriter
    {
        public BitWriter(int bytes) { Bytes = new byte[bytes]; }
        public byte[] Bytes { get; }
        public void Put(int value, int bits) { for(int i = bits - 1; i >= 0; i--) { if(((value >> i) & 1) != 0 && pos / 8 < Bytes.Length) Bytes[pos / 8] |= (byte)(0x80 >> (pos % 8)); pos++; } }
        int pos;
    }

    sealed class BitReader
    {
        public BitReader(byte[] b) { bytes = b; }
        public void Skip(int bits) { pos += bits; }
        public int Get(int bits) { int v = 0; for(int i = 0; i < bits; i++) { v = (v << 1) | (pos / 8 < bytes.Length ? (bytes[pos / 8] >> (7 - pos % 8)) & 1 : 0); pos++; } return v; }
        readonly byte[] bytes; int pos;
    }
}
