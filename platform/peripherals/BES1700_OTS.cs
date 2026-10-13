// Minimal stationary OTS profile. Firmware accepts ID A1 at register 1B;
// this is a functional profile, not a physical-device ID measurement.
using Antmicro.Renode.Peripherals.I2C;
namespace Antmicro.Renode.Peripherals.Sensors
{
    public sealed class BES1700_OTS : II2CPeripheral
    {
        public BES1700_OTS(){Reset();}
        public void Write(byte[] data){if(data.Length==0)return;pointer=data[0];for(int i=1;i<data.Length;i++){if(pointer!=0x1b)registers[pointer]=data[i];pointer=(pointer+1)&255;}}
        public byte[] Read(int count){var result=new byte[count];for(int i=0;i<count;i++){result[i]=registers[pointer];pointer=(pointer+1)&255;}return result;}
        public void FinishTransmission(){}
        public void Reset(){registers=new byte[256];registers[0x1b]=0xa1;pointer=0;}
        private byte[] registers;
        private int pointer;
    }
}
