// Inferred digital-controller reset behavior. No radio or HCI responses synthesized.
using Antmicro.Renode.Core;
using Antmicro.Renode.Time;
using Antmicro.Renode.Peripherals.Timers;
namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public sealed class BES1700_BTController : BES1700_RegisterBank
    {
        public BES1700_BTController(IMachine machine, uint versionWord = 0):base(machine) {
            this.versionWord=versionWord;
            clock=new LimitTimer(machine.ClockSource,2000000UL,this,"btFineClock",uint.MaxValue,
                direction:Direction.Ascending,enabled:true,eventEnabled:false,autoUpdate:true);
        }
        public override void WriteDoubleWord(long offset,uint value) {
            // Stock controller initialization requests bit 31 then waits for it to clear.
            // Reset the digital control/interrupt state synchronously; preserve RF setup.
            if(offset==0 && (value&0x80000000u)!=0) {
                for(long o=0;o<=0x30;o+=4)base.WriteDoubleWord(o,0);
                value&=0x7fffffffu;
            }
            // Second core control block at +0x400 (written by BTC init right after the version
            // check): bit 31 is a self-clearing soft reset the firmware polls for.
            if(offset==0x400 && (value&0x80000000u)!=0) {
                for(long o=0x404;o<=0x430;o+=4) if(o!=0x404) base.WriteDoubleWord(o,0);
                value&=0x7fffffffu;
            }
            if(offset==0x100 && (value&0x80000000u)!=0) {
                // Firmware reads a 28-bit half-slot clock and a 625-step fine counter.
                // One half-slot is 312.5 us; capture both from the same virtual instant.
                ulong ticks=clock.Value;
                value=(uint)((ticks/625)&0x0fffffff);
                base.WriteDoubleWord(0x104,(uint)(624-ticks%625));
                base.WriteDoubleWord(0x9c4,(uint)(ticks/2));
            }
            base.WriteDoubleWord(offset,value);
        }
        // Baseband IP version at +0x404 (BTC init asserts it equals 0x0B000600 on the radio block).
        public override uint ReadDoubleWord(long offset) {
            if(offset==0x404 && versionWord!=0) return versionWord;
            return base.ReadDoubleWord(offset);
        }
        private readonly LimitTimer clock;
        private readonly uint versionWord;
    }
}
