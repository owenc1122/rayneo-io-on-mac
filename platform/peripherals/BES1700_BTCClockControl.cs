using Antmicro.Renode.Core;
namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public sealed class BES1700_BTCClockControl : BES1700_RegisterBank
    {
        public BES1700_BTCClockControl(IMachine machine,BES1700_ClockControl systemControl):base(machine) {this.systemControl=systemControl;}
        private static bool IsIPC(long o)=>o==0x50 || o==0x54 || o==0xa0 || o==0xa4 || o==0xac || o==0xb0;
        public override uint ReadDoubleWord(long offset)=>IsIPC(offset)?systemControl.ReadBluetoothIPC(offset):base.ReadDoubleWord(offset);
        public override void WriteDoubleWord(long offset,uint value) {
            if(IsIPC(offset))systemControl.WriteBluetoothIPC(offset,value);
            else base.WriteDoubleWord(offset,value);
        }
        private readonly BES1700_ClockControl systemControl;
    }
}
