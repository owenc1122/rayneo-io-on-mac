// 「小雷小雷」 keyword classifier for the HiFi4 stand-in's wakeup stage (in place of the DSP's
// pil_algo_wakeup_dll_nand.dll, Xtensa code that cannot run here). A small neural keyword spotter of the
// kind DSP wake-word libraries use: the MFCC front end of HiFi4KeywordSpotter (25 ms / 10 ms, 13 cepstra),
// a 1.3 s window normalised per window and pooled 2:1 in time, one ReLU hidden layer and a sigmoid output.
// Weights: platform/kws/xiaolei.model, trained by scripts/train-kws.py on macOS voices with added noise.
// Streaming: scored every 20 ms; a keyword is reported when the output stays above the threshold for two
// scores in a row over a window with speech (at least 10 % of frames 0.7 above the window's quiet level).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;

namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public sealed class HiFi4KeywordNet
    {
        public HiFi4KeywordNet(string modelPath, double threshold = 0.97)
        {
            Threshold = threshold;
            var lines = File.ReadAllLines(modelPath).Where(l => !l.StartsWith("#") && l.Trim().Length > 0).ToArray();
            var head = lines[0].Split(' ').Select(int.Parse).ToArray();
            window = head[0]; pool = head[1]; ncep = head[2]; hidden = head[3];
            Func<int, double[]> row = i => lines[i].Split(' ').Select(v => double.Parse(v, CultureInfo.InvariantCulture)).ToArray();
            mu = row(1); sd = row(2); w1 = row(3); b1 = row(4); w2 = row(5); b2 = row(6)[0];
            inputs = window / pool * ncep;
            if(mu.Length != inputs || w1.Length != inputs * hidden || w2.Length != hidden) throw new InvalidDataException("keyword model dimensions do not match");
            Reset();
        }

        public double Threshold { get; set; }
        public double LastScore { get; private set; }
        public double MaxScore { get; private set; }

        public void Reset()
        {
            pending.Clear(); frames.Clear(); energy.Clear(); samplesSeen = 0; frameCount = 0; above = 0; refractory = 0;
            LastScore = 0; MaxScore = 0;
        }

        // Feeds s16 mono samples; returns the sample index (from Reset) where the keyword ended, or -1.
        public long Push(short[] samples, int count)
        {
            long hit = -1;
            for(int i = 0; i < count; i++) {
                pending.Add(samples[i] / 32768.0); samplesSeen++;
                if(pending.Count < Win) continue;
                HiFi4KeywordSpotter.Frame(pending.ToArray(), 0, out var c, out var e);
                pending.RemoveRange(0, Hop);
                frames.Enqueue(c); if(frames.Count > window) frames.Dequeue();
                energy.Enqueue(e); if(energy.Count > window) energy.Dequeue();
                if(++frameCount % 2 != 0 || frames.Count < window) continue;
                if(refractory > 0) { refractory -= 2; continue; }
                LastScore = Score(); MaxScore = Math.Max(MaxScore, LastScore);
                above = LastScore >= Threshold && Talk() >= TalkShare ? above + 1 : 0;
                if(above >= 2) { hit = samplesSeen; above = 0; refractory = 100; }
            }
            return hit;
        }

        // Share of the window with speech: frames 0.7 (natural log energy) above the window's 10th percentile,
        // none in digital silence.
        private double Talk()
        {
            var e = energy.ToArray(); var sorted = (double[])e.Clone(); Array.Sort(sorted);
            if(sorted[sorted.Length - 1] < -14) return 0;
            double p10 = Percentile(sorted, 10);
            return e.Count(v => v > p10 + Gate) / (double)e.Length;
        }
        // numpy.percentile (linear interpolation)
        private static double Percentile(double[] sorted, double q)
        {
            double pos = (sorted.Length - 1) * q / 100; int lo = (int)Math.Floor(pos), hi = Math.Min(lo + 1, sorted.Length - 1);
            return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
        }

        private double Score()
        {
            var w = frames.ToArray();
            var x = new double[inputs];
            for(int q = 0; q < ncep; q++) {
                double m = 0, v = 0;
                for(int t = 0; t < window; t++) m += w[t][q];
                m /= window;
                for(int t = 0; t < window; t++) v += (w[t][q] - m) * (w[t][q] - m);
                double s = Math.Sqrt(v / window) + 1e-3;
                for(int t = 0; t < window; t++) x[(t / pool) * ncep + q] += (w[t][q] - m) / s / pool;
            }
            double z = b2;
            for(int h = 0; h < hidden; h++) {
                double a = b1[h]; int o = h * inputs;
                for(int k = 0; k < inputs; k++) a += w1[o + k] * (x[k] - mu[k]) / sd[k];
                if(a > 0) z += w2[h] * a;
            }
            return 1 / (1 + Math.Exp(-Math.Max(-30, Math.Min(30, z))));
        }

        // Offline check on a WAV: hit times (s) and the highest score.
        public string Scan(string wav)
        {
            var x = HiFi4KeywordSpotter.ReadWav16(wav); if(x == null) return "cannot read " + wav;
            Reset(); var hits = new List<string>(); var chunk = new short[160];
            for(int i = 0; i + 160 <= x.Length; i += 160) {
                Array.Copy(x, i, chunk, 0, 160);
                long h = Push(chunk, 160); if(h >= 0) hits.Add((h / 16000.0).ToString("0.00", CultureInfo.InvariantCulture));
            }
            var r = string.Format(CultureInfo.InvariantCulture, "max {0:0.000} hits [{1}]", MaxScore, string.Join(",", hits));
            Reset();
            return r;
        }

        private const int Win = 400, Hop = 160;
        private readonly int window, pool, ncep, hidden, inputs;
        private readonly double[] mu, sd, w1, b1, w2;
        private readonly double b2;
        private readonly List<double> pending = new List<double>();
        private readonly Queue<double[]> frames = new Queue<double[]>();
        private readonly Queue<double> energy = new Queue<double>();
        private const double Gate = 0.7, TalkShare = 0.1;
        private long samplesSeen; private int frameCount, above, refractory;
    }
}
