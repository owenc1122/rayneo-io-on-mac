// W1160/W1161 ambient light sensor (AP w1160_driver_uorb_init: I2C address 0x48, tries I2C0 then I2C1;
// w1160_checkid: register 0x3E must read 0xE6). Byte registers, auto-incrementing pointer.
// w1161_read_light: status 0x10 bit 7 = data ready; 0x13..0x16 = two channels, each big-endian
// [gain nibble | 12-bit mantissa], counts = mantissa << shift[gain] (shift table 20,18,16,15..1,0 at
// 0x1832f498); lux = ch0 * 0.0113 when ch1/ch0 < 2.5, else ch0 * 0.00855.
// Lux is settable from the monitor (`i2c1.light Lux 300`). Integration timing is not modelled.
using System;
using Antmicro.Renode.Peripherals.I2C;
namespace Antmicro.Renode.Peripherals.Sensors
{
    public sealed class BES1700_W1160 : II2CPeripheral
    {
        public BES1700_W1160() { Reset(); }
        public double Lux { get; set; } = 250;

        public void Write(byte[] data)
        {
            if(data.Length == 0) return;
            pointer = data[0];
            for(int i = 1; i < data.Length; i++) { if(pointer != 0x3e && pointer != 0x10) regs[pointer] = data[i]; pointer = (pointer + 1) & 0xff; }
        }
        public byte[] Read(int count)
        {
            if(pointer >= 0x13 && pointer <= 0x17) Sample();
            var r = new byte[count];
            for(int i = 0; i < count; i++) { r[i] = regs[pointer]; pointer = (pointer + 1) & 0xff; }
            return r;
        }
        public void FinishTransmission() {}
        public void Reset() { Array.Clear(regs, 0, regs.Length); regs[0x3e] = 0xe6; regs[0x10] = 0x80; pointer = 0; Sample(); }

        private void Sample()
        {
            long counts = (long)Math.Round(Math.Max(0, Lux) / 0.0113);
            Encode(0x13, counts);
            Encode(0x15, counts);      // ch1 = ch0: visible-light ratio, first coefficient
        }
        private void Encode(int reg, long counts)
        {
            // Pick the smallest shift that fits the 12-bit mantissa.
            int nibble = 15;
            while(nibble > 0 && (counts >> Shift[nibble]) > 0xfff) nibble--;
            long mantissa = Math.Min(0xfff, counts >> Shift[nibble]);
            regs[reg] = (byte)((nibble << 4) | (int)(mantissa >> 8));
            regs[reg + 1] = (byte)mantissa;
        }
        private static readonly int[] Shift = { 20, 18, 16, 15, 14, 13, 12, 11, 10, 8, 6, 4, 3, 2, 1, 0 };
        private readonly byte[] regs = new byte[256];
        private int pointer;
    }
}
