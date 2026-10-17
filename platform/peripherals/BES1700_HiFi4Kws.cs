// Keyword spotter used by the HiFi4 stand-in in place of the DSP's "wakeup" KWS library
// (pil_algo_wakeup_dll_nand.dll, Xtensa code that cannot run here). Template matching:
// 13 MFCC (25 ms / 10 ms, 26 mel bands, c0 dropped, cepstral mean adapted on speech frames) and a
// streaming open-begin DTW against every enrolment recording of the wake word. Templates are
// 16 kHz mono WAVs in one folder per keyword (scripts/make-kws-templates.sh creates them with the
// macOS Chinese voices; recordings of the user's own voice can be added to the same folder).
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public sealed class HiFi4KeywordSpotter
    {
        public HiFi4KeywordSpotter(IEnumerable<string> templateFiles, double threshold)
        {
            this.threshold = threshold;
            var means = new List<double[]>();
            foreach(var path in templateFiles) {
                var samples = ReadWav(path);
                if(samples == null || samples.Length < Win) continue;
                var feats = new List<double[]>(); var energy = new List<double>();
                for(int i = 0; i + Win <= samples.Length; i += Hop) { Frame(samples, i, out var c, out var e); feats.Add(c); energy.Add(e); }
                // keep the speech part (energy within 8 log units of the loudest frame)
                double max = double.MinValue; foreach(var e in energy) max = Math.Max(max, e);
                int a = energy.FindIndex(e => e > max - 8), b = energy.FindLastIndex(e => e > max - 8);
                if(a < 0 || b - a < 20) continue;
                var mu = new double[Ncep];
                for(int i = a; i <= b; i++) for(int q = 0; q < Ncep; q++) mu[q] += feats[i][q] / (b - a + 1);
                var t = new double[b - a + 1][];
                for(int i = a; i <= b; i++) { t[i - a] = new double[Ncep - 1]; for(int q = 1; q < Ncep; q++) t[i - a][q - 1] = feats[i][q] - mu[q]; }
                templates.Add(t); means.Add(mu);
            }
            minTemplate = int.MaxValue; foreach(var t in templates) minTemplate = Math.Min(minTemplate, t.Length);
            if(templates.Count == 0) minTemplate = 0;
            mean0 = new double[Ncep];
            foreach(var m in means) for(int q = 0; q < Ncep; q++) mean0[q] += m[q] / means.Count;
            Reset();
        }

        public int TemplateCount => templates.Count;
        public double LastBest { get; private set; } = double.PositiveInfinity;

        public void Reset()
        {
            mu = (double[])mean0.Clone(); floor = double.NaN; pending.Clear(); samplesSeen = 0; refractory = 0; speechFlags.Clear();
            dist = new double[templates.Count][]; len = new double[templates.Count][];
            for(int k = 0; k < templates.Count; k++) { dist[k] = Fill(templates[k].Length, double.PositiveInfinity); len[k] = new double[templates[k].Length]; }
        }

        // Feeds s16 mono samples; returns the sample index (from Reset) where a keyword ended, or -1.
        public long Push(short[] samples, int count)
        {
            long hit = -1;
            for(int i = 0; i < count; i++) {
                pending.Add(samples[i] / 32768.0); samplesSeen++;
                if(pending.Count < Win) continue;
                Frame(pending.ToArray(), 0, out var c, out var e);
                pending.RemoveRange(0, Hop);
                double score = Step(c, e);
                speechFlags.Enqueue(e >= -14 && e > floor + 3); if(speechFlags.Count > 200) speechFlags.Dequeue();
                if(refractory > 0) { refractory--; continue; }
                // a hit needs real speech under the matched span (no matches on background noise)
                if(score < threshold && SpeechFraction(minTemplate) >= 0.5) { hit = samplesSeen; refractory = 100; ResetPaths(); }
            }
            return hit;
        }

        private double SpeechFraction(int frames)
        {
            int n = 0, k = 0, skip = Math.Max(0, speechFlags.Count - frames);
            foreach(var f in speechFlags) { if(k++ < skip) continue; if(f) n++; }
            return frames == 0 ? 0 : n / (double)Math.Min(frames, speechFlags.Count);
        }

        private double Step(double[] c, double e)
        {
            // digital silence (no input yet, or a file that ended) is no signal: nothing to adapt to
            if(e >= -14) {
                if(double.IsNaN(floor)) floor = e;
                else floor = e > floor ? floor + 0.005 * (e - floor) : 0.9 * floor + 0.1 * e;   // rises over ~2 s, falls fast
                if(e > floor + 3) for(int q = 0; q < Ncep; q++) mu[q] = 0.99 * mu[q] + 0.01 * c[q];
            }
            var x = new double[Ncep - 1];
            for(int q = 1; q < Ncep; q++) x[q - 1] = c[q] - mu[q];
            double best = double.PositiveInfinity;
            for(int k = 0; k < templates.Count; k++) {
                var t = templates[k]; var D = dist[k]; var L = len[k];
                var nD = new double[t.Length]; var nL = new double[t.Length];
                for(int j = 0; j < t.Length; j++) {
                    double d = 0; for(int q = 0; q < x.Length; q++) { double v = t[j][q] - x[q]; d += v * v; }
                    d = Math.Sqrt(d);
                    if(j == 0) { nD[0] = d; nL[0] = 1; continue; }
                    double bd = double.PositiveInfinity, bl = 0, bs = double.PositiveInfinity;
                    Consider(D[j], L[j], d, ref bd, ref bl, ref bs);
                    Consider(D[j - 1], L[j - 1], d, ref bd, ref bl, ref bs);
                    Consider(nD[j - 1], nL[j - 1], d, ref bd, ref bl, ref bs);
                    nD[j] = bd + d; nL[j] = bl + 1;
                }
                dist[k] = nD; len[k] = nL;
                int last = t.Length - 1;
                if(nL[last] >= 0.5 * t.Length) best = Math.Min(best, nD[last] / nL[last]);
            }
            LastBest = best;
            return best;
        }

        private static void Consider(double D, double L, double d, ref double bd, ref double bl, ref double bs)
        {
            if(L <= 0 || double.IsInfinity(D)) return;
            double s = (D + d) / (L + 1);
            if(s < bs) { bs = s; bd = D; bl = L; }
        }

        private void ResetPaths() { for(int k = 0; k < templates.Count; k++) { dist[k] = Fill(templates[k].Length, double.PositiveInfinity); len[k] = new double[templates[k].Length]; } }
        private static double[] Fill(int n, double v) { var a = new double[n]; for(int i = 0; i < n; i++) a[i] = v; return a; }

        // ---- MFCC
        private static void Frame(double[] x, int at, out double[] cep, out double energy)
        {
            var re = new double[Nfft]; var im = new double[Nfft];
            double prev = at > 0 ? x[at - 1] : x[at];
            for(int i = 0; i < Win; i++) {
                double v = x[at + i], p = i == 0 ? x[at] : x[at + i - 1];
                re[i] = (i == 0 ? v : v - 0.97 * p) * Hamming[i];
            }
            Fft(re, im);
            var power = new double[Nfft / 2 + 1]; energy = 1e-8;
            for(int k = 0; k <= Nfft / 2; k++) { power[k] = re[k] * re[k] + im[k] * im[k]; energy += power[k]; }
            energy = Math.Log(energy);
            var logMel = new double[Nmel];
            for(int m = 0; m < Nmel; m++) { double s = 1e-8; for(int k = MelLo[m]; k < MelHi[m]; k++) s += Mel[m][k] * power[k]; logMel[m] = Math.Log(s); }
            cep = new double[Ncep];
            for(int q = 0; q < Ncep; q++) { double s = 0; for(int m = 0; m < Nmel; m++) s += Dct[q, m] * logMel[m]; cep[q] = s; }
        }

        private static void Fft(double[] re, double[] im)
        {
            int n = re.Length;
            for(int i = 1, j = 0; i < n; i++) {
                int bit = n >> 1; for(; (j & bit) != 0; bit >>= 1) j ^= bit; j ^= bit;
                if(i < j) { var t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; }
            }
            for(int size = 2; size <= n; size <<= 1) {
                double ang = -2 * Math.PI / size;
                for(int i = 0; i < n; i += size)
                    for(int k = 0; k < size / 2; k++) {
                        double wr = Math.Cos(ang * k), wi = Math.Sin(ang * k);
                        int a = i + k, b = a + size / 2;
                        double tr = re[b] * wr - im[b] * wi, ti = re[b] * wi + im[b] * wr;
                        re[b] = re[a] - tr; im[b] = im[a] - ti; re[a] += tr; im[a] += ti;
                    }
            }
        }

        public static short[] ReadWav16(string path)
        {
            var d = ReadWav(path); if(d == null) return null;
            var s = new short[d.Length]; for(int i = 0; i < d.Length; i++) s[i] = (short)Math.Max(-32768, Math.Min(32767, d[i] * 32768));
            return s;
        }

        private static double[] ReadWav(string path)
        {
            try {
                var b = File.ReadAllBytes(path);
                int o = 12, data = -1, len = 0;
                if(b.Length < 44 || Encoding.ASCII.GetString(b, 0, 4) != "RIFF") { data = 0; len = b.Length; }
                while(data < 0 && o + 8 <= b.Length) {
                    string id = Encoding.ASCII.GetString(b, o, 4); int n = BitConverter.ToInt32(b, o + 4);
                    if(id == "data") { data = o + 8; len = Math.Min(n, b.Length - data); }
                    o += 8 + n + (n & 1);
                }
                if(data < 0) return null;
                var x = new double[len / 2];
                for(int i = 0; i < x.Length; i++) x[i] = BitConverter.ToInt16(b, data + 2 * i) / 32768.0;
                return x;
            } catch(Exception) { return null; }
        }

        private const int Sr = 16000, Win = 400, Hop = 160, Nfft = 512, Nmel = 26, Ncep = 13;
        private static readonly double[] Hamming = MakeHamming();
        private static readonly double[][] Mel; private static readonly int[] MelLo, MelHi;
        private static readonly double[,] Dct = MakeDct();
        static HiFi4KeywordSpotter()
        {
            Func<double, double> mel = f => 2595 * Math.Log10(1 + f / 700), imel = m => 700 * (Math.Pow(10, m / 2595) - 1);
            var bins = new int[Nmel + 2];
            for(int i = 0; i < Nmel + 2; i++) bins[i] = (int)Math.Floor((Nfft + 1) * imel(mel(60) + (mel(7600) - mel(60)) * i / (Nmel + 1)) / Sr);
            Mel = new double[Nmel][]; MelLo = new int[Nmel]; MelHi = new int[Nmel];
            for(int m = 0; m < Nmel; m++) {
                Mel[m] = new double[Nfft / 2 + 1];
                int a = bins[m], b = bins[m + 1], c = bins[m + 2];
                for(int k = a; k < b; k++) Mel[m][k] = (k - a) / (double)Math.Max(1, b - a);
                for(int k = b; k < c; k++) Mel[m][k] = (c - k) / (double)Math.Max(1, c - b);
                MelLo[m] = a; MelHi[m] = c;
            }
        }
        private static double[] MakeHamming() { var h = new double[Win]; for(int i = 0; i < Win; i++) h[i] = 0.54 - 0.46 * Math.Cos(2 * Math.PI * i / (Win - 1)); return h; }
        private static double[,] MakeDct() { var d = new double[Ncep, Nmel]; for(int q = 0; q < Ncep; q++) for(int m = 0; m < Nmel; m++) d[q, m] = Math.Cos(Math.PI * q * (m + 0.5) / Nmel); return d; }

        private readonly List<double[][]> templates = new List<double[][]>();
        private readonly double[] mean0;
        private readonly double threshold;
        private readonly List<double> pending = new List<double>();
        private double[] mu; private double floor;
        private double[][] dist, len;
        private long samplesSeen; private int refractory, minTemplate;
        private readonly Queue<bool> speechFlags = new Queue<bool>();
    }
}
