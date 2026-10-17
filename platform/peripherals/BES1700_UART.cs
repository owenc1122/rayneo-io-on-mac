using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.DMA;
namespace Antmicro.Renode.Peripherals.UART
{
    // PL011 transport with BES DMA-control register readback. The stock console receives with
    // RXDMAE (DMACR bit0): bytes go from DR to the DMA channel whose source is DR, and the driver
    // (dma_mode_uart_irq_handler) collects them on the receive-timeout interrupt (bit 6), reading the
    // remaining count from the DMA channel. Only that path is modelled here; the interrupt line is
    // driven by this class (Interrupt) because the PL011 base model has no receive timeout.
    public sealed class BES1700_UART : PL011, IDoubleWordPeripheral
    {
        public BES1700_UART(IMachine machine, BES1700_DMA dma = null) : base(machine) { this.dma = dma; }
        public GPIO Interrupt { get; } = new GPIO();
        public new uint ReadDoubleWord(long offset)
        {
            if(offset == 0x48) return dmaControl;
            if(offset == 0x38) return mask;
            if(offset == 0x3c) return base.ReadDoubleWord(offset) | (timeout ? 0x40u : 0);
            if(offset == 0x40) return (base.ReadDoubleWord(0x3c) | (timeout ? 0x40u : 0)) & mask;
            return base.ReadDoubleWord(offset);
        }
        public new void WriteDoubleWord(long offset, uint value)
        {
            if(offset == 0x48) { dmaControl = value & 7; Drain(); return; }
            if(offset == 0x38) mask = value;
            if(offset == 0x44 && (value & 0x40) != 0) timeout = false;
            base.WriteDoubleWord(offset, value);
            Update();
        }
        protected override void CharWritten()
        {
            if((dmaControl & 1) == 0 || dma == null) { base.CharWritten(); return; }
            while(TryGetCharacter(out var c)) pending.Enqueue(c);
            Drain();
        }
        // Push queued bytes into the RX DMA channel; leftovers wait for the driver to restart it.
        private void Drain()
        {
            if((dmaControl & 1) == 0 || dma == null || pending.Count == 0) return;
            bool moved = false;
            while(pending.Count > 0 && dma.PeripheralReceive(DataRegister, pending.Peek())) { pending.Dequeue(); moved = true; }
            if(moved) { timeout = true; Update(); }
        }
        private void Update() { Interrupt.Set(timeout && (mask & 0x40) != 0); }
        public override void Reset() { base.Reset(); dmaControl = 0; mask = 0; timeout = false; pending.Clear(); Interrupt.Unset(); }
        private const uint DataRegister = 0x4000b000;
        private readonly BES1700_DMA dma;
        private readonly Queue<byte> pending = new Queue<byte>();
        private uint dmaControl, mask;
        private bool timeout;
    }
}
