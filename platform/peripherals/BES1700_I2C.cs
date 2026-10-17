// Synopsys DesignWare APB I2C master as used by the BES AP HAL (hal_i2c_mst_read/_write poll
// STATUS/RXFLR and DATA_CMD). Transfers complete synchronously when a command is pushed:
//   DATA_CMD bit 8 = read, bit 9 = STOP after this byte, bit 10 = RESTART before this byte.
// Bytes written since the last START/RESTART are delivered to the target as one Write() when
// the direction changes, on RESTART, or at STOP; each read command fetches one byte with Read(1).
// A missing target sets TX_ABRT with ABRT_7B_ADDR_NOACK, as the controller would on an address NACK.
// Bus timing, clock stretching, arbitration and slave mode are not modelled.
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Core.Structure;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
namespace Antmicro.Renode.Peripherals.I2C
{
    public sealed class BES1700_I2C : SimpleContainer<II2CPeripheral>, IDoubleWordPeripheral, IKnownSize
    {
        public BES1700_I2C(IMachine machine) : base(machine) { IRQ = new GPIO(); Reset(); }
        public GPIO IRQ { get; }
        // Monitor: `bthI2c2 TraceTransfers true` logs every command and register access.
        public bool TraceTransfers { get; set; }
        public long Size => 0x100;

        public uint ReadDoubleWord(long offset)
        {
            if(TraceTransfers && offset != 0x70 && offset != 0x78 && offset != 0x74) this.Log(LogLevel.Info, "rd 0x{0:X2}", offset);
            switch(offset) {
                case 0x00: return con;
                case 0x04: return tar;
                case 0x10: {
                    if(rx.Count == 0) { raw |= RxUnder; Update(); return 0; }
                    var v = rx.Dequeue(); Update(); return v;
                }
                case 0x2c: return Stat();
                case 0x30: return mask;
                case 0x34: return Raw();
                case 0x38: return rxTl;
                case 0x3c: return txTl;
                case 0x40: raw &= ~(RxUnder | RxOver | TxOver | RdReq | TxAbrt | RxDone | Activity | StopDet | StartDet | GenCall); abortSource = 0; Update(); return 0;
                case 0x44: return Clear(RxUnder);
                case 0x48: return Clear(RxOver);
                case 0x4c: return Clear(TxOver);
                case 0x50: return Clear(RdReq);
                case 0x54: abortSource = 0; return Clear(TxAbrt);
                case 0x58: return Clear(RxDone);
                case 0x5c: return Clear(Activity);
                case 0x60: return Clear(StopDet);
                case 0x64: return Clear(StartDet);
                case 0x68: return Clear(GenCall);
                case 0x6c: return enable;
                case 0x70: // ACTIVITY=0, TFNF=1, TFE=1, RFNE, RFF, MST_ACTIVITY=0
                    return 0x6u | (rx.Count > 0 ? 0x8u : 0) | (rx.Count >= FifoDepth ? 0x10u : 0);
                case 0x74: return 0;                       // TXFLR: commands complete immediately
                case 0x78: return (uint)rx.Count;          // RXFLR
                case 0x7c: return sdaHold;
                case 0x80: return abortSource;
                case 0x88: return dmaCr;
                case 0x8c: return dmaTdlr;
                case 0x90: return dmaRdlr;
                case 0x9c: return enable & 1;              // ENABLE_STATUS.IC_EN
                case 0xf4: return ((FifoDepth - 1u) << 16) | ((FifoDepth - 1u) << 8) | 0x6eu; // COMP_PARAM_1
                case 0xf8: return 0x3230302a;               // COMP_VERSION "2.00*"
                case 0xfc: return 0x44570140;               // COMP_TYPE
                default: return regs.TryGetValue(offset, out var r) ? r : 0;
            }
        }

