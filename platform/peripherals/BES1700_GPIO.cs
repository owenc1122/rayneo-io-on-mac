// Drop-in replacement for platform/peripherals/BES1700_GPIO.cs.
// Keeps the existing panel software-SPI behaviour byte-for-byte and adds: input pins, edge/level interrupts.
// Register map from the stock HAL (hal_gpio_setup_irq 0x105b96f0, _hal_gpio_irq_handler 0x105b9360,
// hal_gpio_pin_get_val 0x105b961c). The block uses set/clear register pairs:
//   0x00 DR set   / 0x0c DR clear        0x04 DDR set  / 0x10 DDR clear      0x50 EXT (pin level)
//   0x30 INTEN set/ 0x18 INTEN clear     0x34 MASK set / 0x1c MASK clear
//   0x38 EDGE set / 0x20 EDGE clear (clear = level)   0x3c POL set (high/rising) / 0x24 POL clear (low/falling)
//   0x48 DEBOUNCE set / 0x28 clear       0x40 masked status, 0x44 raw status, 0x4c EOI (write 1 clears edge latch)
// The interrupt the CPU actually sees is routed through the PSC block (see BES1700_PSC_draft.cs): the handler
// reads PSC 0x40085108/1a8/1cc for banks 0/1/2, all on NVIC line 2 (nuttx_irq_attach(2) in hal_gpio_setup_irq).
// Input injection from the monitor:  gpio0 SetInput 1 false   (crown/action key P0_1, active low)
using System;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Time;
namespace Antmicro.Renode.Peripherals.GPIOPort
{
    public class BES1700_GPIO : IDoubleWordPeripheral, IKnownSize, IGPIOReceiver
    {
        public BES1700_GPIO(IMachine machine, bool panelSPI = false, byte panelId = 0x87, uint pullUps = 0, uint invertedInputs = 0)
        { this.machine = machine; this.panelSPI = panelSPI; this.panelId = panelId; this.pullUps = pullUps; this.invertedInputs = invertedInputs; IRQ = new GPIO(); Reset(); }
        public long Size => 0x1000;
        public GPIO IRQ { get; private set; }
        public event Action PendingChanged;
        // Raised after the driven output word changes (e.g. panel power enables seen by the LCDC model).
        public event Action OutputChanged;
        public uint Output => output & direction;
        public uint Pending => (raw & inten & ~mask);

        public uint ReadDoubleWord(long offset)
        {
            switch(offset) {
                case 0: return output;
                case 4: return direction;
                case 0x30: return inten;
                case 0x34: return mask;
                case 0x38: return edge;
                case 0x3c: return polarity;
                case 0x40: return Pending;
                case 0x44: return raw;
                case 0x50: return panelSPI ? ((output & ~Miso) | (miso ? Miso : 0)) & PanelPins | (Level() & ~PanelPins) : Level();
                default: return 0;
            }
        }
        public void WriteDoubleWord(long offset, uint value)
        {
            var old = output;
            switch(offset) {
                case 0: output |= value; break;
                case 0xc: output &= ~value; break;
                case 4: direction |= value; Reevaluate(); return;
                case 0x10: direction &= ~value; Reevaluate(); return;
                case 0x30: inten |= value; Reevaluate(); return;
                case 0x18: inten &= ~value; Reevaluate(); return;
                case 0x34: mask |= value; Update(); return;
                case 0x1c: mask &= ~value; Update(); return;
                case 0x38: edge |= value; Reevaluate(); return;
                case 0x20: edge &= ~value; Reevaluate(); return;
                case 0x3c: polarity |= value; Reevaluate(); return;
                case 0x24: polarity &= ~value; Reevaluate(); return;
                case 0x48: case 0x28: return;      // debounce enable: no timing model
                case 0x4c: raw &= ~(value & edge); Reevaluate(); return;
                default: return;
            }
            if(old != output) OutputChanged?.Invoke();
            if(!panelSPI) { Reevaluate(); return; }
            if((output & ChipSelects) == ChipSelects) { bits=0; index=0; shift=0; miso=false; return; }
            if((old & ChipSelects) != (output & ChipSelects)) { bits=0; index=0; shift=0; }
            if((old & Clock)==0 && (output & Clock)!=0)
            {
                if(index >= 2 && command == 0x19)
                    miso=(ReadPanelRegister(address) & (1 << (7-bits))) != 0;
                shift=(byte)((shift<<1) | ((output & Mosi)!=0 ? 1 : 0));
                if(++bits==8) {
                    TransferPanelByte(shift);
                    bits=0; shift=0;
                }
            }
        }

