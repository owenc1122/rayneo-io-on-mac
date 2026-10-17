using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.DMA;
using Antmicro.Renode.Time;
namespace Antmicro.Renode.Peripherals.UART
{
    // PL011 with the BES console's receive paths; transmit is the PL011 base model. Received bytes go to a
    // 32-entry RX FIFO modelled here:
    //  - RXDMAE (DMACR bit0) set: the FIFO drains into the DMA channel whose source is DR, and the driver
    //    (dma_mode_uart_irq_handler) collects them on the receive-timeout interrupt (bit 6), reading the
    //    remaining count from the DMA channel. The DMA request is a level, so bytes left over are taken
    //    as soon as the driver restarts the channel.
    //  - RXDMAE clear (the console after deep sleep, nuttx_uart_enable_rxirq): bytes wait in the FIFO and
    //    raise the RX interrupt (bit 4, FIFO at the IFLS level) and the receive timeout (bit 6, FIFO not
    //    empty and idle); DR reads take them.
    //  - The RX pin as a GPIO input (UART0 RX = P2_2, gpio0 bit 18; idles high): before deep sleep the AP's
    //    console_prepare_wakeup muxes it to GPIO with a falling-edge interrupt and
    //    hal_uart_rx_gpio_irq_handler switches it back to the UART; every byte's start bit is that edge.
    // The interrupt line is driven by this class (Interrupt), the base model's IRQ is not connected.
    public sealed class BES1700_UART : PL011, IDoubleWordPeripheral
    {
        public BES1700_UART(IMachine machine, BES1700_DMA dma = null) : base(machine) { this.machine = machine; this.dma = dma; }
        public GPIO Interrupt { get; } = new GPIO();
        public GPIO RxLine { get; } = new GPIO();
        public new uint ReadDoubleWord(long offset)
        {
            switch(offset) {
                case 0x00:
                    if(fifo.Count == 0) return 0;
                    uint b = fifo.Dequeue();
                    if(fifo.Count == 0) timeout = false;
                    Update();
                    return b;
                case 0x18: return (base.ReadDoubleWord(0x18) & ~0x50u) | (fifo.Count == 0 ? 0x10u : 0) | (fifo.Count >= FifoSize ? 0x40u : 0);
                case 0x38: return mask;
                case 0x3c: return RawStatus();
                case 0x40: return RawStatus() & mask;
                case 0x48: return dmaControl;
                default: return base.ReadDoubleWord(offset);
            }
        }
        public new void WriteDoubleWord(long offset, uint value)
        {
            if(offset == 0x48) { dmaControl = value & 7; Service(); return; }
            if(offset == 0x38) mask = value;
            if(offset == 0x44 && (value & 0x40) != 0) {
                timeout = false;
                // the timeout comes back while bytes are still waiting and nothing takes them
                if(fifo.Count > 0) Later(() => { if(fifo.Count > 0) { timeout = true; Update(); } });
            }
            base.WriteDoubleWord(offset, value);
            Update();
        }
        protected override void CharWritten()
        {
            RxLine.Set(); RxLine.Unset(); RxLine.Set();   // idle high, start bit low
            while(TryGetCharacter(out var c)) {
                if(fifo.Count < FifoSize) fifo.Enqueue(c); else overrun = true;
            }
            if(!Dma) timeout = fifo.Count > 0;
            Service();
        }
        private bool Dma => (dmaControl & 1) != 0 && dma != null;
        private void Service()
        {
            if(Dma && fifo.Count > 0) {
                bool moved = false;
                while(fifo.Count > 0 && dma.PeripheralReceive(DataRegister, fifo.Peek())) { fifo.Dequeue(); moved = true; }
                if(moved) timeout = true;
                if(fifo.Count > 0) Later(Service);
            }
            Update();
        }
        private void Later(System.Action action)
        {
            if(retryScheduled) return;
            retryScheduled = true;
            machine.ScheduleAction(TimeInterval.FromMilliseconds(1), _ => { retryScheduled = false; action(); });
        }
        private uint RawStatus()
        {
            uint level = new uint[] { 4, 8, 16, 24, 28, 28, 28, 28 }[(base.ReadDoubleWord(0x34) >> 3) & 7];
            return (base.ReadDoubleWord(0x3c) & ~0x450u) | (!Dma && fifo.Count >= level ? 0x10u : 0) | (timeout ? 0x40u : 0) | (overrun ? 0x400u : 0);
        }
        private void Update() { Interrupt.Set((RawStatus() & mask & 0x7f0) != 0); }
        public override void Reset() { base.Reset(); dmaControl = 0; mask = 0; timeout = overrun = false; fifo.Clear(); Interrupt.Unset(); }
        private const int FifoSize = 32;
        private const uint DataRegister = 0x4000b000;
        private readonly BES1700_DMA dma;
        private readonly IMachine machine;
        private bool retryScheduled, timeout, overrun;
        private readonly Queue<byte> fifo = new Queue<byte>();
        private uint dmaControl, mask;
    }
}
