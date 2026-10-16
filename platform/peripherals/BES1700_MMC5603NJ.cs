// MEMSIC MMC5603NJ 3-axis magnetometer probed by the BTH (mmc5603nj_init: product ID reg 0x39 = 0x10).
// Byte registers, auto-incrementing pointer. Measurements complete instantly: Status1 reports
// Meas_m_done/Meas_t_done as soon as a measurement (or continuous mode) is requested.
// Output: 20-bit offset binary, 16384 counts per gauss (0x80000 = 0). The field is the local
// geomagnetic vector rotated by HeadingDegrees, settable from the monitor for head-direction tests.
using System;
using Antmicro.Renode.Peripherals.I2C;
namespace Antmicro.Renode.Peripherals.Sensors
{
    public sealed class BES1700_MMC5603NJ : II2CPeripheral
    {
        public BES1700_MMC5603NJ() { Reset(); }
        public double HeadingDegrees { get; set; }
        public double HorizontalGauss { get; set; } = 0.20;
        public double VerticalGauss { get; set; } = 0.45;
        public double TemperatureC { get; set; } = 30;

        public void Write(byte[] data)
        {
            if(data.Length == 0) return;
            pointer = data[0];
            for(int i = 1; i < data.Length; i++) { WriteRegister(pointer, data[i]); pointer = (pointer + 1) & 0xff; }
        }
        public byte[] Read(int count)
        {
            var r = new byte[count];
            for(int i = 0; i < count; i++) { r[i] = ReadRegister(pointer); pointer = (pointer + 1) & 0xff; }
            return r;
        }
        public void FinishTransmission() {}
        public void Reset() { Array.Clear(regs, 0, regs.Length); regs[0x39] = 0x10; regs[0x18] = 0x10; pointer = 0; Sample(); }

        private void WriteRegister(int reg, byte value)
        {
            switch(reg) {
                case 0x1b: // Internal control 0: take measurement M/T, set/reset pulses
                    if((value & 0x03) != 0) { Sample(); regs[0x18] |= (byte)(((value & 1) != 0 ? 0x40 : 0) | ((value & 2) != 0 ? 0x80 : 0)); }
                    break;
                case 0x1c: // Internal control 1: bit 7 software reset
                    if((value & 0x80) != 0) { Reset(); return; }
                    regs[reg] = value; break;
                case 0x18: break; // status is read-only
                default: regs[reg] = value; break;
            }
        }
        private byte ReadRegister(int reg)
        {
            if(reg <= 0x09 && (regs[0x1d] & 0x10) != 0) Sample();   // continuous mode: fresh data
            if(reg == 0x18 && (regs[0x1d] & 0x10) != 0) return (byte)(regs[0x18] | 0xc0);
            return regs[reg];
        }
        private void Sample()
        {
            double h = HeadingDegrees * Math.PI / 180;
            // Glasses frame: X forward, Y left, Z up. Magnetic north at heading 0.
            double gx = HorizontalGauss * Math.Cos(h), gy = -HorizontalGauss * Math.Sin(h), gz = -VerticalGauss;
            Put(0x00, 0x06, gx); Put(0x02, 0x07, gy); Put(0x04, 0x08, gz);
            regs[0x09] = (byte)Math.Max(0, Math.Min(255, (TemperatureC + 75) / 0.8));
        }
        private void Put(int hi, int low, double gauss)
        {
            int v = Math.Max(0, Math.Min(0xfffff, 0x80000 + (int)Math.Round(gauss * 16384)));
            regs[hi] = (byte)(v >> 12); regs[hi + 1] = (byte)(v >> 4); regs[low] = (byte)((v & 0xf) << 4);
        }
        private readonly byte[] regs = new byte[256];
        private int pointer;
    }
}
