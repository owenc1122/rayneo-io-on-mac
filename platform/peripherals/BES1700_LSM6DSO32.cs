// ST LSM6DSO32 6-axis IMU as used by the BTH lsm6dso32 driver (bthI2c1 0x6A, WHO_AM_I 0x6C, INT1 on
// GPIO_PIN2_1 falling edge with H_LACTIVE, accel+gyro in the tagged FIFO). Register subset per the
// datasheet: CTRL1_XL..CTRL10_C, FIFO_CTRL1..4, FIFO_STATUS1/2, FIFO_DATA_OUT_TAG/X/Y/Z, INT1_CTRL,
// STATUS_REG, OUT_TEMP, OUTX..OUTZ for gyro and accel, TIMESTAMP. Samples are generated at the
// configured ODR in virtual time from the current motion (set by BES1700_HeadMotion or the monitor).
// Embedded functions (pedometer, tilt, FSM, MLC), self-test and power modes are not modelled.
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.I2C;
using Antmicro.Renode.Peripherals.Timers;
using Antmicro.Renode.Time;
namespace Antmicro.Renode.Peripherals.Sensors
{
    public sealed class BES1700_LSM6DSO32 : II2CPeripheral
    {
        public BES1700_LSM6DSO32(IMachine machine)
        {
            Interrupt1 = new GPIO(); Interrupt2 = new GPIO();
            timer = new LimitTimer(machine.ClockSource, 6667, null, "lsm6dso32", 1, Direction.Ascending,
                enabled: false, workMode: WorkMode.Periodic, eventEnabled: true, autoUpdate: true);
            timer.LimitReached += Sample;
            Reset();
        }
        public GPIO Interrupt1 { get; }
        public GPIO Interrupt2 { get; }
        public bool TraceStats { get; set; }
        // Motion in the sensor frame: acceleration in g, angular rate in dps.
        public double AccelX { get; set; }
        public double AccelY { get; set; }
        public double AccelZ { get; set; } = 1;
        public double GyroX { get; set; }
        public double GyroY { get; set; }
        public double GyroZ { get; set; }
        public double TemperatureC { get; set; } = 30;

        public void Write(byte[] data)
        {
            if(data.Length == 0) return;
            pointer = data[0];
            for(int i = 1; i < data.Length; i++) { WriteRegister(pointer, data[i]); Advance(); }
        }
        public byte[] Read(int count)
        {
            var r = new byte[count];
            for(int i = 0; i < count; i++) { r[i] = ReadRegister(pointer); Advance(); }
            return r;
        }
        public void FinishTransmission() {}
        // Monitor: `bthI2c1.bthImu Stats` (samples generated, FIFO words read, interrupt edges, current config).
        public string Stats()
        {
            return string.Format("samples={0} fifoRead={1} int1Edges={2} fifo={3} ctrl1=0x{4:X2} ctrl2=0x{5:X2} fifoCtrl3=0x{6:X2} fifoCtrl4=0x{7:X2} int1=0x{8:X2} wtm={9} ctrl3=0x{10:X2}",
                samples, fifoReads, edges, fifo.Count, regs[0x10], regs[0x11], regs[0x09], regs[0x0a], regs[0x0d], Watermark, regs[0x12]);
        }
        public void Reset()
        {
            Array.Clear(regs, 0, regs.Length);
            regs[0x0f] = 0x6c; regs[0x12] = 0x04; regs[0x08] = 0x00;
            fifo.Clear(); pointer = 0; ticks = 0; overrun = false; timer.Enabled = false; UpdateInterrupts();
        }