        // ---- input side ----
        // invertedInputs: lines from models that drive active-high where the board signal is active-low
        // (e.g. the IMU INT1 with H_LACTIVE set by the firmware).
        public void OnGPIO(int number, bool value) { SetInput(number, ((invertedInputs >> number) & 1) != 0 ? !value : value); }
        public void SetInput(int pin, bool level)
        {
            if(pin < 0 || pin > 31) return;
            uint before = Level();
            if(level) inputs |= 1u << pin; else inputs &= ~(1u << pin);
            uint after = Level();
            uint rise = ~before & after, fall = before & ~after;
            raw |= edge & inten & ((rise & polarity) | (fall & ~polarity));
            Reevaluate();
        }
        // Convenience for scripted crown presses: holds the pin at 'activeLevel' for 'milliseconds' of virtual time.
        public void Pulse(int pin, bool activeLevel, ulong milliseconds)
        {
            SetInput(pin, activeLevel);
            machine.ScheduleAction(TimeInterval.FromMilliseconds(milliseconds), _ => SetInput(pin, !activeLevel));
        }
        private uint Level() { return (output & direction) | (inputs & ~direction); }
        private void Reevaluate()
        {
            uint lvl = Level();
            uint levelHits = ~edge & inten & ((lvl & polarity) | (~lvl & ~polarity));
            raw = (raw & edge) | levelHits;
            Update();
        }
        private void Update() { IRQ.Set(Pending != 0); PendingChanged?.Invoke(); }

        // ---- panel SPI (unchanged from platform version) ----
        public byte TransferPanelByte(byte value)
        {
            if((output & ChipSelects)==ChipSelects) return 0;
            byte response=0;
            if(index==0) command=value;
            else if(index==1) address=value;
            else if(command==0x18) { if((output&Cs)==0) registers[address]=value; if((output&RightCs)==0) rightRegisters[address]=value; }
            else if(command==0x19) response=ReadPanelRegister(address);
            if(index==2 && command==0x19 && address==0x34)
                this.Log(LogLevel.Info,"Panel SPI ID read: 0x{0:X2}",response);
            if(index==2 && (address==0x36 || address==0x17)) this.Log(LogLevel.Info,"Panel reg {0:X2} cmd={1:X2} value={2:X2} response={3:X2} selected={4:X}",address,command,value,response,(~output)&ChipSelects);
            index++;
            return response;
        }
        public void Reset()
        {
            output=panelSPI ? ChipSelects : 0; direction=0; miso=false; bits=0;index=0;shift=0;command=0;address=0;
            inputs=pullUps; inten=0; mask=0; edge=0; polarity=0; raw=0;
            System.Array.Clear(registers,0,registers.Length);registers[0x34]=panelId;System.Array.Clear(rightRegisters,0,rightRegisters.Length);rightRegisters[0x34]=panelId;
            IRQ.Unset();
        }
        private byte ReadPanelRegister(byte register) { return (byte)(((output&Cs)==0?registers[register]:255) & ((output&RightCs)==0?rightRegisters[register]:255)); }
        private const uint RightCs=1u<<23, ChipSelects=(1u<<16)|(1u<<23);
        private const uint Cs=1u<<16,Clock=1u<<17,Mosi=1u<<18,Miso=1u<<19;
        private const uint PanelPins=ChipSelects|Clock|Mosi|Miso;
        private readonly IMachine machine;
        private readonly bool panelSPI;
        private readonly byte panelId;
        private readonly uint pullUps, invertedInputs;
        private readonly byte[] rightRegisters=new byte[256];
        private readonly byte[] registers=new byte[256];
        private uint output,direction,inputs,inten,mask,edge,polarity,raw;
        private bool miso;
        private int bits,index;
        private byte shift,command,address;
    }
}
