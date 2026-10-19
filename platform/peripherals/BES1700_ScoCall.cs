// Stand-in for the far-end (phone) voice on an HFP call's downlink SCO link. The real glasses would
// receive 60-byte eSCO frames off the air every 7.5 ms; here BES1700_ClockControl's ch3 SCO path pulls
// one frame per eSCO slot from this generator (it is wired as sysCmu.ScoDownlink in the constructor).
// It synthesises an obviously non-silent "ring-back" tone (the 440 Hz / 480 Hz North-American
// call-progress pair, 2 s on / 1 s off) at 16 kHz, encodes it with the same MsbcCodec the DSP decodes,
// and wraps it as the on-wire mSBC eSCO packet: 0x01, an H2 sequence byte (08/38/C8/F8), the 57-byte
// mSBC frame, one padding byte = 60 bytes. CvsdCodec covers the narrow-band (CVSD) case. Swap NextPcm
// for real call audio (e.g. frames pumped from the phone peer) to carry actual voice.
//
// It is not real hardware; the unused MMIO window only lets the platform instantiate it with a
// reference to the clock controller. See also BES1700_HeadMotion.cs (same "helper peripheral" shape).
using System;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals.Bus;

namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public sealed class BES1700_ScoCall : IDoubleWordPeripheral, IKnownSize
    {
        public BES1700_ScoCall(IMachine machine, BES1700_ClockControl clock, bool wideBand = true)
        {
            this.wideBand = wideBand;
            clock.ScoDownlink = Next;
        }
        public long Size => 0x100;
        public uint ReadDoubleWord(long offset) => 0;
        public void WriteDoubleWord(long offset, uint value) { }
        public void Reset() { h2 = 0; sample = 0; }
        public bool WideBand { get { return wideBand; } set { wideBand = value; } }

        // One 7.5 ms frame: 120 samples at 16 kHz (mSBC) or 60 at 8 kHz (CVSD), encoded and, for mSBC,
        // H2-framed to 60 bytes. CVSD is a raw 60-byte bitstream.
        public byte[] Next()
        {
            if(wideBand) {
                var m = msbc.Encode(NextPcm(120, 16000));        // 57 bytes, 0xAD sync
                var frame = new byte[60];
                frame[0] = 0x01; frame[1] = H2[h2 & 3]; h2++;
                Array.Copy(m, 0, frame, 2, Math.Min(57, m.Length));
                return frame;                                    // [01][h2][57B mSBC][pad] = 60
            }
            return cvsd.Encode(NextPcm(60, 8000));               // raw 60-byte CVSD
        }

        // 440 Hz + 480 Hz call-progress tone, 2 s on / 1 s off (recognisable and clearly non-silent).
        private short[] NextPcm(int n, int rate)
        {
            var pcm = new short[n];
            for(int i = 0; i < n; i++) {
                double t = sample / (double)rate;
                double v = (t % 3.0) < 2.0 ? Math.Sin(2*Math.PI*440*t) + Math.Sin(2*Math.PI*480*t) : 0;
                pcm[i] = (short)(v * 7000);
                sample++;
            }
            return pcm;
        }

        private static readonly byte[] H2 = { 0x08, 0x38, 0xC8, 0xF8 };
        private readonly MsbcCodec msbc = new MsbcCodec();
        private readonly CvsdCodec cvsd = new CvsdCodec();
        private bool wideBand;
        private int h2;
        private long sample;
    }
}