        private void Advance()
        {
            // IF_INC (CTRL3_C bit 2); FIFO_DATA_OUT wraps 0x78..0x7E so multi-byte reads stream words.
            if((regs[0x12] & 0x04) == 0) return;
            pointer = pointer == 0x7e ? 0x78 : (pointer + 1) & 0x7f;
        }
        private void WriteRegister(int reg, byte value)
        {
            switch(reg) {
                case 0x0f: case 0x1e: case 0x3a: case 0x3b: return;          // read-only
                case 0x12:
                    if((value & 0x01) != 0) { Reset(); return; }               // SW_RESET
                    regs[reg] = (byte)(value & 0x7e); UpdateInterrupts(); return;
                case 0x0a: regs[reg] = value; if((value & 7) == 0) { fifo.Clear(); overrun = false; } break;
                default: regs[reg] = value; break;
            }
            if(reg == 0x10 || reg == 0x11) Reschedule();
            UpdateInterrupts();
        }
        private byte ReadRegister(int reg)
        {
            switch(reg) {
                case 0x1e: return (byte)((AccelOn ? 1 : 0) | (GyroOn ? 2 : 0) | 4);    // XLDA, GDA, TDA
                case 0x3a: return (byte)(fifo.Count & 0xff);
                case 0x3b: {
                    int wtm = Watermark;
                    return (byte)(((fifo.Count >> 8) & 3) | (wtm > 0 && fifo.Count >= wtm ? 0x80 : 0) | (overrun ? 0x40 : 0) | (fifo.Count >= FifoDepth ? 0x20 : 0));
                }
                case 0x78: {
                    if(fifo.Count == 0) return 0;
                    current = fifo.Peek();
                    return current[0];
                }
                case 0x79: case 0x7a: case 0x7b: case 0x7c: case 0x7d: return fifo.Count > 0 ? fifo.Peek()[reg - 0x78] : (byte)0;
                case 0x7e: {
                    if(fifo.Count == 0) return 0;
                    var w = fifo.Dequeue(); fifoReads++;
                    if(TraceStats && (fifoReads == 1 || fifoReads % 200 == 0)) this.Log(LogLevel.Info, "FIFO read: " + Stats());
                    UpdateInterrupts();
                    return w[6];
                }
                case 0x20: case 0x21: { int t = (int)Math.Round((TemperatureC - 25) * 256); return (byte)(reg == 0x20 ? t : t >> 8); }
                case 0x22: case 0x23: return Word(GyroRaw(GyroX), reg - 0x22);
                case 0x24: case 0x25: return Word(GyroRaw(GyroY), reg - 0x24);
                case 0x26: case 0x27: return Word(GyroRaw(GyroZ), reg - 0x26);
                case 0x28: case 0x29: return Word(AccelRaw(AccelX), reg - 0x28);
                case 0x2a: case 0x2b: return Word(AccelRaw(AccelY), reg - 0x2a);
                case 0x2c: case 0x2d: return Word(AccelRaw(AccelZ), reg - 0x2c);
                case 0x40: case 0x41: case 0x42: case 0x43: return (byte)(ticks >> (8 * (reg - 0x40)));
                default: return regs[reg];
            }
        }

        private static readonly double[] OdrHz = { 0, 12.5, 26, 52, 104, 208, 416, 833, 1666, 3332, 6667, 1.6, 0, 0, 0, 0 };
        private double AccelOdr => OdrHz[regs[0x10] >> 4];
        private double GyroOdr => OdrHz[regs[0x11] >> 4];
        private bool AccelOn => AccelOdr > 0;
        private bool GyroOn => GyroOdr > 0;
        private int Watermark => regs[0x07] | ((regs[0x08] & 1) << 8);
        private const int FifoDepth = 512;

