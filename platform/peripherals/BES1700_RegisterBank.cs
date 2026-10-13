// Preliminary storage for inferred read/write control registers only.
// No synthesized completion, radio events, or device responses.
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;
namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public class BES1700_RegisterBank : IDoubleWordPeripheral, IKnownSize
    {
        public BES1700_RegisterBank(IMachine machine,bool traceAccesses=false) {this.traceAccesses=traceAccesses;}
        public long Size=>0x1000;
        public virtual uint ReadDoubleWord(long offset){uint value=values.TryGetValue(offset,out var v)?v:0;Trace("R",offset,value);return value;}
        public virtual void WriteDoubleWord(long offset,uint value){Trace("W",offset,value);values[offset]=value;}
        public void Reset(){values.Clear();}
        private void Trace(string op,long offset,uint value) {if(traceAccesses && seen.Add(op+offset))this.Log(LogLevel.Info,"{0} {1:X} = {2:X}",op,offset,value);}
        private readonly bool traceAccesses;
        private readonly HashSet<string> seen=new HashSet<string>();
        private readonly Dictionary<long,uint> values=new Dictionary<long,uint>();
    }
}
