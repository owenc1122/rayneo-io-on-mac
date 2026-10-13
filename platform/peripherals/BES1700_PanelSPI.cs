// Functional PL022-style SPI transport for the GPIO-selected panel.
using System.Collections.Generic;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.GPIOPort;
namespace Antmicro.Renode.Peripherals.SPI
{
    public class BES1700_PanelSPI : IDoubleWordPeripheral, IKnownSize
    {
        public BES1700_PanelSPI(BES1700_GPIO panel) {this.panel=panel;}
        public long Size=>0x1000;
        public uint ReadDoubleWord(long offset) {
            if(offset==0xc) return 3u|(fifo.Count>0?4u:0u);
            if(offset==8) return fifo.Count>0?fifo.Dequeue():0;
            return values.TryGetValue(offset,out var v)?v:0;
        }
        public void WriteDoubleWord(long offset,uint value) {
            if(offset==8) fifo.Enqueue(panel.TransferPanelByte((byte)value));
            else values[offset]=value;
        }
        public void Reset() {fifo.Clear();values.Clear();}
        private readonly BES1700_GPIO panel;
        private readonly Queue<uint> fifo=new Queue<uint>();
        private readonly Dictionary<long,uint> values=new Dictionary<long,uint>();
    }
}
