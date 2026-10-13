// GC265 control-register profile inferred from the stock AP driver's identity checks.
// Register offsets/idle mask corroborated by nxp-mcuxpresso/gpu-vglite vg_lite_hw.h.
// Command execution is deliberately unfinished: pending work stays busy, without a fake completion IRQ.
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Miscellaneous;
namespace Antmicro.Renode.Peripherals.Video
{
    public class BES1700_GPU : BES1700_RegisterBank
    {
        public BES1700_GPU(IMachine machine):base(machine) {this.machine=machine;}
        public override uint ReadDoubleWord(long offset) {
            switch(offset) {
                case 4:return busy?0u:0xb05u;
                case 0x20:return 0x265;
                case 0x24:return 0x2002;
                case 0x30:return 0x420;
                default:return base.ReadDoubleWord(offset);
            }
        }
        public override void WriteDoubleWord(long offset,uint value) {
            base.WriteDoubleWord(offset,value);
            if(offset==0 && (value&0x1000)!=0) busy=false;
            if(offset!=0x504 || value==0) return;
            busy=true;
            uint address=ReadDoubleWord(0x500);
            var bus=machine.GetSystemBus(this);
            this.Log(LogLevel.Warning,"GPU command execution pending: address={0:X} bytes={1}",address,value*8);
            for(uint i=0;i<System.Math.Min(value,32u);i++)
                this.Log(LogLevel.Info,"GPU CMD {0:X}: {1:X8} {2:X8}",address+i*8,bus.ReadDoubleWord(address+i*8),bus.ReadDoubleWord(address+i*8+4));
        }
        private readonly IMachine machine;
        private bool busy;
    }
}
