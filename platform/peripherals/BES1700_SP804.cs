// ARM SP804-compatible dual timer used by the BES HAL hwtimer (hal_timer_common_* in the stock AP:
// bases table 0x201045a0 = {0x40083000, 0x40002000}, IRQ table 0x20101388 = {58,59},{66,67}).
// Per sub-timer (stride 0x20): Load +0x00, Value +0x04, Control +0x08, IntClr +0x0c, RIS +0x10,
// MIS +0x14, BGLoad +0x18. Control: 0x80 enable, 0x40 periodic, 0x20 IRQ enable, 0x0c prescale
// (/1, /16, /256), 0x02 32-bit, 0x01 one-shot. Timer clock is a constructor parameter (block 0
// reloads against the 16384 Hz AON system timer). Functional model; no clock-domain latency.
using System;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.Timers;
using Antmicro.Renode.Time;
namespace Antmicro.Renode.Peripherals.Timers
{
    public sealed class BES1700_SP804 : IDoubleWordPeripheral, IKnownSize
    {
        public BES1700_SP804(IMachine machine, ulong frequency = 16384)
        {
            IRQ0 = new GPIO(); IRQ1 = new GPIO();
            subs = new[] { new Sub(machine, frequency, IRQ0, "t0"), new Sub(machine, frequency, IRQ1, "t1") };
        }
        public GPIO IRQ0 { get; }
        public GPIO IRQ1 { get; }
        public long Size => 0x1000;
        public uint ReadDoubleWord(long offset)
        {
            if(offset >= 0x40) return 0;
            return subs[offset / 0x20].Read(offset % 0x20);
        }
        public void WriteDoubleWord(long offset, uint value)
        {
            if(offset >= 0x40) return;
            subs[offset / 0x20].Write(offset % 0x20, value);
        }
        public void Reset() { foreach(var s in subs) s.Reset(); }
        private readonly Sub[] subs;

        private sealed class Sub
        {
            public Sub(IMachine machine, ulong frequency, GPIO irq, string name)
            {
                this.irq = irq; this.frequency = frequency;
                timer = new LimitTimer(machine.ClockSource, frequency, null, name, uint.MaxValue, Direction.Descending,
                    enabled: false, workMode: WorkMode.Periodic, eventEnabled: true, autoUpdate: true);
                timer.LimitReached += OnLimit;
                Reset();
            }
            public uint Read(long offset)
            {
                switch(offset) {
                    case 0x00: return load;
                    case 0x04: return running ? (uint)Math.Max(2UL, timer.Value) - 2 : value;
                    case 0x08: return control;
                    case 0x10: return ris ? 1u : 0u;
                    case 0x14: return ris && (control & 0x20) != 0 ? 1u : 0u;
                    case 0x18: return load;
                    default: return 0;
                }
            }
            public void Write(long offset, uint v)
            {
                switch(offset) {
                    case 0x00: load = v; Restart(v); break;           // Load: reload the counter now
                    case 0x08: SetControl(v); break;
                    case 0x0c: ris = false; Update(); break;
                    case 0x18: load = v; break;                        // BGLoad: next period only
                }
            }
            public void Reset()
            {
                timer.Enabled = false; running = false; load = 0; value = 0xffffffff; control = 0x20; ris = false; irq.Unset();
            }
            private void SetControl(uint v)
            {
                bool wasEnabled = (control & 0x80) != 0;
                if(running) value = (uint)timer.Value;
                control = v;
                int pre = (int)((v >> 2) & 3);
                timer.Divider = pre == 1 ? 16UL : pre == 2 ? 256UL : 1UL;
                timer.Mode = (v & 0x01) != 0 ? WorkMode.OneShot : WorkMode.Periodic;
                if((v & 0x80) != 0 && !wasEnabled) Restart(value == 0 ? Period() : value);
                else if((v & 0x80) == 0) { timer.Enabled = false; running = false; }
                Update();
            }
            private ulong Period() { return (control & 0x40) != 0 && load != 0 ? load : 0xffffffffUL; }
            private void Restart(ulong start)
            {
                value = (uint)start;
                if((control & 0x80) == 0) { running = false; return; }
                running = true;
                // SP804 counts Load..0 and interrupts on the following tick: a period is Load+1 ticks
                // (the HAL programs Load = ticks-1 and checks the AON timer for early expiry).
                // The real counter decrements on the shared clock edges, so the first decrement waits for
                // the next edge; this model starts mid-tick, so one extra tick keeps it from firing early.
                timer.Enabled = false;
                timer.Limit = start + 2;
                timer.Value = start + 2;
                timer.Enabled = true;
            }
            private void OnLimit()
            {
                ris = true; Update();
                // One-shot: the counter halts at zero but stays enabled; a Load write restarts it.
                if((control & 0x01) != 0) { value = 0; running = false; timer.Enabled = false; return; }
                // Periodic: reload from Load; free-running: wrap to 0xffffffff.
                Restart(Period());
            }
            private void Update() { irq.Set(ris && (control & 0x20) != 0); }
            private readonly LimitTimer timer;
            private readonly GPIO irq;
            private readonly ulong frequency;
            private uint load, value, control;
            private bool ris, running;
        }
    }
}
