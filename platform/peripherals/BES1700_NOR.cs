// Functional NOR controller inferred from the stock firmware's norflaship_* routines.
// JEDEC C8 60 18 is a supported 16 MiB profile, NOT a physical-device ID readback.
// Command completion is synchronous; controller and flash timing remain uncalibrated.
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;
namespace Antmicro.Renode.Peripherals.SPI
{
    public sealed class BES1700_NOR : IDoubleWordPeripheral, IBytePeripheral, IKnownSize
    {
        public BES1700_NOR(IMachine machine, uint jedec = 0xc86018, uint flashBase = 0x10000000, uint flashSize = 0x2000000, uint readMask = 0xffffff) { this.machine=machine;this.jedec=jedec;this.flashBase=flashBase;this.flashSize=flashSize;this.readMask=readMask; }
        public uint ReadDoubleWord(long offset) {
            if(offset==0xc) return (31u<<9) | ((uint)Math.Min(rx.Count,31)<<4) | (rx.Count==0?8u:0u) | (pendingBytes>0?1u:0u);
            if(offset==0x10) return rx.Count==0?0u:rx.Dequeue();
            return regs.TryGetValue(offset,out var v)?v:0;
        }
        public byte ReadByte(long offset) { return (byte)(ReadDoubleWord(offset&~3) >> (8*(int)(offset&3))); }
        public void WriteByte(long offset,byte value) {
            if(offset==8) { Feed(value);return; }
            var aligned=offset&~3;int shift=8*(int)(offset&3);
            WriteDoubleWord(aligned,(ReadDoubleWord(aligned)&~(255u<<shift))|((uint)value<<shift));
        }
        public void WriteDoubleWord(long offset,uint value) {
            if(offset==8) {for(int i=0;i<4;i++)Feed((byte)(value>>(8*i)));return;}
            if(offset==0x18) {if((value&1)!=0)rx.Clear();if((value&2)!=0)tx.Clear();return;}
            regs[offset]=value;
            if(offset==0) Execute(value);
        }
        private void Execute(uint command) {
            byte op=(byte)command;
            bool extended=(ReadDoubleWord(4)&1)!=0;
            int length=extended && (command&0x100)!=0?(int)((command>>13)&0x1fff):0;
            bool dual=(ReadDoubleWord(0x204)&0x80000)!=0;
            uint address=(command>>8)|(ReadDoubleWord(0x30)<<24);
            if((ReadDoubleWord(4)&1)!=0) {address=0;for(int i=0;i<Math.Min(tx.Count,3);i++)address=(address<<8)|tx[i];}
            if(seen.Add(op))this.Log(LogLevel.Info,"NOR command 0x{0:X2}, RX={1}, TX={2}",op,length,tx.Count);
            if(op==6) {status1|=2;return;}
            else if(op==0x50){statusWriteEnabled=true;return;}
            else if(op==4){status1&=0xfd;return;}
            else if(op==0x99) {status1=0;status2=0;statusWriteEnabled=false;pendingBytes=0;}
            else if(op==1 && ((status1&2)!=0 || statusWriteEnabled)) {if(tx.Count>0)status1=(byte)(tx[0]&0xfc);if(tx.Count>1)status2=tx[1];statusWriteEnabled=false;}
            else if(op==0x31 && (status1&2)!=0) {if(tx.Count>0)status2=tx[0];status1&=0xfd;}
            if(op==0x20 || op==0x52 || op==0xd8 || op==0x60 || op==0xc7) {
                if((status1&2)!=0) {
                    uint size=op==0x20?4096u:op==0x52?32768u:op==0xd8?65536u:flashSize;
                    if(dual && size<flashSize)size*=2;
                    uint start=address&~(size-1);
                    if(start+size<=flashSize)for(uint i=0;i<size;i++)machine.GetSystemBus(this).WriteByte(flashBase+start+i,0xff);
                    status1&=0xfd;
                }
            }
            else if(op==2 || op==0x32 || op==0xa2) {
                if((status1&2)!=0) {
                    pendingAddress=address;
                    pendingBytes=(int)((ReadDoubleWord(4)>>12)&0x1fff);
                    status1|=1;
                    var buffered=tx.ToArray();tx.Clear();
                    foreach(var value in buffered) {if(pendingBytes==0)break;Feed(value);}
                    if(pendingBytes==0)status1&=0xfc;
                }
                return;
            }
            for(int i=0;i<length;i++) {
                byte v=0;
                if(op==0x9f)v=(byte)(jedec>>(16-8*((dual?i/2:i)%3)));
                else if(op==5)v=status1;
                else if(op==0x35)v=status2;
                else if(op==3 || op==0xb || op==0x6b || op==0xeb)v=machine.GetSystemBus(this).ReadByte(flashBase+((address+(uint)i)&readMask));
                // Dual-chip register reads pack a nibble from each die into each byte.
                // The stock norflash_dual_chip_read_reg_ex deinterleaves these nibbles.
                if(dual && (op==0x9f || op==5 || op==0x35 || op==0x4b))
                    v=(byte)((((i&1)==0 ? v>>4 : v&15))*17);
                rx.Enqueue(v);
            }
            tx.Clear();
        }
        private void Feed(byte value) {
            if(pendingBytes==0) {if(tx.Count<8192)tx.Add(value);return;}
            if(pendingAddress<flashSize) {
                var bus=machine.GetSystemBus(this);
                uint mapped=flashBase+pendingAddress;
                bus.WriteByte(mapped,(byte)(bus.ReadByte(mapped)&value));
            }
            pendingAddress++;pendingBytes--;
            if(pendingBytes==0)status1&=0xfc;
        }
        private uint pendingAddress;
        private int pendingBytes;
        public void Reset(){regs.Clear();tx.Clear();rx.Clear();seen.Clear();status1=status2=0;statusWriteEnabled=false;pendingBytes=0;}
        public long Size=>0x1000;
        private readonly IMachine machine;
        private readonly uint jedec,flashBase,flashSize,readMask;
        private byte status1,status2;
        private bool statusWriteEnabled;
        private readonly Dictionary<long,uint> regs=new Dictionary<long,uint>();
        private readonly List<byte> tx=new List<byte>();
        private readonly Queue<byte> rx=new Queue<byte>();
        private readonly HashSet<byte> seen=new HashSet<byte>();
    }
}
