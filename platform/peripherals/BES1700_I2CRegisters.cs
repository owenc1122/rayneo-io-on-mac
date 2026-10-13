// Byte-addressed I2C control registers used by the observed power/LED drivers.
// Optional immutable identification byte; other reset values are provisional zeros.
// Electrical outputs, conversion results, faults and timing are not simulated.
using Antmicro.Renode.Peripherals.I2C;
namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public sealed class BES1700_I2CRegisters : II2CPeripheral
    {
        public BES1700_I2CRegisters(int idAddress=-1, byte idValue=0)
        {
            if(idAddress < -1 || idAddress > 255) throw new System.ArgumentOutOfRangeException("idAddress");
            this.idAddress=idAddress;this.idValue=idValue;Reset();
        }
        public void Write(byte[] data)
        {
            if(data.Length==0) return;
            pointer=data[0];
            for(int i=1;i<data.Length;i++) {
                if(pointer!=idAddress) registers[pointer]=data[i];
                pointer=(pointer+1)&255;
            }
        }
        public byte[] Read(int count)
        {
            var result=new byte[count];
            for(int i=0;i<count;i++) {result[i]=registers[pointer];pointer=(pointer+1)&255;}
            return result;
        }
        public void FinishTransmission() {}
        public void Reset() {System.Array.Clear(registers,0,registers.Length);if(idAddress>=0)registers[idAddress]=idValue;pointer=0;}
        private readonly byte[] registers=new byte[256];
        private readonly int idAddress;
        private readonly byte idValue;
        private int pointer;
    }
}
