// Functional PSRAM register model derived from hal_psram_* in the AP image.
// The mapped memory stores data independently; PHY timing is not cycle accurate.
using System.Collections.Generic;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;
namespace Antmicro.Renode.Peripherals.Memory
{
    public sealed class BES1700_PSRAM : IDoubleWordPeripheral, IKnownSize
    {
        public BES1700_PSRAM(bool phy=false) {this.phy=phy;}
        public uint ReadDoubleWord(long offset) {
            // DLL lock-state field polled by hal_psram_phy_init after enabling DLLs.
            if(phy && offset==0x44) return (Value(0x40)&0x1800)==0x1800?0x06000000u:0;
            if(!phy && offset==0x404) return 0x400u; // Eight free TX FIFO words; idle, RX empty.
            return Value(offset);
        }
        public void WriteDoubleWord(long offset,uint value) {registers[offset]=value;}
        private uint Value(long offset) {return registers.TryGetValue(offset,out var v)?v:0;}
        public void Reset(){registers.Clear();}
        public long Size=>0x1000;
        private readonly bool phy;
        private readonly Dictionary<long,uint> registers=new Dictionary<long,uint>();
    }
}