        public void WriteDoubleWord(long offset, uint value)
        {
            if(TraceTransfers && offset != 0x10) this.Log(LogLevel.Info, "wr 0x{0:X2} = 0x{1:X}", offset, value);
            switch(offset) {
                case 0x00: con = value; break;
                case 0x04: tar = value & 0x3ff; break;
                case 0x10: Command(value); break;
                case 0x30: mask = value & 0xfff; Update(); break;
                case 0x38: rxTl = value & 0xff; Update(); break;
                case 0x3c: txTl = value & 0xff; Update(); break;
                case 0x6c:
                    if((value & 1) == 0 && (enable & 1) != 0) EndTransfer(false);
                    if((value & 2) != 0) { EndTransfer(false); raw |= TxAbrt; abortSource |= 1u << 16; } // ABORT
                    enable = value & 1; if(enable == 0) rx.Clear(); Update(); break;
                case 0x7c: sdaHold = value; break;
                case 0x88: dmaCr = value; break;
                case 0x8c: dmaTdlr = value; break;
                case 0x90: dmaRdlr = value; break;
                default: regs[offset] = value; break;
            }
        }

        public override void Reset()
        {
            con = 0x7f; tar = 0x55; mask = 0x8ff; rxTl = 0; txTl = 0; enable = 0; raw = 0; abortSource = 0;
            sdaHold = 1; dmaCr = 0; dmaTdlr = 0; dmaRdlr = 0; rx.Clear(); pending.Clear(); target = null; inTransfer = false;
            regs.Clear(); IRQ.Unset();
        }

        private void Command(uint value)
        {
            if((enable & 1) == 0) { raw |= TxOver; Update(); return; }
            bool read = (value & 0x100) != 0, stop = (value & 0x200) != 0, restart = (value & 0x400) != 0;
            if(TraceTransfers) this.Log(LogLevel.Info, "cmd tar=0x{0:X2} {1} {2}{3}{4}", tar & 0x7f, read ? "R" : "W 0x" + (value & 0xff).ToString("X2"), stop ? "STOP " : "", restart ? "RESTART " : "", (enable & 1) == 0 ? "(disabled)" : "");
            if(!inTransfer) Start();
            else if(restart || read != lastRead) { Flush(); if(restart) raw |= StartDet; }
            if(target == null) {
                raw |= TxAbrt; abortSource |= 1;        // ABRT_7B_ADDR_NOACK
                if(nacked.Add(tar & 0x7f)) this.Log(LogLevel.Info, "No target at 0x{0:X2} (address NACK)", tar & 0x7f);
                EndTransfer(true); Update(); return;
            }
            if(read) {
                var data = target.Read(1);
                if(rx.Count < FifoDepth) rx.Enqueue(data.Length > 0 ? data[0] : (byte)0xff); else raw |= RxOver;
            } else pending.Add((byte)value);
            lastRead = read;
            if(stop) EndTransfer(true);
            Update();
        }
        private void Start()
        {
            inTransfer = true; lastRead = false; pending.Clear();
            raw |= StartDet | Activity;
            TryGetByAddress((int)(tar & 0x7f), out target);
        }
        private void Flush()
        {
            if(target != null && pending.Count > 0) target.Write(pending.ToArray());
            pending.Clear();
        }
        private void EndTransfer(bool stopCondition)
        {
            if(!inTransfer) return;
            Flush();
            target?.FinishTransmission();
            target = null; inTransfer = false;
            if(stopCondition) raw |= StopDet;
        }
        private uint Clear(uint bit) { raw &= ~bit; Update(); return 0; }
        private uint Raw()
        {
            uint r = raw;
            if(rx.Count > rxTl) r |= RxFull;
            r |= TxEmpty;                               // TX FIFO is always drained
            return r;
        }
        private uint Stat() { return Raw() & mask; }
        private void Update() { IRQ.Set((enable & 1) != 0 && Stat() != 0); }

        private const int FifoDepth = 16;
        private const uint RxUnder = 1, RxOver = 2, RxFull = 4, TxOver = 8, TxEmpty = 0x10, RdReq = 0x20, TxAbrt = 0x40,
            RxDone = 0x80, Activity = 0x100, StopDet = 0x200, StartDet = 0x400, GenCall = 0x800;
        private readonly Queue<byte> rx = new Queue<byte>();
        private readonly List<byte> pending = new List<byte>();
        private readonly Dictionary<long, uint> regs = new Dictionary<long, uint>();
        private readonly HashSet<uint> nacked = new HashSet<uint>();
        private II2CPeripheral target;
        private bool inTransfer, lastRead;
        private uint con, tar, mask, rxTl, txTl, enable, raw, abortSource, sdaHold, dmaCr, dmaTdlr, dmaRdlr;
    }
}
