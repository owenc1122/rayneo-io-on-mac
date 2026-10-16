// New peripheral for the AON power/sleep controller window 0x40085000.
// Only the GPIO wake/IRQ aggregation used by the stock HAL is modelled; every other offset is plain storage
// (the block is currently unmapped in platform/best1700.repl, so reads there return 0 with a warning).
//   hal_psc_gpio_irq_enable 0x105b1ed8: pointer table 0x182995b0 -> enable regs 0x0fc (bank0) 0x1a4 (bank1) 0x1c8 (bank2)
//   hal_psc_gpio_irq_get_status 0x105b1f1c: pointer table 0x182995a4 -> status regs 0x108 0x1a8 0x1cc
//   _hal_gpio_irq_handler 0x105b9360 iterates those status words and then writes the GPIO bank EOI (0x4c).
// repl sketch:
//   psc: Miscellaneous.BES1700_PSC @ sysbus 0x40085000
//       gpio0: gpio0
//       gpio1: gpio1
//       gpio2: gpio2
//       IRQ -> nvic@2
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.GPIOPort;
namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public class BES1700_PSC : IDoubleWordPeripheral, IKnownSize
    {
        public BES1700_PSC(IMachine machine, BES1700_GPIO gpio0, BES1700_GPIO gpio1, BES1700_GPIO gpio2)
        {
            banks = new[] { gpio0, gpio1, gpio2 };
            foreach(var g in banks) if(g != null) g.PendingChanged += Update;
            IRQ = new GPIO();
        }
        public long Size => 0x1000;
        public GPIO IRQ { get; private set; }
        public uint ReadDoubleWord(long offset)
        {
            int s = System.Array.IndexOf(StatusRegs, offset);
            if(s >= 0) return banks[s] == null ? 0 : banks[s].Pending & Get(EnableRegs[s]);
            return Get(offset);
        }
        public void WriteDoubleWord(long offset, uint value)
        {
            if(System.Array.IndexOf(StatusRegs, offset) >= 0) return;   // status is derived from the GPIO banks
            values[offset] = value;
            if(System.Array.IndexOf(EnableRegs, offset) >= 0) Update();
        }
        public void Reset() { values.Clear(); IRQ.Unset(); }
        private void Update()
        {
            bool any = false;
            for(int i = 0; i < 3; i++) if(banks[i] != null && (banks[i].Pending & Get(EnableRegs[i])) != 0) any = true;
            IRQ.Set(any);
        }
        private uint Get(long o) { return values.TryGetValue(o, out var v) ? v : 0; }
        private static readonly long[] EnableRegs = { 0x0fc, 0x1a4, 0x1c8 };
        private static readonly long[] StatusRegs = { 0x108, 0x1a8, 0x1cc };
        private readonly BES1700_GPIO[] banks;
        private readonly Dictionary<long, uint> values = new Dictionary<long, uint>();
    }
}
