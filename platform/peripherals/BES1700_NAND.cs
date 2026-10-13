// SPI NAND/controller profile inferred from the AP firmware's device table.
// C8 81 C8, 2048+128 bytes/page, 64 pages/block, 1024 blocks.
// Sparse erased medium: no claim that this contains the device's filesystem.
// Timing, wear and ECC faults are not implemented. RX requests carry real cache bytes.
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;
namespace Antmicro.Renode.Peripherals.SPI
{
    public sealed class BES1700_NAND : IDoubleWordPeripheral, IBytePeripheral, IKnownSize
    {
        public BES1700_NAND(IMachine machine) { RxRequest=new GPIO(); Reset(); }
        public GPIO RxRequest {get; private set;}
        public long Size => 0x1000;
        public uint ReadDoubleWord(long offset) {
            if(offset==0xc) return (31u<<9) | ((uint)Math.Min(rx.Count,31)<<4) | (rx.Count==0?8u:0u) | (pendingLoad?1u:0u);
            if(offset==0x10 || offset==8) {uint value=0;int width=1<<(int)((Get(0x1c)>>16)&3);for(int i=0;i<Math.Min(width,4);i++)value|=(uint)Pop()<<(8*i);return value;}
            return Get(offset);
        }
        public byte ReadByte(long offset) {
            if(offset==0x10 || offset==8) return Pop();
            return (byte)(ReadDoubleWord(offset&~3)>>(8*(int)(offset&3)));
        }
        private byte Pop() {byte value=rx.Count==0?(byte)0:rx.Dequeue();if(rx.Count==0)RxRequest.Unset();return value;}
        private uint Get(long offset) {return regs.TryGetValue(offset,out var value)?value:0;}
        public void WriteByte(long offset,byte value) {
            if(offset==8) {Feed(value);return;}
            int shift=8*(int)(offset&3);long aligned=offset&~3;
            WriteDoubleWord(aligned,(Get(aligned)&~(255u<<shift))|((uint)value<<shift));
        }
        public void WriteDoubleWord(long offset,uint value) {
            if(offset==8) {for(int i=0;i<4;i++)Feed((byte)(value>>(8*i)));return;}
            if(offset==0x18) {if((value&1)!=0){rx.Clear();RxRequest.Unset();}if((value&2)!=0)tx.Clear();return;}
            regs[offset]=value;
            if(offset==0) Execute(value);
        }
        private void Execute(uint command) {
            byte op=(byte)command;
            bool extended=(Get(4)&1)!=0;
            int rxLength=extended && (command&0x100)!=0?(int)((command>>13)&0x1fff):0;
            int txLength=(int)((Get(4)>>12)&0x1fff);
            uint address=command>>8;
            if(seen.Add(op))this.Log(LogLevel.Info,"NAND command {0:X2}, TX={1}/{2}, RX={3}",op,tx.Count,txLength,rxLength);
            if(op==6){features[0xc0]|=2;return;}
            if((op==2 || op==0x32 || op==0x84 || op==0x34) && tx.Count<txLength) {
                pendingLoad=true;pendingCommand=command;return;
            }
            switch(op) {
            case 0xff: ResetDevice();break;
            case 0x06: features[0xc0]|=2;break;
            case 0x04: features[0xc0]&=0xfd;break;
            case 0x9f:
                byte[] id={0xc8,0x81,0xc8};
                for(int i=0;i<rxLength;i++)rx.Enqueue(i<3?id[i]:(byte)0xff);
                break;
            case 0x0f:
                for(int i=0;i<rxLength;i++)rx.Enqueue(tx.Count>0?features[tx[0]]:(byte)0xff);
                break;
            case 0x1f:
                if(tx.Count>=2 && tx[0]!=0xc0)features[tx[0]]=tx[1];
                break;
            case 0x13:
                FillErased(cache);
                if(address<PageCount && pages.TryGetValue(address,out var page))Array.Copy(page,cache,PageSize);
                features[0xc0]&=0x0f;
                break;
            case 0x03: case 0x0b: case 0x3b: case 0x6b: case 0xbb: case 0xeb:
                int column=extended?(tx.Count>=2?(tx[0]<<8)|tx[1]:0):(int)(address&0xffff);
                if(!extended)rxLength=(int)((Get(4)>>12)&0x1fff);
                for(int i=0;i<rxLength;i++)rx.Enqueue(column+i<PageSize?cache[column+i]:(byte)0xff);
                break;
            case 0x02: case 0x32: case 0x84: case 0x34:
                if(op==0x02 || op==0x32)FillErased(cache);
                if(!extended || tx.Count>=2) {
                    int start=extended?(tx[0]<<8)|tx[1]:(int)(address&0xffff);
                    int skip=extended?2:0;
                    for(int i=skip;i<Math.Min(tx.Count,txLength) && start+i-skip<PageSize;i++)cache[start+i-skip]=tx[i];
                }
                break;
            case 0x10:
                if((features[0xc0]&2)==0 || address>=PageCount || (features[0xa0]&0x38)!=0)features[0xc0]|=8;
                else {
                    if(!pages.TryGetValue(address,out var target)){target=new byte[PageSize];FillErased(target);pages[address]=target;}
                    for(int i=0;i<PageSize;i++)target[i]&=cache[i];
                    features[0xc0]&=0xf7;
                }
                features[0xc0]&=0xfd;break;
            case 0xd8:
                if((features[0xc0]&2)==0 || address>=PageCount || (features[0xa0]&0x38)!=0)features[0xc0]|=4;
                else {for(uint i=address&~63u;i<(address&~63u)+64;i++)pages.Remove(i);features[0xc0]&=0xfb;}
                features[0xc0]&=0xfd;break;
            default:
                this.Log(LogLevel.Warning,"Unsupported NAND opcode {0:X2}",op);
                for(int i=0;i<rxLength;i++)rx.Enqueue(0xff);
                break;
            }
            tx.Clear();
            RxRequest.Set(rx.Count>0 && (Get(0x1c)&4)!=0);
        }
        private void Feed(byte value) {
            if(tx.Count<8192)tx.Add(value);
            if(pendingLoad && tx.Count>=(int)((Get(4)>>12)&0x1fff)) {
                pendingLoad=false;Execute(pendingCommand);
            }
        }
        private bool pendingLoad;
        private uint pendingCommand;
        public byte ReadCache(long offset) {return offset>=0 && offset<PageSize?cache[(int)offset]:(byte)0xff;}
        private void ResetDevice(){Array.Clear(features,0,features.Length);features[0xa0]=0x38;features[0xb0]=0x10;FillErased(cache);}
        private static void FillErased(byte[] data){for(int i=0;i<data.Length;i++)data[i]=0xff;}
        public void Reset(){regs.Clear();rx.Clear();tx.Clear();seen.Clear();pendingLoad=false;RxRequest.Unset();ResetDevice();}
        private const int PageSize=2176;
        private const uint PageCount=65536;
        private readonly Dictionary<long,uint> regs=new Dictionary<long,uint>();
        private readonly Dictionary<uint,byte[]> pages=new Dictionary<uint,byte[]>();
        private readonly byte[] cache=new byte[PageSize],features=new byte[256];
        private readonly List<byte> tx=new List<byte>();
        private readonly Queue<byte> rx=new Queue<byte>();
        private readonly HashSet<byte> seen=new HashSet<byte>();
    }
    public sealed class BES1700_NANDCache : IBytePeripheral, IDoubleWordPeripheral, IKnownSize
    {
        public BES1700_NANDCache(BES1700_NAND controller) {this.controller=controller;}
        public long Size=>0x10000;
        public byte ReadByte(long offset)=>controller.ReadCache(offset);
        public uint ReadDoubleWord(long offset){uint value=0;for(int i=0;i<4;i++)value|=(uint)ReadByte(offset+i)<<(8*i);return value;}
        public void WriteByte(long offset,byte value){this.Log(LogLevel.Warning,"Write to read-only NAND cache window");}
        public void WriteDoubleWord(long offset,uint value){this.Log(LogLevel.Warning,"Write to read-only NAND cache window");}
        public void Reset(){}
        private readonly BES1700_NAND controller;
    }
}
