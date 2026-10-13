// Inferred from firmware MMIO accesses. Not a timing-accurate silicon model.
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Time;
using Antmicro.Renode.Peripherals.CPU;
using Antmicro.Renode.Peripherals.Timers;

namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public sealed class BES1700_ClockControl : IDoubleWordPeripheral, IKnownSize
    {
        public BES1700_ClockControl(IMachine machine, bool alwaysOn = false, CortexM bluetoothCpu = null, CortexM bluetoothHostCpu = null)
        {
            APReceive0=apRx[0];APReceive1=apRx[1];APReceive2=apRx[2];APReceive3=apRx[3];
            APTransmit0=apTx[0];APTransmit1=apTx[1];APTransmit2=apTx[2];APTransmit3=apTx[3];
            BTCReceive0=btRx[0];BTCReceive1=btRx[1];BTCReceive2=btRx[2];BTCReceive3=btRx[3];
            BTCTransmit0=btTx[0];BTCTransmit1=btTx[1];BTCTransmit2=btTx[2];BTCTransmit3=btTx[3];
            BTHAPReceive0=bthApRx[0];BTHAPReceive1=bthApRx[1];BTHAPTransmit0=bthApTx[0];BTHAPTransmit1=bthApTx[1];
            BTHReceive0=bthRx[0];BTHReceive1=bthRx[1];BTHTransmit0=bthTx[0];BTHTransmit1=bthTx[1];
            this.alwaysOn = alwaysOn;
            this.bluetoothCpu = bluetoothCpu;this.bluetoothHostCpu = bluetoothHostCpu;this.machine=machine;
            counter = new LimitTimer(machine.ClockSource, alwaysOn ? 16384UL : 6000000UL, this, "clock", uint.MaxValue,
                direction: Direction.Ascending, enabled: true, eventEnabled: false, autoUpdate: true);
        }
        public uint ReadDoubleWord(long offset)
        {
            if(!alwaysOn && (offset==0x140 || offset==0x144)) {
                lock(ipcLock) return offset==0x140?(apRxMask<<8)|(apTxMask<<12)|(btToAp<<24)|(apAck<<28):0;
            }
            if(offset == (alwaysOn ? 0x50 : 0x288)) return (uint)counter.Value;
            if(!alwaysOn && (offset==0xec || offset==0x224 || offset==0x1f4)) return ReadHostIPC(offset);
            long firstLock = alwaysOn ? 0x100 : 0xc0;
            int lockCount = alwaysOn ? 16 : 8;
            if(offset >= firstLock && offset < firstLock + lockCount*4) {
                int index = (int)((offset-firstLock)/4);
                if(locks[index]) return 0;
                locks[index] = true; return 1; // read-to-acquire memory semaphore
            }
            return registers.TryGetValue(offset, out var value) ? value : 0;
        }
        public void WriteDoubleWord(long offset, uint value)
        {
            if(!alwaysOn && (offset==0x140 || offset==0x144)) {
                lock(ipcLock) {
                    if(offset==0x140) {
                        apToBt|=(value>>4)&15;apRxMask|=(value>>8)&15;apTxMask|=(value>>12)&15;
                    } else {
                        apAck&=~(value&15);
                        uint consumed=(value>>4)&15;
                        apAck|=apToBt&consumed;apToBt&=~consumed;
                        apRxMask&=~((value>>8)&15);apTxMask&=~((value>>12)&15);
                    }
                    UpdateIPC();return;
                }
            }
            long firstLock = alwaysOn ? 0x100 : 0xc0;
            int lockCount = alwaysOn ? 16 : 8;
            if(offset >= firstLock && offset < firstLock + lockCount*4) { if((value&1)!=0) locks[(offset-firstLock)/4] = false; return; }
            if(!alwaysOn && (offset==0x98 || offset==0x9c || offset==0x1f4 || offset==0x1f8)) { WriteHostIPC(offset,value); return; }
            registers[offset] = value;
            if(alwaysOn && offset==0xcc && (value&0x80)!=0 && bluetoothCpu!=null) {
                uint vector=registers.TryGetValue(0x168,out var boot)?boot&~0x7fu:0;
                var bus=machine.GetSystemBus(this);
                uint sp=bus.ReadDoubleWord(vector),pc=bus.ReadDoubleWord(vector+4);
                bluetoothCpu.VectorTableOffset=vector;
                bluetoothCpu.SP=sp;bluetoothCpu.PC=pc;
                bluetoothCpu.IsHalted=false;
                this.Log(LogLevel.Info,"BTC released: vector={0:X}, SP={1:X}, PC={2:X}",vector,sp,pc);
            }
            if(alwaysOn && offset==0xcc && (value&0x200)!=0 && bluetoothHostCpu!=null) {
                uint vector=registers.TryGetValue(0xb8,out var bootHost)?bootHost&~0x7fu:0;
                var bus=machine.GetSystemBus(this);
                uint sp=bus.ReadDoubleWord(vector),pc=bus.ReadDoubleWord(vector+4);
                bluetoothHostCpu.VectorTableOffset=vector;
                bluetoothHostCpu.SP=sp;bluetoothHostCpu.PC=pc;
                bluetoothHostCpu.IsHalted=false;
                this.Log(LogLevel.Info,"BTH released: vector={0:X}, SP={1:X}, PC={2:X}",vector,sp,pc);
            }
            // hal_cmu_sys_module_init requests two power/clock domains and polls their acknowledgements.
            if(!alwaysOn && offset == 0x1a0) registers[0x1ac] = (value & 0x800u) | ((value & 0x04000000u) << 1);
        }
        // AP and BTC exchange actual shared-memory descriptors. These registers only
        // route request/acknowledgement lines; they never fabricate HCI payloads.
        public uint ReadBluetoothIPC(long offset) {
            lock(ipcLock) {
                if(offset==0x50)return ((btToAp&3)<<18)|((btAck&3)<<16);
                if(offset==0xa0)return ((btRxMask&3)<<18)|((btTxMask&3)<<16);
                if(offset==0xac)return ((btToAp&12)<<16)|((btRxMask&12)<<18)|((btTxMask&12)<<20);
                return 0;
            }
        }
        public void WriteBluetoothIPC(long offset,uint value) {
            lock(ipcLock) {
                if(offset==0xa0) {btRxMask|=(value>>18)&3;btTxMask|=(value>>16)&3;}
                else if(offset==0xa4) {btRxMask&=~((value>>18)&3);btTxMask&=~((value>>16)&3);}
                else if(offset==0x50)btToAp|=(value>>18)&3;
                else if(offset==0x54) {
                    btAck&=~((value>>16)&3);
                    uint consumed=(value>>18)&3;
                    btAck|=btToAp&consumed;btToAp&=~consumed;
                }
                else if(offset==0xac) {btToAp|=(value>>16)&12;btRxMask|=(value>>18)&12;btTxMask|=(value>>20)&12;}
                else if(offset==0xb0) {
                    btRxMask&=~((value>>18)&12);btTxMask&=~((value>>20)&12);
                    btAck&=~((value>>14)&12);
                    uint consumed=(value>>16)&12;
                    btAck|=btToAp&consumed;btToAp&=~consumed;
                }
                UpdateIPC();
            }
        }
        // AP (M55C0) <-> BTH mailbox, from hal_sys2bth_* (AP) and the matching BTH HAL:
        //  AP  +0x98  bit16+ch raise request to BTH        BTH +0x134 raise request to AP
        //  AP  +0x9c  bit16+ch clear BTH's view of AP req   BTH +0x138 (written by the receiver = rx done)
        //             bit ch   clear own tx-done flag
        //  AP  +0x1f4/+0x1f8 mask set/clear (bit ch rx, bit16+ch tx-done)  BTH +0x168/+0x16c
        //  AP  +0xec  bit16+ch request from BTH pending     BTH +0x174 request from AP pending
        //  AP  +0x224 bit16+ch own request was consumed     BTH +0x170
        // Only the M55C0 link (bits 16/17, 0/1) is routed; BTH bits 18/19 belong to the
        // M55C1 link, whose core is not emulated. IRQ numbers come from the firmware's
        // rmt_ipc config tables (cfg+0x20 rx list, cfg+0x24 tx-done list).
        private uint apReq,apDone,apMask,bthReq,bthDone,bthMask;
        private uint ReadHostIPC(long offset) {
            lock(ipcLock) {
                if(offset==0xec) return bthReq<<16;
                if(offset==0x224) return apDone<<16;
                return apMask;
            }
        }
        private int ipcLogBudget=200;
        private void LogIPC(string side,long offset,uint value) {
            if(ipcLogBudget-->0) this.Log(LogLevel.Info,"BTH-IPC {0} +0x{1:X} = 0x{2:X} (apReq={3} apDone={4} apMask={5:X} bthReq={6} bthDone={7} bthMask={8:X})",side,offset,value,apReq,apDone,apMask,bthReq,bthDone,bthMask);
        }
        private void WriteHostIPC(long offset,uint value) {
            LogIPC("AP",offset,value);
            lock(ipcLock) {
                uint hi=(value>>16)&3, lo=value&3;
                if(offset==0x98) apReq|=hi;
                else if(offset==0x9c) { bthDoneFrom(ref apReq,ref apDone,hi); apDone&=~lo; }
                else if(offset==0x1f4) apMask|=value&0x30003;
                else apMask&=~(value&0x30003);
                UpdateIPC();
            }
        }
        public uint ReadBthIPC(long offset) {
            lock(ipcLock) {
                if(offset==0x174) return apReq<<16;
                if(offset==0x170) return bthDone<<16;
                return bthMask;
            }
        }
        public void WriteBthIPC(long offset,uint value) {
            LogIPC("BTH",offset,value);
            lock(ipcLock) {
                uint hi=(value>>16)&3, lo=value&3;
                if(offset==0x134) bthReq|=hi;
                else if(offset==0x138) { bthDoneFrom(ref bthReq,ref bthDone,hi); bthDone&=~lo; }
                else if(offset==0x168) bthMask|=value&0x30003;
                else if(offset==0x16c) bthMask&=~(value&0x30003);
                UpdateIPC();
            }
        }
        private static void bthDoneFrom(ref uint req,ref uint done,uint consumed) { done|=req&consumed; req&=~consumed; }
        private void UpdateIPC() {
            for(int i=0;i<2;i++) {
                uint bit=1u<<i;
                bthApRx[i].Set((bthReq&apMask&bit)!=0); bthApTx[i].Set((apDone&(apMask>>16)&bit)!=0);
                bthRx[i].Set((apReq&bthMask&bit)!=0); bthTx[i].Set((bthDone&(bthMask>>16)&bit)!=0);
            }
            for(int i=0;i<4;i++) {
                uint bit=1u<<i;
                apRx[i].Set((btToAp&apRxMask&bit)!=0);apTx[i].Set((apAck&apTxMask&bit)!=0);
                btRx[i].Set((apToBt&btRxMask&bit)!=0);btTx[i].Set((btAck&btTxMask&bit)!=0);
            }
        }
        public GPIO BTHAPReceive0 {get;private set;} public GPIO BTHAPReceive1 {get;private set;}
        public GPIO BTHAPTransmit0 {get;private set;} public GPIO BTHAPTransmit1 {get;private set;}
        public GPIO BTHReceive0 {get;private set;} public GPIO BTHReceive1 {get;private set;}
        public GPIO BTHTransmit0 {get;private set;} public GPIO BTHTransmit1 {get;private set;}
        private readonly GPIO[] bthApRx={new GPIO(),new GPIO()}, bthApTx={new GPIO(),new GPIO()}, bthRx={new GPIO(),new GPIO()}, bthTx={new GPIO(),new GPIO()};
        public GPIO APReceive0 {get;private set;} public GPIO APReceive1 {get;private set;}
        public GPIO APReceive2 {get;private set;} public GPIO APReceive3 {get;private set;}
        public GPIO APTransmit0 {get;private set;} public GPIO APTransmit1 {get;private set;}
        public GPIO APTransmit2 {get;private set;} public GPIO APTransmit3 {get;private set;}
        public GPIO BTCReceive0 {get;private set;} public GPIO BTCReceive1 {get;private set;}
        public GPIO BTCReceive2 {get;private set;} public GPIO BTCReceive3 {get;private set;}
        public GPIO BTCTransmit0 {get;private set;} public GPIO BTCTransmit1 {get;private set;}
        public GPIO BTCTransmit2 {get;private set;} public GPIO BTCTransmit3 {get;private set;}
        private readonly GPIO[] apRx={new GPIO(),new GPIO(),new GPIO(),new GPIO()};
        private readonly GPIO[] apTx={new GPIO(),new GPIO(),new GPIO(),new GPIO()};
        private readonly GPIO[] btRx={new GPIO(),new GPIO(),new GPIO(),new GPIO()};
        private readonly GPIO[] btTx={new GPIO(),new GPIO(),new GPIO(),new GPIO()};
        private readonly object ipcLock=new object();
        private uint apToBt,btToAp,apAck,btAck,apRxMask,apTxMask,btRxMask,btTxMask;
        public void Reset() { apToBt=btToAp=apAck=btAck=apRxMask=apTxMask=btRxMask=btTxMask=0;apReq=apDone=apMask=bthReq=bthDone=bthMask=0;UpdateIPC();registers.Clear(); Array.Clear(locks, 0, locks.Length); counter.Reset(); }
        public long Size => 0x1000;
        private readonly bool alwaysOn;
        private readonly IMachine machine;
        private readonly CortexM bluetoothCpu;
        private readonly CortexM bluetoothHostCpu;
        private readonly LimitTimer counter;
        private readonly Dictionary<long,uint> registers = new Dictionary<long,uint>();
        private readonly bool[] locks = new bool[16];
    }
}
