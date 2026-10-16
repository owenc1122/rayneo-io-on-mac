// MAX17335 fuel gauge / protector, one per temple battery (stock AP max17335_register:
// dev0L @ i2c0 0x36/0x0b, dev1R @ i2c0 0x76/0x4b, 400 kHz). The primary address serves
// registers 0x000-0x0ff, the secondary address (BES1700_MAX17335Page) 0x100-0x1ff.
// Registers are 16-bit little endian, pointer = first written byte.
// Functional model: a resting battery whose reported values follow the units the driver
// converts from (RepSOC 1/256 %, VCell 78.125 uV, Temp 1/256 C, Current 156.25 uV / Rsense).
// No charge/discharge dynamics, alerts or protection behaviour are simulated.
using System.Collections.Generic;
using Antmicro.Renode.Peripherals.I2C;
namespace Antmicro.Renode.Peripherals.Sensors
{
    public sealed class BES1700_MAX17335 : II2CPeripheral
    {
        public BES1700_MAX17335(int socPercent = 82, int cellMillivolts = 3950, int temperatureC = 27) { soc=socPercent;mv=cellMillivolts;temp=temperatureC;Reset(); }
        // Settable from the monitor (e.g. `gaugeL Soc 40`).
        public int Soc { get => soc; set { soc=System.Math.Max(0,System.Math.Min(100,value)); Apply(); } }
        public int CellMillivolts { get => mv; set { mv=value; Apply(); } }
        public int TemperatureC { get => temp; set { temp=value; Apply(); } }

        public void Write(byte[] data) { WritePage(0,data); }
        public byte[] Read(int count) { return ReadPage(count); }
        public void FinishTransmission() {}
        public void Reset()
        {
            regs.Clear();
            regs[0x00]=0x0000;        // Status
            regs[0x21]=0x4065;        // DevName (driver only logs it)
            regs[0x61]=0x0000;        // CommStat: DISOff/CHGOff clear, write-protect handled by value only
            regs[0x18]=0x0000;
            regs[0x1b0]=0x0000;       // nConfig
            pointer=0;highByte=false;Apply();
        }

        // Byte-oriented: the controller may fetch a 16-bit register one byte per read command.
        internal void WritePage(int page,byte[] data)
        {
            if(data.Length==0) return;
            pointer=page|data[0]; highByte=false;
            for(int i=1;i+1<data.Length;i+=2) {
                regs[pointer]=(ushort)(data[i]|(data[i+1]<<8));
                pointer=(pointer&0x100)|((pointer+1)&0xff);
            }
        }
        internal byte[] ReadPage(int count)
        {
            var result=new byte[count];
            for(int i=0;i<count;i++) {
                regs.TryGetValue(pointer,out var v);
                result[i]=highByte?(byte)(v>>8):(byte)v;
                if(highByte) pointer=(pointer&0x100)|((pointer+1)&0xff);
                highByte=!highByte;
            }
            return result;
        }
        private void Apply()
        {
            regs[0x06]=(ushort)(soc*256);                 // RepSOC
            regs[0x0d]=(ushort)(soc*256);                 // AvSOC
            regs[0x05]=(ushort)(soc*10);                  // RepCap (0.5 mAh units at 10 mOhm, nominal)
            regs[0x10]=1000;                              // FullCapRep
            ushort vcell=(ushort)(mv*1000/78.125);
            regs[0x1a]=vcell; regs[0x19]=vcell;           // VCell, AvgVCell
            regs[0xda]=vcell; regs[0xdb]=vcell;           // pack/cell voltage mirrors
            regs[0x1b]=(ushort)(temp*256); regs[0x16]=(ushort)(temp*256); // Temp, AvgTA
            regs[0x1c]=0; regs[0x1d]=0;                   // Current, AvgCurrent: resting
        }
        private readonly Dictionary<int,ushort> regs=new Dictionary<int,ushort>();
        private int pointer,soc,mv,temp;
        private bool highByte;
    }

    public sealed class BES1700_MAX17335Page : II2CPeripheral
    {
        public BES1700_MAX17335Page(BES1700_MAX17335 gauge) { this.gauge=gauge; }
        public void Write(byte[] data) { gauge.WritePage(0x100,data); }
        public byte[] Read(int count) { return gauge.ReadPage(count); }
        public void FinishTransmission() {}
        public void Reset() {}
        private readonly BES1700_MAX17335 gauge;
    }
}
