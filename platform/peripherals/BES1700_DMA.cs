// Functional eight-channel DMA inferred from hal_dma_* (PL080-style layout).
// Copies actual bus data. Timing and peripheral request pacing are not modeled.
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;
namespace Antmicro.Renode.Peripherals.DMA
{
    public sealed class BES1700_DMA : IDoubleWordPeripheral, IKnownSize, IGPIOReceiver
    {
        public BES1700_DMA(IMachine machine) { this.machine=machine; IRQ=new GPIO(); }
        public GPIO IRQ {get; private set;}
        public long Size=>0x1000;
        public uint ReadDoubleWord(long o) {
            if(o==0) return Masked(false)|Masked(true);
            if(o==4) return Masked(false);
            if(o==0xc) return Masked(true);
            if(o==0x14) return completed;
            if(o==0x18) return errors;
            if(o==0x1c) {uint enabled=0;for(int c=0;c<8;c++) if((Get(0x110+c*0x20)&1)!=0) enabled|=1u<<c;return enabled;}
            return Get(o);
        }
        public void WriteDoubleWord(long o,uint v) {
            if(o==8) {completed&=~v;Update();return;}
            if(o==0x10) {errors&=~v;Update();return;}
            regs[o]=v;
            if(o>=0x110 && o<=0x1f0 && (o-0x110)%0x20==0 && (v&1)!=0) Transfer((int)((o-0x110)/0x20));
        }
        public void OnGPIO(int number,bool value) {
            if(number!=0)return;
            nandReady=value;
            if(value)for(int c=0;c<8;c++)if((Get(0x110+c*0x20)&1)!=0 && (Get(0x100+c*0x20)==0x40198010 || Get(0x100+c*0x20)==0x40198008))Transfer(c);
        }
        // Peripheral-to-memory request from a device FIFO (UART RX): one byte into the enabled flow-2
        // channel whose source is that device register. Returns false when no channel is waiting.
        public bool PeripheralReceive(uint source, byte value) {
            for(int c=0;c<8;c++) {
                long b=0x100+c*0x20;
                uint config=Get(b+16);
                if((config&1)==0 || ((config>>11)&7)!=2 || Get(b)!=source) continue;
                uint ctrl=Get(b+12), count=ctrl&0xfff;
                if(count==0) continue;
                var bus=machine.GetSystemBus(this);
                uint dst=Get(b+4);
                bus.WriteByte(dst,value);
                if((ctrl&(1u<<27))!=0) regs[b+4]=dst+1;
                regs[b+12]=(ctrl&~0xfffu)|(count-1);
                if(count-1==0) {
                    if((ctrl&0x80000000u)!=0) completed|=1u<<c;
                    uint next=Get(b+8);
                    if(next!=0) { uint a=next&~3u; for(int i=0;i<4;i++) regs[b+i*4]=bus.ReadDoubleWord(a+(uint)i*4); }
                    else regs[b+16]=config&~1u;
                    Update();
                }
                return true;
            }
            return false;
        }
        private void Transfer(int channel) {
            long b=0x100+channel*0x20;
            var bus=machine.GetSystemBus(this);
            // Peripheral RX waits for a real request; never manufacture received data.
            uint flow=(Get(b+16)>>11)&7;
            if(flow!=0 && flow!=1 && flow!=5 && !(flow==2 && nandReady && (Get(b)==0x40198010 || Get(b)==0x40198008))) return;
            if(flow==2) {
                uint available=(bus.ReadDoubleWord(0x40198004)>>12)&0x1fff;
                uint requested=(Get(b+12)&0xfff)*(1u<<(int)((Get(b+12)>>18)&7));
                if(requested>available)return;
            }
            var visited=new HashSet<uint>();
            while(true) {
                uint src=Get(b),dst=Get(b+4),next=Get(b+8),ctrl=Get(b+12);
                int sw=1<<(int)((ctrl>>18)&7),dw=1<<(int)((ctrl>>21)&7);
                // Do not silently claim unsupported packing or circular requests completed.
                if(sw>4 || dw>4 || sw!=dw) {Fail(channel,"unsupported transfer width");break;}
                uint count=ctrl&0xfff;
                if(transfers++<12) this.Log(LogLevel.Info,"DMA ch={0} src={1:X} dst={2:X} count={3} flow={4}",channel,src,dst,count,flow);
                for(uint i=0;i<count;i++) {
                    if(sw==1) bus.WriteByte(dst,bus.ReadByte(src));
                    else if(sw==2) bus.WriteWord(dst,bus.ReadWord(src));
                    else bus.WriteDoubleWord(dst,bus.ReadDoubleWord(src));
                    if((ctrl&(1u<<26))!=0) src+=(uint)sw;
                    if((ctrl&(1u<<27))!=0) dst+=(uint)dw;
                }
                regs[b]=src;regs[b+4]=dst;regs[b+12]=ctrl&~0xfffu;
                if((ctrl&0x80000000u)!=0) completed|=1u<<channel;
                if(next==0) break;
                uint address=next&~3u;
                if(visited.Count>=1024 || !visited.Add(address)) {Fail(channel,"circular descriptor");break;}
                for(int i=0;i<4;i++) regs[b+i*4]=bus.ReadDoubleWord(address+(uint)i*4);
            }
            regs[b+16]=Get(b+16)&~1u;
            Update();
        }
        private void Fail(int channel,string reason) {errors|=1u<<channel;this.Log(LogLevel.Warning,"DMA channel {0}: {1}",channel,reason);}
        private uint Get(long o) {return regs.TryGetValue(o,out var v)?v:0;}
        private uint Masked(bool error) {
            uint mask=0;for(int c=0;c<8;c++) if((Get(0x110+c*0x20)&(error?0x4000u:0x8000u))!=0) mask|=1u<<c;
            return (error?errors:completed)&mask;
        }
        private void Update(){IRQ.Set((Masked(false)|Masked(true))!=0);}
        public void Reset(){regs.Clear();completed=errors=0;nandReady=false;IRQ.Unset();}
        private readonly IMachine machine;
        private readonly Dictionary<long,uint> regs=new Dictionary<long,uint>();
        private uint completed,errors;
        private int transfers;
        private bool nandReady;
    }
}