        private void Reschedule()
        {
            double rate = Math.Max(AccelOdr, GyroOdr);
            if(rate <= 0) { timer.Enabled = false; return; }
            timer.Enabled = false;
            timer.Frequency = (ulong)Math.Round(rate * 10);   // 0.1 Hz resolution
            timer.Limit = 10;
            timer.Value = 0;
            timer.Enabled = true;
        }
        private void Sample()
        {
            ticks += 25;   // TIMESTAMP counts 25 us
            samples++;
            if(TraceStats && samples % 500 == 0) this.Log(Antmicro.Renode.Logging.LogLevel.Info, Stats());
            int mode = regs[0x0a] & 7;
            if(mode != 0) {
                // BDR_XL = FIFO_CTRL3[3:0], BDR_GY = [7:4]; batch whichever is enabled.
                if((regs[0x09] >> 4) != 0 && GyroOn) Push(0x01, GyroRaw(GyroX), GyroRaw(GyroY), GyroRaw(GyroZ), mode);
                if((regs[0x09] & 0xf) != 0 && AccelOn) Push(0x02, AccelRaw(AccelX), AccelRaw(AccelY), AccelRaw(AccelZ), mode);
            }
            UpdateInterrupts(pulseDrdy: true);
        }
        private void Push(int tag, short x, short y, short z, int mode)
        {
            if(fifo.Count >= FifoDepth) {
                overrun = true;
                if(mode == 1) return;            // FIFO mode: stop when full
                fifo.Dequeue();                  // continuous: overwrite oldest
            }
            var w = new byte[7];
            w[0] = (byte)((tag << 3) | ((tagCounter & 3) << 1));
            w[1] = (byte)x; w[2] = (byte)(x >> 8); w[3] = (byte)y; w[4] = (byte)(y >> 8); w[5] = (byte)z; w[6] = (byte)(z >> 8);
            fifo.Enqueue(w);
            tagCounter++;
        }
        private void UpdateInterrupts(bool pulseDrdy = false)
        {
            byte int1 = regs[0x0d];
            bool level = false;
            if((int1 & 0x08) != 0 && Watermark > 0 && fifo.Count >= Watermark) level = true;   // INT1_FIFO_TH
            if((int1 & 0x10) != 0 && overrun) level = true;                                    // INT1_FIFO_OVR
            if((int1 & 0x20) != 0 && fifo.Count >= FifoDepth) level = true;                    // INT1_FIFO_FULL
            bool drdy = pulseDrdy && (((int1 & 0x01) != 0 && AccelOn) || ((int1 & 0x02) != 0 && GyroOn));
            bool activeLow = (regs[0x12] & 0x20) != 0;                                          // H_LACTIVE
            if(drdy) { Drive(true, activeLow); Drive(level, activeLow); }                       // DRDY pulse
            else Drive(level, activeLow);
        }
        private void Drive(bool asserted, bool activeLow)
        {
            if(asserted && !lastAsserted) { edges++; if(TraceStats && edges <= 5) this.Log(LogLevel.Info, "INT1 asserted: " + Stats()); }
            lastAsserted = asserted;
            Interrupt1.Set(asserted ^ activeLow);
        }
        private short AccelRaw(double g)
        {
            int fs = (regs[0x10] >> 2) & 3;
            double mgPerLsb = fs == 0 ? 0.122 : fs == 1 ? 0.976 : fs == 2 ? 0.244 : 0.488;   // ±4/32/8/16 g
            return Clamp(g * 1000 / mgPerLsb);
        }
        private short GyroRaw(double dps)
        {
            int fs = (regs[0x11] >> 2) & 3;
            double mdps = (regs[0x11] & 0x02) != 0 ? 4.375 : fs == 0 ? 8.75 : fs == 1 ? 17.5 : fs == 2 ? 35 : 70;
            return Clamp(dps * 1000 / mdps);
        }
        private static short Clamp(double v) { return (short)Math.Max(-32768, Math.Min(32767, Math.Round(v))); }
        private static byte Word(short v, int half) { return (byte)(half == 0 ? v : v >> 8); }

        private readonly byte[] regs = new byte[128];
        private readonly Queue<byte[]> fifo = new Queue<byte[]>();
        private readonly LimitTimer timer;
        private byte[] current;
        private int pointer, tagCounter;
        private uint ticks;
        private bool overrun, lastAsserted;
        private long samples, fifoReads, edges;
    }
}
