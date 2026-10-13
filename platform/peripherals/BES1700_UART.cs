using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals.Bus;
namespace Antmicro.Renode.Peripherals.UART
{
    // PL011 transport with BES DMA-control register readback.
    public sealed class BES1700_UART : PL011, IDoubleWordPeripheral
    {
        public BES1700_UART(IMachine machine) : base(machine) {}
        public new uint ReadDoubleWord(long offset) {return offset==0x48?dmaControl:base.ReadDoubleWord(offset);}
        public new void WriteDoubleWord(long offset,uint value) {if(offset==0x48) dmaControl=value&7;else base.WriteDoubleWord(offset,value);}
        public override void Reset(){base.Reset();dmaControl=0;}
        private uint dmaControl;
    }
}
