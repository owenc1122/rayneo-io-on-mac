// Functional QSPI command engine. Pixel scanout and display interrupts are not yet modeled.
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.GPIOPort;
using Antmicro.Renode.Peripherals.Miscellaneous;
namespace Antmicro.Renode.Peripherals.Video
{
    public class BES1700_LCDC : BES1700_RegisterBank
    {
        public BES1700_LCDC(IMachine machine,BES1700_GPIO panel,string capturePath=null):base(machine) {this.panel=panel;this.machine=machine;this.capturePath=capturePath;IRQ=new GPIO();}
        public GPIO IRQ {get; private set;}
        public uint CompletedFrames {get; private set;}
        public string FrameImagePath {get; set;}
        public byte[] LastFrame {get; private set;}
        public override void WriteDoubleWord(long offset,uint value)
        {
            base.WriteDoubleWord(offset,value);
            if(offset==0x1c0 || offset==0x1c4) UpdateIRQ();
            if(offset==0x224 && (value&1)!=0) {ScanOut();return;}
            if(offset!=0x280 || (value&1)==0) return;
            // The stock HAL encodes data bit count minus one in bits 4 onward.
            int length=(value&2)!=0 ? (int)(((value>>4)&255)+1)/8 : 0;
            var previous=panel.ReadDoubleWord(0);
            uint selections=(1u<<16)|(1u<<23);
            this.Log(LogLevel.Info,"QSPI select {0:X} gpio={1:X} command={2:X} data={3:X}",ReadDoubleWord(0x2a8),previous,ReadDoubleWord(0x284),ReadDoubleWord(0x288));
            uint selected=(~previous)&selections;
            if(selected==0) selected=(ReadDoubleWord(0x2a8)&3)==2 ? 1u<<23 : 1u<<16;
            panel.WriteDoubleWord(0,selections);
            panel.WriteDoubleWord(12,selected);
            panel.TransferPanelByte((byte)ReadDoubleWord(0x284));
            for(int i=0;i<length;i++)
                panel.TransferPanelByte((byte)(ReadDoubleWord(0x288+(i/4)*4)>>(24-8*(i%4))));
            panel.WriteDoubleWord(0,selections);
            panel.WriteDoubleWord(12,(~previous)&selections);
            base.WriteDoubleWord(0x280,value&~1u);
            base.WriteDoubleWord(0x1c4,ReadDoubleWord(0x1c4)|(1u<<18));
        }
        private void ScanOut()
        {
            uint control=ReadDoubleWord(0x190), address=ReadDoubleWord(0xc0);
            int width=(int)(ReadDoubleWord(0xec)&0xfff),height=(int)((ReadDoubleWord(0xec)>>16)&0xfff);
            int stride=(int)(ReadDoubleWord(0xe0)&0xffff);
            // Current observed path is a packed RGB888 stream on layer 1.
            // Other formats/layers must be implemented before acknowledging them.
            if((control&1)==0 || ((control>>8)&15)!=2 || width<=0 || height<=0 || stride<width*3 || (long)stride*height>16777216 || address==0) {
                this.Log(LogLevel.Warning,"Unsupported scanout: control={0:X} address={1:X} size={2}x{3} stride={4}",control,address,width,height,stride);return;
            }
            LastFrame=machine.GetSystemBus(this).ReadBytes(address,stride*height);
            CompletedFrames++;
            if(FrameImagePath!=null) {
                // This RayNeo transport packs three monochrome samples per RGB888 transfer unit.
                var header=System.Text.Encoding.ASCII.GetBytes(string.Format("P5\n{0} {1}\n255\n",width*3,height));
                string temporary=FrameImagePath+".tmp";
                using(var stream=System.IO.File.Create(temporary)) {
                    stream.Write(header,0,header.Length);
                    for(int y=0;y<height;y++) stream.Write(LastFrame,y*stride,width*3);
                }
                // Atomic replacement prevents the UI from reading a partial frame.
                if(System.IO.File.Exists(FrameImagePath)) System.IO.File.Replace(temporary,FrameImagePath,null);
                else System.IO.File.Move(temporary,FrameImagePath);
            }
            if(capturePath!=null) System.IO.File.WriteAllBytes(capturePath,LastFrame);
            if(CompletedFrames<=4) this.Log(LogLevel.Info,"Scanout copied: frame={0} address={1:X} size={2}x{3} stride={4} bytes={5}",CompletedFrames,address,width,height,stride,LastFrame.Length);
            base.WriteDoubleWord(0x224,0);
            // Functional transfer done: aggregate SPI frame bit and raw layer completion.
            base.WriteDoubleWord(0x1c4,ReadDoubleWord(0x1c4)|0x100400u);
            UpdateIRQ();
        }
        private void UpdateIRQ() {IRQ.Set((ReadDoubleWord(0x1c4)&ReadDoubleWord(0x1c0))!=0);}
        private readonly IMachine machine;
        private readonly string capturePath;
        private readonly BES1700_GPIO panel;
    }
}
