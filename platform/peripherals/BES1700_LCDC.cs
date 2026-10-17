// RayNeo LCDC: QSPI command engine + G4 scanout into a 1080x280 two-eye canvas (see display.md).
// Changes vs platform version: ScanOut decodes the RayNeo G4 transport and keeps one 540x280 canvas per eye.
//   * Layer 1 is programmed as 90 x H "RGB888" (fmt 2) with pitch 302 (rayneo_lcdc_layer_update_full 0x10753a04,
//     _partial 0x10753a54, _dual_update_full 0x10753bb0). Each byte carries two 4-bit grey pixels, even x in the
//     HIGH nibble (rgb565_to_g4_align_mve 0x108238bc: byte=((p0>>3)&0xf0)|((p1>>7)&0x0f) = green[5:2] of RGB565).
//   * Eye select = panel GPIO1 chip selects at trigger time: bit16 low = CS1 (pin 0x30, buffer 0x202802c0 in dual
//     mode), bit23 low = CS2 (pin 0x37, buffer 0x2026b840); both low = same data to both panels (set_spi_cs_pin(0)).
//   * Full refresh is sent as rows 0..278 then row 279 (address +279*302); partial refresh sends only rows
//     [start,end]. The row of a transfer is recovered from the address relative to the last full-frame base.
// Output PGM: 1080x280, left half = CS1 eye, right half = CS2 eye, grey = nibble*17 (panel is green monochrome).
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Bus;
using Antmicro.Renode.Peripherals.GPIOPort;
using Antmicro.Renode.Peripherals.Miscellaneous;
namespace Antmicro.Renode.Peripherals.Video
{
    public class BES1700_LCDC : BES1700_RegisterBank
    {
        public const int EyeWidth=540, EyeHeight=280, RowBytes=302;
        public BES1700_LCDC(IMachine machine,BES1700_GPIO panel,string capturePath=null):base(machine) {this.panel=panel;this.machine=machine;this.capturePath=capturePath;IRQ=new GPIO();panel.OutputChanged+=OnPanelOutput;}
        public GPIO IRQ {get; private set;}
        public uint CompletedFrames {get; private set;}
        public string FrameImagePath {get; set;}
        public byte[] LastFrame {get; private set;}
        public byte[] Canvas => canvas;                    // 1080x280 8-bit grey, both eyes
        public override void WriteDoubleWord(long offset,uint value)
        {
            base.WriteDoubleWord(offset,value);
            if(offset==0x1c0 || offset==0x1c4) UpdateIRQ();
            if(offset==0x224 && (value&1)!=0) {ScanOut();return;}
            if(offset!=0x280 || (value&1)==0) return;
            int length=(value&2)!=0 ? (int)(((value>>4)&255)+1)/8 : 0;
            if(qspiLog-->0) this.Log(LogLevel.Info,"QSPI cmd={0:X2} len={1} data={2:X8} {3:X8}",ReadDoubleWord(0x284),length,ReadDoubleWord(0x288),ReadDoubleWord(0x28c));
            // Panel row window: cmd 0x02, bytes 00 2A 00 <start hi> <start lo> <end hi> <end lo>
            // (rayneo_lcdc_send_cmd_list before each partial/full transfer).
            if(ReadDoubleWord(0x284)==0x02 && length>=7) {
                var b=new byte[7];
                for(int i=0;i<7;i++) b[i]=(byte)(ReadDoubleWord(0x288+(i/4)*4)>>(24-8*(i%4)));
                if(b[1]==0x2a) { windowStart=(b[3]<<8)|b[4]; windowEnd=(b[5]<<8)|b[6]; }
            }
            var previous=panel.ReadDoubleWord(0);
            uint selections=(1u<<16)|(1u<<23);
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
        // Debug helper: dump emulated memory (e.g. the LVGL frame buffer) to a host file.
        public void DumpRegion(ulong address, int length, string path) {
            System.IO.File.WriteAllBytes(path, machine.GetSystemBus(this).ReadBytes(address, length));
        }
        private int qspiLog=0;
        private int windowStart=-1, windowEnd=-1;
        private void ScanOut()
        {
            uint control=ReadDoubleWord(0x190), address=ReadDoubleWord(0xc0);
            int width=(int)(ReadDoubleWord(0xec)&0xfff),height=(int)((ReadDoubleWord(0xec)>>16)&0xfff);
            int stride=(int)(ReadDoubleWord(0xe0)&0xffff);
            if((control&1)==0 || ((control>>8)&15)!=2 || width<=0 || height<=0 || stride<width*3 || (long)stride*height>16777216 || address==0) {
                this.Log(LogLevel.Warning,"Unsupported scanout: control={0:X} address={1:X} size={2}x{3} stride={4}",control,address,width,height,stride);return;
            }
            LastFrame=machine.GetSystemBus(this).ReadBytes(address,stride*height);
            CompletedFrames++;
            uint cs=(~panel.ReadDoubleWord(0))&((1u<<16)|(1u<<23));
            bool eyeA=(cs&(1u<<16))!=0, eyeB=(cs&(1u<<23))!=0;
            if(!eyeA && !eyeB) eyeA=eyeB=true;                 // LCDC mux without GPIO CS (boot logo path)
            if(stride==RowBytes && width*3<=EyeWidth/2) {
                int firstRow=windowStart>=0 && windowStart<EyeHeight ? windowStart : RowOf(address,height,eyeA?0:1);
                for(int r=0;r<height && firstRow+r<EyeHeight;r++) {
                    int y=firstRow+r; if(y<0) continue;
                    for(int b=0;b<width*3;b++) {
                        byte v=LastFrame[r*stride+b];
                        int x=b*2;
                        if(eyeA) {canvas[y*2*EyeWidth+x]=(byte)((v>>4)*17);canvas[y*2*EyeWidth+x+1]=(byte)((v&15)*17);}
                        if(eyeB) {canvas[y*2*EyeWidth+EyeWidth+x]=(byte)((v>>4)*17);canvas[y*2*EyeWidth+EyeWidth+x+1]=(byte)((v&15)*17);}
                    }
                }
            } else this.Log(LogLevel.Warning,"Non-RayNeo layer geometry {0}x{1} stride {2}; canvas not updated",width,height,stride);
            if(FrameImagePath!=null) QueueFrameWrite();
            if(capturePath!=null) System.IO.File.WriteAllBytes(capturePath,LastFrame);
            if(CompletedFrames<=4) this.Log(LogLevel.Info,"Scanout copied: frame={0} address={1:X} size={2}x{3} stride={4} cs={5:X}",CompletedFrames,address,width,height,stride,cs);
            base.WriteDoubleWord(0x224,0);
            base.WriteDoubleWord(0x1c4,ReadDoubleWord(0x1c4)|0x100400u);
            UpdateIRQ();
        }
        // Full refresh = 279 rows from row 0; remember its address as the eye's base. Other transfers are placed
        // relative to that base (rounded, because the column offset may shift the start by up to +-16 bytes).
        private int RowOf(uint address,int height,int eye)
        {
            if(height>=EyeHeight-1) {bases[eye]=address;return 0;}
            if(bases[eye]==0) return (EyeHeight-height)/2;   // logo before any full refresh: centre it
            long delta=(long)address-bases[eye];
            return (int)System.Math.Floor((delta+RowBytes/2.0)/RowBytes);
        }
        private void UpdateIRQ() {IRQ.Set((ReadDoubleWord(0x1c4)&ReadDoubleWord(0x1c0))!=0);}
        // The Mac app polls FrameImagePath; write it at most ~30 times per host second. A pending
        // update is flushed by a host timer so the last frame of an animation is never lost.
        private void QueueFrameWrite()
        {
            lock(frameLock) {
                var now=System.Diagnostics.Stopwatch.GetTimestamp();
                if(now-lastWrite>=System.Diagnostics.Stopwatch.Frequency/30) {WriteFrame(FrameImagePath);lastWrite=now;framePending=false;return;}
                if(framePending) return;
                framePending=true;
                if(flushTimer==null) flushTimer=new System.Threading.Timer(_=>{lock(frameLock){if(framePending){WriteFrame(FrameImagePath);lastWrite=System.Diagnostics.Stopwatch.GetTimestamp();framePending=false;}}},null,40,System.Threading.Timeout.Infinite);
                else flushTimer.Change(40,System.Threading.Timeout.Infinite);
            }
        }
        // Panel supplies: iv_1v8_en/iv_1v8_disable drive pin 45 (GPIO1 bit 13). With the panel unpowered
        // (iv_panel_screen_off: auto screen-off, sleep) the eyes show nothing, like the real waveguide.
        private bool PanelPowered => (panel.Output & (1u<<13)) != 0;
        private bool lastPowered=true;
        private void OnPanelOutput()
        {
            bool powered=PanelPowered;
            if(powered==lastPowered) return;
            lastPowered=powered;
            if(FrameImagePath!=null) lock(frameLock) { WriteFrame(FrameImagePath); lastWrite=System.Diagnostics.Stopwatch.GetTimestamp(); }
        }
        private void WriteFrame(string path)
        {
            var header=System.Text.Encoding.ASCII.GetBytes(string.Format("P5\n{0} {1}\n255\n",2*EyeWidth,EyeHeight));
            string temporary=path+".tmp";
            var pixels=lastPowered ? canvas : new byte[canvas.Length];
            using(var stream=System.IO.File.Create(temporary)) {stream.Write(header,0,header.Length);stream.Write(pixels,0,pixels.Length);}
            if(System.IO.File.Exists(path)) System.IO.File.Replace(temporary,path,null);
            else System.IO.File.Move(temporary,path);
        }
        // Monitor helper for tests: `lcdc SaveFrame @/path/shot.pgm` writes the current two-eye canvas.
        public void SaveFrame(string path) { lock(frameLock) WriteFrame(path); }
        private readonly object frameLock=new object();
        private System.Threading.Timer flushTimer;
        private long lastWrite;
        private bool framePending;
        private readonly uint[] bases=new uint[2];
        private readonly byte[] canvas=new byte[2*EyeWidth*EyeHeight];
        private readonly IMachine machine;
        private readonly string capturePath;
        private readonly BES1700_GPIO panel;
    }
}
