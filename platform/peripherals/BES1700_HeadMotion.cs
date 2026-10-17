// Host-side head pose for the BTH IMU (Renode LSM6DSO_IMU standing in for the LSM6DSO32).
// Not a chip register block: it sits on an unused sysbus window so the monitor / Mac app can call it,
// and drives the IMU's default acceleration (gravity direction from pitch/roll) and angular rate.
// Gestures are played in virtual time so they keep real-world timing however fast the emulation runs.
//   monitor: headMotion Pose 20 0      (pitch up 20 deg, roll 0)
//            headMotion Nod             (down and back, ~0.6 s)    headMotion Shake   (left-right, ~0.8 s)
//            headMotion Turn 30         (yaw 30 deg over 0.5 s)
// Axis convention (glasses frame, assumption until checked against a real unit): X forward, Y left, Z up;
// pitch rotates about Y, yaw about Z, roll about X. Rates in dps, acceleration in g.
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.Sensors;
using Antmicro.Renode.Time;
namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public sealed class BES1700_HeadMotion : IDoubleWordPeripheral, IKnownSize
    {
        public BES1700_HeadMotion(IMachine machine, LSM6DSO_IMU imu) { this.machine = machine; this.imu = imu; Apply(0, 0, 0, 0, 0); }
        public long Size => 0x100;
        public uint ReadDoubleWord(long offset) { return 0; }
        public void WriteDoubleWord(long offset, uint value) { }
        public void Reset() { pitch = roll = 0; Apply(0, 0, 0, 0, 0); }

        public double Pitch => pitch;
        public double Roll => roll;

        public void Pose(double pitchDegrees, double rollDegrees)
        {
            Play(new List<(double, double, double, double)> { (0.25, pitchDegrees - pitch, rollDegrees - roll, 0) });
        }
        public void Nod() { Play(new List<(double, double, double, double)> { (0.3, -25, 0, 0), (0.3, 25, 0, 0) }); }
        public void Shake() { Play(new List<(double, double, double, double)> { (0.2, 0, 0, 30), (0.4, 0, 0, -60), (0.2, 0, 0, 30) }); }
        public void Turn(double yawDegrees) { Play(new List<(double, double, double, double)> { (0.5, 0, 0, yawDegrees) }); }

        // Each segment: duration (s), delta pitch, delta roll, delta yaw (deg), at constant rate.
        private void Play(List<(double t, double dp, double dr, double dy)> segments)
        {
            double at = 0;
            const double step = 0.02;
            foreach(var seg in segments) {
                int n = Math.Max(1, (int)Math.Round(seg.t / step));
                double rp = seg.dp / seg.t, rr = seg.dr / seg.t, ry = seg.dy / seg.t;
                for(int i = 0; i < n; i++) {
                    machine.ScheduleAction(TimeInterval.FromSeconds(at), _ => {
                        pitch += rp * step; roll += rr * step;
                        Apply(pitch, roll, rr, rp, ry);
                    });
                    at += step;
                }
            }
            machine.ScheduleAction(TimeInterval.FromSeconds(at), _ => Apply(pitch, roll, 0, 0, 0));
        }
        private void Apply(double p, double r, double rateX, double rateY, double rateZ)
        {
            double pr = p * Math.PI / 180, rr = r * Math.PI / 180;
            // Gravity seen by the sensor at rest is +1 g on the up axis; tilting moves it to X/Y.
            imu.DefaultAccelerationX = (decimal)(-Math.Sin(pr));
            imu.DefaultAccelerationY = (decimal)(Math.Sin(rr) * Math.Cos(pr));
            imu.DefaultAccelerationZ = (decimal)(Math.Cos(rr) * Math.Cos(pr));
            imu.DefaultAngularRateX = (decimal)rateX;
            imu.DefaultAngularRateY = (decimal)rateY;
            imu.DefaultAngularRateZ = (decimal)rateZ;
        }
        private readonly IMachine machine;
        private readonly LSM6DSO_IMU imu;
        private double pitch, roll;
    }
}
