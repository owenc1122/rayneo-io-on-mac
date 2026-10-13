// NVIC for an ARMv8-M core whose firmware runs with MPU_CTRL.PRIVDEFENA=0.
//
// Architecture (ARMv8-M ARM, "Protected Memory System Architecture"): accesses to
// the Private Peripheral Bus 0xE0000000-0xE00FFFFF always use the default memory
// map and are never checked against MPU regions. Renode 1.17's tlib does check
// them, so the stock BTH firmware faults on its first SCB->VTOR read.
//
// Work-around inside the emulator only: the CPU is created with one MPU region more
// than the silicon (17), make-resc.py programs that extra region (16) to cover the
// PPB (privileged RW, XN), and this NVIC reports the real count (16) in MPU_TYPE so
// the firmware's "real number == config" check and its region loops never see or
// touch region 16. Firmware code and data are untouched.
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals.Bus;
namespace Antmicro.Renode.Peripherals.IRQControllers
{
    public class BES1700_PPBExemptNVIC : NVIC, IDoubleWordPeripheral
    {
        public BES1700_PPBExemptNVIC(IMachine machine, long systickFrequency = 50000000, uint reportedMpuRegions = 16)
            : base(machine, (ulong)systickFrequency, 0xFF, true) { this.reportedMpuRegions = reportedMpuRegions; }
        public new uint ReadDoubleWord(long offset)
        {
            var value = base.ReadDoubleWord(offset);
            if(offset == 0xd90) value = (value & ~0xff00u) | ((reportedMpuRegions & 0xff) << 8);
            return value;
        }
        private readonly uint reportedMpuRegions;
    }
}
