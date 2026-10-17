// Host-side head pose for the BTH IMU (BES1700_LSM6DSO32).
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
        public BES1700_HeadMotion(IMachine machine, BES1700_LSM6DSO32 imu) { this.machine = machine; this.imu = imu; Apply(0, 0, 0, 0, 0); }
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
        // Sensor mounting: the BTH neck monitor rotates IMU samples by Euler angles (roll, pitch, yaw) =
        // imu_params, default [101, -65, -65] deg when factory data is blank (AP log "Using default imu_params").
        // Head-frame vectors are mapped back into the sensor frame with the transpose of that rotation.
        public double MountRoll { get; set; } = 101;
        public double MountPitch { get; set; } = -65;
        public double MountYaw { get; set; } = -65;
        public int MountOrder { get; set; } = 0;     // 0: R = Rz*Ry*Rx, 1: R = Rx*Ry*Rz
        private void Apply(double p, double r, double rateX, double rateY, double rateZ)
        {
            double pr = p * Math.PI / 180, rr = r * Math.PI / 180;
            // Gravity reaction in the head frame at rest is +1 g up; tilting moves it to X/Y.
            var g = new[] { -Math.Sin(pr), Math.Sin(rr) * Math.Cos(pr), Math.Cos(rr) * Math.Cos(pr) };
            var w = new[] { rateX, rateY, rateZ };
            var R = Mount();
            var gs = MulT(R, g); var ws = MulT(R, w);
            imu.AccelX = gs[0]; imu.AccelY = gs[1]; imu.AccelZ = gs[2];
            imu.GyroX = ws[0]; imu.GyroY = ws[1]; imu.GyroZ = ws[2];
        }
        private double[,] Mount()
        {
            double a = MountRoll * Math.PI / 180, b = MountPitch * Math.PI / 180, c = MountYaw * Math.PI / 180;
            var rx = new double[,] { { 1, 0, 0 }, { 0, Math.Cos(a), -Math.Sin(a) }, { 0, Math.Sin(a), Math.Cos(a) } };
            var ry = new double[,] { { Math.Cos(b), 0, Math.Sin(b) }, { 0, 1, 0 }, { -Math.Sin(b), 0, Math.Cos(b) } };
            var rz = new double[,] { { Math.Cos(c), -Math.Sin(c), 0 }, { Math.Sin(c), Math.Cos(c), 0 }, { 0, 0, 1 } };
            return MountOrder == 0 ? Mul(Mul(rz, ry), rx) : Mul(Mul(rx, ry), rz);
        }
        private static double[,] Mul(double[,] x, double[,] y)
        {
            var m = new double[3, 3];
            for(int i = 0; i < 3; i++) for(int j = 0; j < 3; j++) for(int k = 0; k < 3; k++) m[i, j] += x[i, k] * y[k, j];
            return m;
        }
        // Sensor = R^T * head (R maps sensor to head).
        private static double[] MulT(double[,] m, double[] v)
        {
            var o = new double[3];
            for(int i = 0; i < 3; i++) for(int k = 0; k < 3; k++) o[i] += m[k, i] * v[k];
            return o;
        }
        private readonly IMachine machine;
        private readonly BES1700_LSM6DSO32 imu;
        private double pitch, roll;
    }
}
