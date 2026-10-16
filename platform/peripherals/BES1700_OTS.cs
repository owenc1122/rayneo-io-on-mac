// Drop-in replacement for platform/peripherals/BES1700_OTS.cs.
// "mixo" optical track sensor = the crown rotation encoder, I2C0 address 0x74 (existing repl entry).
// Stock driver (AP 0x10190000 image):
//   rayneo_mixo_ots_init 0x108dc700: ID register 0x1B must read 0xA1/0xB1/0xC1.
//   callisto_2x_init 0x1095c258: product ID registers 0x00/0x01 must read 0x58/0x5B (read-only).
//   mixo_ots_register 0x108dcb0c -> mixo_set_interrupt_pin(0x4e) = GPIO2 bit14, IOEXPANDER INTCFG 0x0a (falling edge).
//   mixo_ots_irq_handler 0x108dc930 queues mixo_ots_work_handler 0x108dc9e4 which loops:
//       reg 0x02 (motion status, bit7 = motion)  -> if set: mixo_ots_get_raw_data 0x1095c0f8:
//       reg 0x12 = (dx[11:8]<<4)|dy[11:8], reg 0x03 = dx[7:0], reg 0x04 = dy[7:0]; 12-bit two's complement,
//       0x800 treated as 0; |d|==0x7ff is logged as overflow.  Loop ends when bit7 clears, then 0x02 is read twice
//       (mixo_ots_forced_clear_int 0x1095c208).
//   The sample {timestamp, x, y} is published as a uORB sensor; rayneo_wheel_read 0x108207fc uses X.
//   One wheel step = 375 counts (lv_rayneo_input wheel_trigger_step_x default @0x1832d314); |x|<=7 ignored.
// repl sketch:  ots: Sensors.BES1700_OTS @ i2c0 0x74
//                   MotionIRQ -> gpio2@14
// monitor:      ots Rotate 400      (one detent clockwise; negative = other direction)
using System;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.I2C;
namespace Antmicro.Renode.Peripherals.Sensors
{
    public sealed class BES1700_OTS : II2CPeripheral
    {
        public BES1700_OTS(){MotionIRQ=new GPIO();Reset();}
        public GPIO MotionIRQ {get; private set;}       // active low; connect to gpio2@14
        public int CountsPerStep {get; set;} = 375;

        public void Rotate(int counts) {pendingX+=counts;Raise();}
        public void Steps(int steps) {Rotate(steps*CountsPerStep+(steps>0?8:steps<0?-8:0));}
        public void Move(int dx,int dy) {pendingX+=dx;pendingY+=dy;Raise();}

        public void Write(byte[] data){if(data.Length==0)return;pointer=data[0];for(int i=1;i<data.Length;i++){if(pointer!=0x1b&&pointer>0x01)registers[pointer]=data[i];pointer=(pointer+1)&255;}}
        public byte[] Read(int count){var result=new byte[count];for(int i=0;i<count;i++){result[i]=ReadRegister(pointer);pointer=(pointer+1)&255;}return result;}
        public void FinishTransmission(){}
        public void Reset(){registers=new byte[256];registers[0x1b]=0xa1;registers[0x00]=0x58;registers[0x01]=0x5b;pointer=0;pendingX=pendingY=0;latched=false;MotionIRQ.Set(true);}

        private byte ReadRegister(int reg) {
            switch(reg) {
            case 0x02:
                if(pendingX!=0||pendingY!=0) {
                    int dx=Clamp(pendingX),dy=Clamp(pendingY); pendingX-=dx; pendingY-=dy;
                    latchX=dx&0xfff; latchY=dy&0xfff; latched=true;
                    return 0x80;
                }
                latched=false; MotionIRQ.Set(true);            // no more motion: release the line
                return 0x00;
            case 0x12: return latched?(byte)(((latchX>>8)<<4)|(latchY>>8)):(byte)0;
            case 0x03: return latched?(byte)latchX:(byte)0;
            case 0x04: return latched?(byte)latchY:(byte)0;
            default: return registers[reg];
            }
        }
        private static int Clamp(int v) {return Math.Max(-2000,Math.Min(2000,v));}
        private void Raise() {MotionIRQ.Set(true);MotionIRQ.Set(false);}   // falling edge
        private byte[] registers;
        private int pointer,pendingX,pendingY,latchX,latchY;
        private bool latched;
    }
}
