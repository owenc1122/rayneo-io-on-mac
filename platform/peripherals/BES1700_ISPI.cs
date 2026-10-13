// Synchronous internal SPI register transport. IDs are configurable assumptions
// until a physical chip-ID readback is supplied; no firmware instructions are patched.
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;
namespace Antmicro.Renode.Peripherals.SPI
{
    public sealed class BES1700_ISPI : IDoubleWordPeripheral, IKnownSize
    {
        public BES1700_ISPI(uint socId = 0x1700, uint pmuId = 0x18f0, uint pmuSubtype = 0x650) { this.socId=socId;this.pmuId=pmuId;this.pmuSubtype=pmuSubtype; }
        public uint ReadDoubleWord(long offset)
        {
            if(offset==0xc) return 3u | (fifo.Count>0?4u:0u); // TX empty/not full, RX not empty, not busy
            if(offset==8) return fifo.Count>0?fifo.Dequeue():0;
            return registers.TryGetValue(offset,out var value)?value:0;
        }
        public void WriteDoubleWord(long offset,uint value)
        {
            if(offset!=8) {registers[offset]=value;return;}
            uint cs=(ReadDoubleWord(4)>>7)&15;
            bool wide=(((ReadDoubleWord(0)>>16)&31)+1)>25;
            uint address=wide?(value>>18)&0x3ff:(value>>16)&0xff;
            bool read=(value&(wide?0x10000000u:0x1000000u))!=0;
            uint key=cs*0x1000+address;
            uint response=0;
            if(read) {
                if(address==0 && cs==7) response=socId;
                else if(address==0 && cs==0) response=pmuId;
                else if(address==1 && cs==0) response=pmuSubtype;
                // PSRAM analog DLL status: lock bit 6, delay tap count bits 5:0.
                // Ideal functional PHY (no analog timing or range-error simulation).
                else if(address==0x51 && cs==5) response=0x50;
                else {
                    analog.TryGetValue(key,out response);
                    // Boot calibration: write 0xa000 to PMU 0x4f starts a conversion.
                    // The firmware polls bits 7:6 for 01. Conversion is instantaneous
                    // in this functional model; analog timing is not calibrated.
                    if(cs==0 && address==0x4f && (response&0xa000)==0xa000)
                        response=(response&~0xc0u)|0x40u;
                }
            } else if(address!=0 || (cs!=0 && cs!=7)) analog[key]=(wide?value>>2:value)&0xffff;
            if(fifo.Count<32) fifo.Enqueue(wide?response<<2:response);
        }
        public void Reset(){registers.Clear();analog.Clear();fifo.Clear();}
        public long Size=>0x1000;
        private readonly uint socId,pmuId,pmuSubtype;
        private readonly Dictionary<long,uint> registers=new Dictionary<long,uint>();
        private readonly Dictionary<uint,uint> analog=new Dictionary<uint,uint>();
        private readonly Queue<uint> fifo=new Queue<uint>();
    }
}
