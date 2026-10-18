// Probe-only logging memory (NOT in the default build - see the PROBE=1 variant in make-resc.py).
// A plain byte-array memory that, unlike MappedMemory, routes every access through methods, so each
// byte/word/doubleword read and write is visible. Logs the accessing BTC core's PC + the value, to
// reverse which EM/env fields the rwip page path reads and writes without any static xref.
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;
namespace Antmicro.Renode.Peripherals.Memory
{
    public sealed class BES1700_ProbeMemory : IBytePeripheral, IWordPeripheral, IDoubleWordPeripheral, IKnownSize
    {
        public BES1700_ProbeMemory(IMachine machine, long size, ulong baseAddr, string tag = "PROBE")
        {
            this.machine = machine; this.sizeV = size; this.baseAddr = baseAddr; this.tag = tag;
            data = new byte[size];
        }
        // The accessing core, looked up ONCE lazily and cached. Reading cpu.PC is a lock-free register
        // read; calling SystemBus.TryGetCurrentCPU per access deadlocks (it takes the sysbus lock from
        // inside a bus access). For a btcRam/EM window the accessor is the btc core.
        public Antmicro.Renode.Peripherals.CPU.ICPU Cpu { get; set; }
        public long Size => sizeV;
        public void Reset() { }
        private ulong Pc()
        {
            try { return Cpu != null ? Cpu.PC.RawValue : 0; } catch { return 0; }
        }
        private void Acc(string op, long off, ulong val, int w)
        {
            if(n < Cap) { n++; this.Log(LogLevel.Info, "{0} {1}{2} 0x{3:x} v=0x{4:x} pc=0x{5:x}", tag, op, w, baseAddr + (ulong)off, val, Pc()); }
        }
        public byte ReadByte(long o) { byte v = data[o]; Acc("rd", o, v, 1); return v; }
        public void WriteByte(long o, byte v) { Acc("wr", o, v, 1); data[o] = v; }
        public ushort ReadWord(long o) { ushort v = (ushort)(data[o] | (data[o + 1] << 8)); Acc("rd", o, v, 2); return v; }
        public void WriteWord(long o, ushort v) { Acc("wr", o, v, 2); data[o] = (byte)v; data[o + 1] = (byte)(v >> 8); }
        public uint ReadDoubleWord(long o) { uint v = (uint)(data[o] | (data[o + 1] << 8) | (data[o + 2] << 16) | (data[o + 3] << 24)); Acc("rd", o, v, 4); return v; }
        public void WriteDoubleWord(long o, uint v) { Acc("wr", o, v, 4); data[o] = (byte)v; data[o + 1] = (byte)(v >> 8); data[o + 2] = (byte)(v >> 16); data[o + 3] = (byte)(v >> 24); }
        private readonly IMachine machine; private readonly long sizeV; private readonly ulong baseAddr; private readonly string tag;
        private readonly byte[] data; private int n; private const int Cap = 40000;
    }
}
