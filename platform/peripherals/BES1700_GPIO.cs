// GPIO register semantics and panel SPI inferred from the stock 1.0.4.12 HAL.
// The panel ID is a configurable emulated hardware profile, not a device readback.
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;
namespace Antmicro.Renode.Peripherals.GPIOPort
{
    public class BES1700_GPIO : IDoubleWordPeripheral, IKnownSize
    {
        public BES1700_GPIO(IMachine machine, bool panelSPI = false, byte panelId = 0x87)
        { this.panelSPI = panelSPI; this.panelId = panelId; Reset(); }
        public long Size => 0x1000;
        public uint ReadDoubleWord(long offset)
        {
            switch(offset) {
                case 0: return output;
                case 4: return direction;
                case 0x50: return panelSPI ? (output & ~Miso) | (miso ? Miso : 0) : output;
                default: return 0;
            }
        }
        public void WriteDoubleWord(long offset, uint value)
        {
            var old = output;
            switch(offset) {
                case 0: output |= value; break;
                case 0xc: output &= ~value; break;
                case 4: direction |= value; return;
                case 0x10: direction &= ~value; return;
                default: return;
            }
            if(!panelSPI) return;
            if((output & ChipSelects) == ChipSelects) { bits=0; index=0; shift=0; miso=false; return; }
            if((old & ChipSelects) != (output & ChipSelects)) { bits=0; index=0; shift=0; }
            if((old & Clock)==0 && (output & Clock)!=0)
            {
                // Sample MOSI and expose MISO on the rising edge, as the HAL does.
                if(index >= 2 && command == 0x19)
                    miso=(ReadPanelRegister(address) & (1 << (7-bits))) != 0;
                shift=(byte)((shift<<1) | ((output & Mosi)!=0 ? 1 : 0));
                if(++bits==8) {
                    TransferPanelByte(shift);
                    bits=0; shift=0;
                }
            }
        }
        public byte TransferPanelByte(byte value)
        {
            if((output & ChipSelects)==ChipSelects) return 0;
            byte response=0;
            if(index==0) command=value;
            else if(index==1) address=value;
            else if(command==0x18) { if((output&Cs)==0) registers[address]=value; if((output&RightCs)==0) rightRegisters[address]=value; }
            else if(command==0x19) response=ReadPanelRegister(address);
            if(index==2 && command==0x19 && address==0x34)
                this.Log(LogLevel.Info,"Panel SPI ID read: 0x{0:X2}",response);
            if(index==2 && (address==0x36 || address==0x17)) this.Log(LogLevel.Info,"Panel reg {0:X2} cmd={1:X2} value={2:X2} response={3:X2} selected={4:X}",address,command,value,response,(~output)&ChipSelects);
            index++;
            return response;
        }
        public void Reset() { output=panelSPI ? ChipSelects : 0; direction=0; miso=false; bits=0;index=0;shift=0;command=0;address=0;System.Array.Clear(registers,0,registers.Length);registers[0x34]=panelId;System.Array.Clear(rightRegisters,0,rightRegisters.Length);rightRegisters[0x34]=panelId; }
        private byte ReadPanelRegister(byte register) { return (byte)(((output&Cs)==0?registers[register]:255) & ((output&RightCs)==0?rightRegisters[register]:255)); }
        private const uint RightCs=1u<<23, ChipSelects=(1u<<16)|(1u<<23);
        private const uint Cs=1u<<16,Clock=1u<<17,Mosi=1u<<18,Miso=1u<<19;
        private readonly bool panelSPI;
        private readonly byte panelId;
        private readonly byte[] rightRegisters=new byte[256];
        private readonly byte[] registers=new byte[256];
        private uint output,direction;
        private bool miso;
        private int bits,index;
        private byte shift,command,address;
    }
}
