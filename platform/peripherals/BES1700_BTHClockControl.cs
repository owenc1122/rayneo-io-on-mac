// BTH-side system CMU at 0x50000000, inferred from the stock BTH image.
// +0x90 is the free-running 6 MHz tick the BTH delay loops poll (us * 6).
// +0x134/+0x138/+0x168/+0x16c/+0x170/+0x174 are the BTH half of the AP<->BTH
// mailbox and share state with the AP system CMU model. Everything else is storage.
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals.Timers;
using Antmicro.Renode.Time;
namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public sealed class BES1700_BTHClockControl : BES1700_RegisterBank
    {
        public BES1700_BTHClockControl(IMachine machine,BES1700_ClockControl systemControl):base(machine) {
            this.systemControl=systemControl;
            counter=new LimitTimer(machine.ClockSource,6000000UL,this,"tick",uint.MaxValue,direction: Direction.Ascending,enabled: true,eventEnabled: false,autoUpdate: true);
        }
        private static bool IsIPC(long o)=>o==0x134 || o==0x138 || o==0x168 || o==0x16c || o==0x170 || o==0x174;
        public override uint ReadDoubleWord(long offset) {
            if(offset==0x90) return (uint)counter.Value;
            return IsIPC(offset)?systemControl.ReadBthIPC(offset):base.ReadDoubleWord(offset);
        }
        public override void WriteDoubleWord(long offset,uint value) {
            if(IsIPC(offset)) systemControl.WriteBthIPC(offset,value);
            else base.WriteDoubleWord(offset,value);
        }
        private readonly BES1700_ClockControl systemControl;
        private readonly LimitTimer counter;
    }
}
