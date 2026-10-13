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
        private void UpdateIPC() {
            for(int i=0;i<4;i++) {
                uint bit=1u<<i;
                apRx[i].Set((btToAp&apRxMask&bit)!=0);apTx[i].Set((apAck&apTxMask&bit)!=0);
                btRx[i].Set((apToBt&btRxMask&bit)!=0);btTx[i].Set((btAck&btTxMask&bit)!=0);
            }
        }
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
        public void Reset() { apToBt=btToAp=apAck=btAck=apRxMask=apTxMask=btRxMask=btTxMask=0;UpdateIPC();registers.Clear(); Array.Clear(locks, 0, locks.Length); counter.Reset(); }
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
