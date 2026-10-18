// Noise suppression used by the HiFi4 stand-in in place of the DSP's "up" library (Elevoc NS/beamforming,
// pil_algo_up_demo_nand.dll, Xtensa code that cannot run here). smf.json puts "up" between the 5-mic
// capture and every record stream (arserver mic0/1/2 -> arec*, sserver 0x61), so the AP always receives
// noise-suppressed speech; the wakeup stream (0x1b) takes the BTH VAD history and is not processed.
// Algorithm: STFT (512-point, 50 % overlap, sqrt-Hann analysis/synthesis), MCRA noise tracking (Cohen &
// Berdugo 2002: minimum-tracked smoothed power, speech-presence-controlled recursive averaging), and a
// decision-directed Wiener gain (Ephraim & Malah a-priori SNR, alpha 0.98) with a -18 dB floor.
// Streaming with a fixed delay of one frame (512 samples, 32 ms at 16 kHz), like a frame-based DSP library.
using System;

namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public sealed class HiFi4NoiseSuppressor
    {
        public HiFi4NoiseSuppressor() { Reset(); }

        public void Reset()
        {
            Array.Clear(inBuf, 0, N); Array.Clear(outBuf, 0, N); fill = N - H;
            Array.Clear(noise, 0, Bins); Array.Clear(smooth, 0, Bins); Array.Clear(prevClean, 0, Bins);
            Array.Clear(presence, 0, Bins);
            for(int k = 0; k < Bins; k++) { minPow[k] = double.MaxValue; tmpPow[k] = double.MaxValue; }
            frames = 0;
        }

        // Processes count samples in place (output delayed by Delay samples).
        public void Process(short[] x, int count)
        {
            for(int i = 0; i < count; i++) {
                inBuf[fill] = x[i] / 32768.0;
                x[i] = Clip(outBuf[fill - (N - H)] * 32768.0);
                if(++fill == N) { Frame(); fill = N - H; }
            }
        }

        public const int Delay = N;

        private void Frame()
        {
            var re = new double[N]; var im = new double[N];
            for(int i = 0; i < N; i++) re[i] = inBuf[i] * Window[i];
            Fft(re, im, false);
            frames++;
            for(int k = 0; k < Bins; k++) {
                double p = re[k] * re[k] + im[k] * im[k];
                // MCRA: smoothed power, its running minimum (reset every L frames), speech presence probability
                smooth[k] = frames == 1 ? p : 0.8 * smooth[k] + 0.2 * p;
                if(frames == 1) { minPow[k] = tmpPow[k] = p; noise[k] = p; }
                else { minPow[k] = Math.Min(minPow[k], smooth[k]); tmpPow[k] = Math.Min(tmpPow[k], smooth[k]); }
                bool speech = smooth[k] > 5 * minPow[k] + 1e-12;
                presence[k] = 0.2 * presence[k] + 0.8 * (speech ? 1 : 0);
                double ad = 0.95 + 0.05 * presence[k];
                noise[k] = ad * noise[k] + (1 - ad) * p;
                // a-priori SNR (decision directed) and Wiener gain
                double lambda = noise[k] + 1e-12;
                double post = p / lambda;
                double prio = 0.98 * prevClean[k] / lambda + 0.02 * Math.Max(post - 1, 0);
                double g = Math.Max(prio / (1 + prio), Floor);
                prevClean[k] = g * g * p;
                re[k] *= g; im[k] *= g;
                if(k > 0 && k < N / 2) { re[N - k] = re[k]; im[N - k] = -im[k]; }
            }
            if(frames % L == 0) for(int k = 0; k < Bins; k++) { minPow[k] = Math.Min(tmpPow[k], smooth[k]); tmpPow[k] = smooth[k]; }
            Fft(re, im, true);
            // overlap-add: shift the output by one hop, add the new synthesis-windowed frame
            Array.Copy(outBuf, H, outBuf, 0, N - H); Array.Clear(outBuf, N - H, H);
            for(int i = 0; i < N; i++) outBuf[i] += re[i] / N * Window[i];
            Array.Copy(inBuf, H, inBuf, 0, N - H);
        }

        private static short Clip(double v) { return (short)Math.Max(-32768, Math.Min(32767, Math.Round(v))); }

        private static void Fft(double[] re, double[] im, bool inverse)
        {
            int n = re.Length;
            for(int i = 1, j = 0; i < n; i++) {
                int bit = n >> 1; for(; (j & bit) != 0; bit >>= 1) j ^= bit; j ^= bit;
                if(i < j) { var t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; }
            }
            for(int size = 2; size <= n; size <<= 1) {
                double ang = (inverse ? 2 : -2) * Math.PI / size;
                for(int i = 0; i < n; i += size)
                    for(int k = 0; k < size / 2; k++) {
                        double wr = Math.Cos(ang * k), wi = Math.Sin(ang * k);
                        int a = i + k, b = a + size / 2;
                        double tr = re[b] * wr - im[b] * wi, ti = re[b] * wi + im[b] * wr;
                        re[b] = re[a] - tr; im[b] = im[a] - ti; re[a] += tr; im[a] += ti;
                    }
            }
        }

        // Offline use (tests): processes a 16 kHz mono WAV into another, delay removed.
        public static void ProcessFile(string input, string output)
        {
            var b = System.IO.File.ReadAllBytes(input);
            int o = 12, data = 44, len = b.Length - 44;
            while(o + 8 <= b.Length) {
                string id = System.Text.Encoding.ASCII.GetString(b, o, 4); int n = BitConverter.ToInt32(b, o + 4);
                if(id == "data") { data = o + 8; len = Math.Min(n, b.Length - data); break; }
                o += 8 + n + (n & 1);
            }
            var x = new short[len / 2];
            for(int i = 0; i < x.Length; i++) x[i] = BitConverter.ToInt16(b, data + 2 * i);
            var y = new short[x.Length + Delay];
            Array.Copy(x, y, x.Length);
            new HiFi4NoiseSuppressor().Process(y, y.Length);
            var outData = new byte[x.Length * 2];
            for(int i = 0; i < x.Length; i++) { outData[2 * i] = (byte)y[i + Delay]; outData[2 * i + 1] = (byte)(y[i + Delay] >> 8); }
            using(var f = new System.IO.FileStream(output, System.IO.FileMode.Create)) {
                var w = new System.IO.BinaryWriter(f);
                w.Write(System.Text.Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + outData.Length); w.Write(System.Text.Encoding.ASCII.GetBytes("WAVEfmt "));
                w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(16000); w.Write(32000); w.Write((short)2); w.Write((short)16);
                w.Write(System.Text.Encoding.ASCII.GetBytes("data")); w.Write(outData.Length); w.Write(outData);
            }
        }

        private const int N = 512, H = 256, Bins = N / 2 + 1, L = 40;   // L frames (0.64 s) per minimum window, ~1.3 s span
        private const double Floor = 0.125;
        private static readonly double[] Window = MakeWindow();
        private static double[] MakeWindow() { var w = new double[N]; for(int i = 0; i < N; i++) w[i] = Math.Sqrt(0.5 - 0.5 * Math.Cos(2 * Math.PI * i / N)); return w; }
        private readonly double[] inBuf = new double[N], outBuf = new double[N];
        private readonly double[] noise = new double[Bins], smooth = new double[Bins], minPow = new double[Bins], tmpPow = new double[Bins], prevClean = new double[Bins], presence = new double[Bins];
        private int fill;
        private long frames;
    }
}
