// Internal audio codec at 0x50300000 as the stock firmware uses it for the always-on path: the AP
// programs it (hal_codec_open / hal_codec_adc2_setup_stream / hal_codec_adc2_start_interface, run
// when the BTH asks for device "intcodec" with an smf Device message) and the BTH VAD pipeline
// (smf "@smf@m33c0", src-dma devName=codec2) reads ADC2 through BTH DMA1 request 6 from the FIFO
// data register +0x71c. Registers read back what was written (the driver probes channels that
// way); ADC2 is running while +0x700 bit0 (enable) and bit20 (DMA request) are set and the global
// ADC enable +0x80 bit0 is on. Each enabled ADC2 channel (+0x700 bit n+1) carries the Mac
// microphone (shared HiFi4 microphone timeline, 16 kHz), interleaved per frame as the hardware
// FIFO does. Analog front end, gains and filters are not modelled.
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.DMA;
using Antmicro.Renode.Peripherals.Timers;
using Antmicro.Renode.Time;

namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public sealed class BES1700_Codec : IDoubleWordPeripheral, IKnownSize
    {
        public BES1700_Codec(IMachine machine, BES1700_HiFi4 audio, BES1700_DMA dma)
        {
            this.machine = machine; this.audio = audio; this.dma = dma;
            timer = new LimitTimer(machine.ClockSource, 1000000, this, "codec", 1000, Direction.Descending,
                enabled: true, workMode: WorkMode.Periodic, eventEnabled: true, autoUpdate: true);
            timer.LimitReached += () => machine.ScheduleAction(TimeInterval.Empty, _ => Tick());   // off the clock-source lock
        }

        public long Size => 0x8000;
        public uint ReadDoubleWord(long offset)
        {
            lock(regs) {
                if(offset == Adc2Fifo) return 0;
                return regs.TryGetValue(offset, out var v) ? v : 0;
            }
        }
        public void WriteDoubleWord(long offset, uint value)
        {
            lock(regs) {
                regs.TryGetValue(offset, out var old);
                regs[offset] = value;
                if(offset == 0x700 && Running(value) != Running(old)) {
                    // (virtual time is read on the timer thread in Tick: reading it here, on a CPU thread
                    // inside this lock, can deadlock against Tick waiting for the lock)
                    restart = true;
                    pending.Clear(); generation++;
                    this.Log(LogLevel.Info, "codec: ADC2 {0} ({1} channels)", Running(value) ? "started" : "stopped", Channels(value));
                }
            }
        }
        public void Reset() { lock(regs) { regs.Clear(); pending.Clear(); generation++; } }

        private static bool Running(uint v) { return (v & 0x100001) == 0x100001; }
        private static int Channels(uint v) { int n = 0; for(int b = 1; b <= 8; b++) if((v & (1u << b)) != 0) n++; return Math.Max(1, n); }

        private void Tick()
        {
            // Samples are queued under the register lock, but handed to the DMA (which writes memory
            // through the system bus and raises IRQs) outside it: a CPU holding the bus while it writes
            // a codec register would otherwise wait on this lock while we wait on the bus.
            ushort[] batch; int gen, ch;
            lock(regs) {
                uint ctl = regs.TryGetValue(0x700, out var c) ? c : 0, glob = regs.TryGetValue(0x80, out var g) ? g : 0;
                if(!Running(ctl) || (glob & 1) == 0) return;
                ch = Channels(ctl);
                long now = audio.MicNow();
                if(restart) { restart = false; nextSample = now; }
                if(now > nextSample) {
                    var mono = audio.MicSamples(nextSample, (int)(now - nextSample));
                    foreach(var s in mono) for(int k = 0; k < ch; k++) pending.Enqueue((ushort)s);
                    nextSample = now;
                }
                if(pending.Count == 0) return;
                batch = pending.ToArray(); gen = generation;
            }
            // The DMA takes samples as long as a channel waits on the FIFO; the rest overflow (dropped).
            int moved = 0;
            while(moved < batch.Length && dma.PeripheralReceiveHalfword(Base + Adc2Fifo, batch[moved])) moved++;
            lock(regs) {
                if(gen != generation) return;   // ADC2 restarted meanwhile: the queue was cleared
                for(int i = 0; i < moved; i++) pending.Dequeue();
                if(pending.Count > 4096) { overflow += pending.Count; pending.Clear(); }
                if(moved > 0 && !announced) { announced = true; this.Log(LogLevel.Info, "codec: ADC2 samples reach BTH DMA ({0} channels)", ch); }
            }
        }

        private const uint Base = 0x50300000, Adc2Fifo = 0x71c;
        private readonly IMachine machine;
        private readonly BES1700_HiFi4 audio;
        private readonly BES1700_DMA dma;
        private readonly LimitTimer timer;
        private readonly Dictionary<long, uint> regs = new Dictionary<long, uint>();
        private readonly Queue<ushort> pending = new Queue<ushort>();
        private long nextSample, overflow;
        private int generation;
        private bool announced, restart;
    }
}
