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
        public BES1700_ClockControl(IMachine machine, bool alwaysOn = false, CortexM bluetoothCpu = null, CortexM bluetoothHostCpu = null, CortexM coreOneCpu = null)
        {
            APReceive0=apRx[0];APReceive1=apRx[1];APReceive2=apRx[2];APReceive3=apRx[3];
            APTransmit0=apTx[0];APTransmit1=apTx[1];APTransmit2=apTx[2];APTransmit3=apTx[3];
            BTCReceive0=btRx[0];BTCReceive1=btRx[1];BTCReceive2=btRx[2];BTCReceive3=btRx[3];
            BTCTransmit0=btTx[0];BTCTransmit1=btTx[1];BTCTransmit2=btTx[2];BTCTransmit3=btTx[3];
            this.alwaysOn = alwaysOn;
            this.bluetoothCpu = bluetoothCpu;this.bluetoothHostCpu = bluetoothHostCpu;this.coreOneCpu = coreOneCpu;this.machine=machine;
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
            if(!alwaysOn && offset==0x90) lock(ipcLock) return ReadCoreOneIPC();
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
                }
                UpdateIPC();return;
            }
            long firstLock = alwaysOn ? 0x100 : 0xc0;
            int lockCount = alwaysOn ? 16 : 8;
            if(offset >= firstLock && offset < firstLock + lockCount*4) { if((value&1)!=0) locks[(offset-firstLock)/4] = false; return; }
            if(!alwaysOn && (offset==0x98 || offset==0x9c || offset==0x1f4 || offset==0x1f8)) { WriteHostIPC(offset,value); return; }
            if(!alwaysOn && (offset==0x90 || offset==0x94)) { WriteCoreOneIPC(offset,value); return; }
            uint previous = registers.TryGetValue(offset, out var old) ? old : 0;
            registers[offset] = value;
            // M55C1: hal_cmu_m55c1_cpu_reset_clear writes the core-1-view vector to AON +0xb4 and
            // sets +0x1a4 bit1; hal_cmu_m55c1_start_cpu clears bit1 to let it run.
            if(alwaysOn && offset==0x1a4 && (previous&2)!=0 && (value&2)==0 && coreOneCpu!=null) {
                uint vector=registers.TryGetValue(0xb4,out var v1)?v1&~0x7fu:0;
                var bus=machine.GetSystemBus(this);
                uint sp=bus.ReadDoubleWord(vector,coreOneCpu),pc=bus.ReadDoubleWord(vector+4,coreOneCpu);
                coreOneCpu.VectorTableOffset=vector;coreOneCpu.SP=sp;coreOneCpu.PC=pc;coreOneCpu.IsHalted=false;
                this.Log(LogLevel.Info,"M55C1 released: vector={0:X}, SP={1:X}, PC={2:X}",vector,sp,pc);
            }
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
            // FORCE_LP (+0x1a0) / FORCE_ACK (+0x1ac): hal_cmu_axi_bus_port_force_lp requests
            // bus ports (DSP 0x80, LCDC 0x8, GPU, ...) and waits for the same bits in ACK.
            // hal_cmu_sys_module_init additionally polls ACK bit 27 for request bit 26.
            if(!alwaysOn && offset == 0x1a0) registers[0x1ac] = value | ((value & 0x04000000u) << 1);
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
            }
            UpdateIPC();
        }
        // AP (M55C0) <-> BTH mailbox, from hal_sys2bth_* (AP) and the matching BTH HAL:
        //  AP  +0x98  bit16+ch raise request to BTH        BTH +0x134 raise request to AP
        //  AP  +0x9c  bit16+ch clear BTH's view of AP req   BTH +0x138 (written by the receiver = rx done)
        //             bit ch   clear own tx-done flag
        //  AP  +0x1f4/+0x1f8 mask set/clear (bit ch rx, bit16+ch tx-done)  BTH +0x168/+0x16c
        //  AP  +0xec  bit16+ch request from BTH pending     BTH +0x174 request from AP pending
        //  AP  +0x224 bit16+ch own request was consumed     BTH +0x170
        // The register pair is shared by several links, one 2-bit lane group each:
        // lanes 0/1 = AP(M55C0)<->BTH, lanes 2/3 = M55C1<->BTH (the M55C1 HAL shifts by 2),
        // lanes 10/11 = M55C1<->a core that is not emulated. A-side IRQs of lanes 0/1 go to
        // the AP NVIC, lanes 2/3 to the M55C1 NVIC; B-side IRQs go to the BTH NVIC.
        // IRQ numbers come from the rmt_ipc config tables (cfg+0x20 rx list, cfg+0x24 tx list).
        private uint apReq,apDone,apMask,bthReq,bthDone,bthMask;
        private uint ReadHostIPC(long offset) {
            lock(ipcLock) {
                if(offset==0xec) return bthReq<<16;
                if(offset==0x224) return apDone<<16;
                return apMask;
            }
        }
        private int ipcLogBudget=60, c1LogBudget=200;
        private void LogIPC(string side,long offset,uint value) {
            if(ipcLogBudget-->0) this.Log(LogLevel.Info,"BTH-IPC {0} +0x{1:X} = 0x{2:X} (apReq={3} apDone={4} apMask={5:X} bthReq={6} bthDone={7} bthMask={8:X})",side,offset,value,apReq,apDone,apMask,bthReq,bthDone,bthMask);
        }
        private void WriteHostIPC(long offset,uint value) {
            LogIPC("AP",offset,value);
            lock(ipcLock) {
                uint hi=(value>>16)&0xffff, lo=value&0xffff;
                if(offset==0x98) apReq|=hi;
                else if(offset==0x9c) { bthDoneFrom(ref apReq,ref apDone,hi); apDone&=~lo; }
                else if(offset==0x1f4) apMask|=value;
                else apMask&=~value;
            }
            UpdateIPC();
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
                uint hi=(value>>16)&0xffff, lo=value&0xffff;
                if(offset==0x134) bthReq|=hi;
                else if(offset==0x138) { bthDoneFrom(ref bthReq,ref bthDone,hi); bthDone&=~lo; }
                else if(offset==0x168) bthMask|=value;
                else if(offset==0x16c) bthMask&=~value;
            }
            UpdateIPC();
        }
        private static void bthDoneFrom(ref uint req,ref uint done,uint consumed) { done|=req&consumed; req&=~consumed; }
        // Line levels are computed under ipcLock but driven after releasing it: raising an
        // NVIC line from one CPU thread while another CPU thread waits for ipcLock in an MMIO
        // access deadlocks Renode otherwise.
        private void UpdateIPC() {
            var levels=new bool[40];
            lock(ipcLock) {
                for(int i=0;i<4;i++) {
                    uint bit=1u<<i;
                    levels[i]=(bthReq&apMask&bit)!=0; levels[4+i]=(apDone&(apMask>>16)&bit)!=0;
                    levels[8+i]=(apReq&bthMask&bit)!=0; levels[12+i]=(bthDone&(bthMask>>16)&bit)!=0;
                    levels[24+i]=(btToAp&apRxMask&bit)!=0; levels[28+i]=(apAck&apTxMask&bit)!=0;
                    levels[32+i]=(apToBt&btRxMask&bit)!=0; levels[36+i]=(btAck&btTxMask&bit)!=0;
                }
                for(int i=0;i<2;i++) {
                    levels[16+i]=(coreOneMailbox&(1u<<(21+i)))!=0; levels[18+i]=(coreOneMailbox&(1u<<(18+i)))!=0;
                    levels[20+i]=(coreOneMailbox&(1u<<(15+i)))!=0; levels[22+i]=(coreOneMailbox&(1u<<(12+i)))!=0;
                }
            }
            for(int i=0;i<4;i++) {
                c1BtRx[i].Set(levels[24+i]); c1BtTx[i].Set(levels[28+i]);
                laneARx[i].Set(levels[i]); laneATx[i].Set(levels[4+i]); laneBRx[i].Set(levels[8+i]); laneBTx[i].Set(levels[12+i]);
                apRx[i].Set(levels[24+i]); apTx[i].Set(levels[28+i]); btRx[i].Set(levels[32+i]); btTx[i].Set(levels[36+i]);
            }
            for(int i=0;i<2;i++) { c2aRx[i].Set(levels[16+i]); c2aTx[i].Set(levels[18+i]); a2cRx[i].Set(levels[20+i]); a2cTx[i].Set(levels[22+i]); }
            uint dsp; lock(ipcLock) dsp=coreOneMailbox;
            for(int i=0;i<2;i++) { d2aRx[i].Set((dsp&(1u<<(9+i)))!=0); d2aTx[i].Set((dsp&(1u<<(6+i)))!=0); }
        }
        public GPIO LaneARx0=>laneARx[0]; public GPIO LaneARx1=>laneARx[1]; public GPIO LaneARx2=>laneARx[2]; public GPIO LaneARx3=>laneARx[3];
        public GPIO LaneATx0=>laneATx[0]; public GPIO LaneATx1=>laneATx[1]; public GPIO LaneATx2=>laneATx[2]; public GPIO LaneATx3=>laneATx[3];
        public GPIO LaneBRx0=>laneBRx[0]; public GPIO LaneBRx1=>laneBRx[1]; public GPIO LaneBRx2=>laneBRx[2]; public GPIO LaneBRx3=>laneBRx[3];
        public GPIO LaneBTx0=>laneBTx[0]; public GPIO LaneBTx1=>laneBTx[1]; public GPIO LaneBTx2=>laneBTx[2]; public GPIO LaneBTx3=>laneBTx[3];
        private static GPIO[] Lines(int n){var a=new GPIO[n];for(int i=0;i<n;i++)a[i]=new GPIO();return a;}
        private readonly GPIO[] laneARx=Lines(4), laneATx=Lines(4), laneBRx=Lines(4), laneBTx=Lines(4);
        // AP <-> M55C1 ("mcu2cp") mailbox: one shared register, +0x90 write = set bits,
        // +0x94 write = clear bits, read = value (hal_mcu2cp_* on the AP and the matching
        // code in nuttx_apc1 use it this way). Bits, for channel ch:
        //   15+ch AP->C1 pending   (AP peer_tx sets; C1 rx_resume/suspend set/clear)
        //   12+ch C1 tx consumed   (AP rx_done sets; C1 local_tx_clear clears)
        //   21+ch C1->AP pending   (C1 peer_tx sets; AP rx_resume/suspend set/clear)
        //   18+ch AP tx consumed   (C1 rx_done sets; AP local_tx_clear clears)
        // Bits 0..10 are the AP<->HiFi4 DSP link (hal_mcu2cp_*: DSP cfg 0x18299620), same scheme 12 bits lower:
        //    3+ch AP->DSP pending  (AP peer_tx sets; DSP clears when it takes the message)
        //    0+ch DSP tx consumed  (AP rx_done sets; DSP clears)
        //    9+ch DSP->AP pending  (DSP peer_tx sets; AP rx_resume/suspend set/clear)  -> AP IRQ 76/77
        //    6+ch AP tx consumed   (DSP rx_done sets; AP local_tx_clear clears)       -> AP IRQ 79/80
        // The DSP side is BES1700_HiFi4 (DspMailbox/DspSet/DspClear).
        public GPIO DspToAPRx0=>d2aRx[0]; public GPIO DspToAPRx1=>d2aRx[1];
        public GPIO DspToAPTx0=>d2aTx[0]; public GPIO DspToAPTx1=>d2aTx[1];
        private readonly GPIO[] d2aRx=Lines(2), d2aTx=Lines(2);
        public Action DspMailboxWritten;
        public uint DspMailbox { get { lock(ipcLock) return coreOneMailbox & 0x7ffu; } }
        public void DspSet(uint bits) { lock(ipcLock) coreOneMailbox|=bits&0x7ffu; UpdateIPC(); }
        public void DspClear(uint bits) { lock(ipcLock) coreOneMailbox&=~(bits&0x7ffu); UpdateIPC(); }
        public GPIO CoreOneToAPRx0=>c2aRx[0]; public GPIO CoreOneToAPRx1=>c2aRx[1];
        public GPIO CoreOneToAPTx0=>c2aTx[0]; public GPIO CoreOneToAPTx1=>c2aTx[1];
        public GPIO APToCoreOneRx0=>a2cRx[0]; public GPIO APToCoreOneRx1=>a2cRx[1];
        public GPIO APToCoreOneTx0=>a2cTx[0]; public GPIO APToCoreOneTx1=>a2cTx[1];
        private readonly GPIO[] c2aRx=Lines(2), c2aTx=Lines(2), a2cRx=Lines(2), a2cTx=Lines(2);
        private uint coreOneMailbox;
        private uint ReadCoreOneIPC() { return coreOneMailbox; }
        private void WriteCoreOneIPC(long offset,uint value) {
            lock(ipcLock) {
                if(offset==0x90) coreOneMailbox|=value; else coreOneMailbox&=~value;
                if(c1LogBudget-->0) {
                    bool fromCoreOne=coreOneCpu!=null && machine.SystemBus.TryGetCurrentCPU(out var current) && current==coreOneCpu;
                    this.Log(LogLevel.Info,"C1-IPC {0} {1} 0x{2:X} -> 0x{3:X}",fromCoreOne?"C1":"AP",offset==0x90?"set":"clr",value,coreOneMailbox);
                }
            }
            UpdateIPC();
            if((value&0x7ffu)!=0) DspMailboxWritten?.Invoke();
        }
        // The AP<->BTC "intersys" lanes are used first by the AP (btdrv init) and then by the
        // M55C1 BT stack (same HAL, same bits); the same levels are also offered to the M55C1 NVIC.
        public GPIO CoreOneBTReceive0=>c1BtRx[0]; public GPIO CoreOneBTReceive1=>c1BtRx[1]; public GPIO CoreOneBTReceive2=>c1BtRx[2]; public GPIO CoreOneBTReceive3=>c1BtRx[3];
        public GPIO CoreOneBTTransmit0=>c1BtTx[0]; public GPIO CoreOneBTTransmit1=>c1BtTx[1]; public GPIO CoreOneBTTransmit2=>c1BtTx[2]; public GPIO CoreOneBTTransmit3=>c1BtTx[3];
        private readonly GPIO[] c1BtRx=Lines(4), c1BtTx=Lines(4);
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
        public void Reset() { apToBt=btToAp=apAck=btAck=apRxMask=apTxMask=btRxMask=btTxMask=0;apReq=apDone=apMask=bthReq=bthDone=bthMask=0;coreOneMailbox=0;UpdateIPC();registers.Clear(); Array.Clear(locks, 0, locks.Length); counter.Reset(); }
        public long Size => 0x1000;
        private readonly bool alwaysOn;
        private readonly IMachine machine;
        private readonly CortexM bluetoothCpu;
        private readonly CortexM bluetoothHostCpu;
        private readonly CortexM coreOneCpu;
        private readonly LimitTimer counter;
        private readonly Dictionary<long,uint> registers = new Dictionary<long,uint>();
        private readonly bool[] locks = new bool[16];
    }
}
