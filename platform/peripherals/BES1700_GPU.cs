// VeriSilicon GC265 VGLite command-buffer executor (from parallel research, see .local/research/parallel/gpu.md).
// VeriSilicon GC265 "VGLite" command-buffer executor for the stock RayNeo 1.0.4.12 AP driver.
// Evidence (AP 0x10190000 image, see gpu.md): push_state 0x1059f0a8 (0x30010000|addr,data),
// push_clut 0x1059ec4c (0x30000000|count<<16|addr), push_data 0x1059ef40 (0x40000000|qwords,0 + payload),
// push_call 0x1059eeb4 (0x60000000|qwords, address), push_stall 0x1059ee08 (0x10000000|id,0,0x20000000|id,0),
// submit 0x1059ebb0 (END word 0x00000000), vg_lite_kernel SUBMIT -> 0x500 address, 0x504 qwords.
// gpu_irq_handler 0x105a8b00 reads 0x10 (any non-negative value = done, bit31 = bus error) and posts a semaphore.
// NVIC line: nuttx_irq_attach(0x21) in gpu_hal_init 0x105a8bf0 -> connect IRQ to nvic@33.
// Pixel semantics follow the public vg_lite reference (vglite/vg_lite.c); formats/blends not observed in this
// firmware are logged once and skipped rather than approximated silently.
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Peripherals.Miscellaneous;
namespace Antmicro.Renode.Peripherals.Video
{
    public class BES1700_GPU : BES1700_RegisterBank
    {
        public BES1700_GPU(IMachine machine):base(machine) {this.machine=machine;IRQ=new GPIO();}
        public GPIO IRQ {get; private set;}
        public ulong ExecutedSubmits {get; private set;}
        public bool TraceCommands {get; set;}

        public override uint ReadDoubleWord(long offset) {
            switch(offset) {
                case 0x4: return 0xb05u;                 // VG_LITE_HW_IDLE_STATE: execution is synchronous
                case 0x10: {uint v=intrStatus;intrStatus=0;IRQ.Unset();return v;}
                case 0x20: return 0x265;                 // chip id checked by vg_lite_init 0x105a0720
                case 0x24: return 0x2002;
                case 0x30: return 0x420;
                case 0x508: return fetchPos;
                default: return base.ReadDoubleWord(offset);
            }
        }
        public override void WriteDoubleWord(long offset,uint value) {
            base.WriteDoubleWord(offset,value);
            if(offset==0x504 && value!=0) {
                bus=machine.GetSystemBus(this);
                uint address=base.ReadDoubleWord(0x500);
                uint ev=0; bool ended=false;
                try { ended=Run(address,(long)value*8,0,ref ev); }
                catch(Exception e) { this.Log(LogLevel.Error,"GPU command buffer {0:X} failed: {1}",address,e.Message); intrStatus|=0x80000000u; }
                ExecutedSubmits++;
                intrStatus|=ended?(1u<<(int)(ev&31)):1u;
                IRQ.Set();
            }
        }

        // ---------------- command stream ----------------
        private bool Run(uint address,long bytes,int depth,ref uint ev) {
            long pos=0;
            while(pos+8<=bytes) {
                uint w0=bus.ReadDoubleWord(address+(ulong)pos), w1=bus.ReadDoubleWord(address+(ulong)pos+4);
                fetchPos=(uint)(address+pos);
                uint op=w0>>28;
                if(TraceCommands) this.Log(LogLevel.Noisy,"CMD {0:X8} {1:X8}",w0,w1);
                switch(op) {
                case 0x0: ev=w0&0x1f; return true;                           // END(event)
                case 0x1: case 0x2: pos+=8; break;                          // SEMAPHORE / STALL
                case 0x3: {
                    int count=(int)((w0>>16)&0xfff); uint reg=w0&0xffff;
                    if(count<=1 && (w0&0x0fff0000)==0x00010000) {SetState(reg,w1);pos+=8;break;}
                    for(int i=0;i<count;i++) SetState(reg+(uint)i,bus.ReadDoubleWord(address+(ulong)(pos+4+4*i)));
                    pos+=((4+4*count+7)/8)*8; break;                       // STATES(count,addr), padded to qword
                }
                case 0x4: {                                                 // DATA(qwords) + payload
                    int q=(int)(w0&0x0fffffff);
                    var payload=bus.ReadBytes(address+(ulong)pos+8,q*8);
                    OnData(payload);
                    pos+=8+(long)q*8; break;
                }
                case 0x6: {                                                 // CALL(qwords,address)
                    if(depth>4) {this.Log(LogLevel.Warning,"CALL nesting too deep");pos+=8;break;}
                    uint e2=0; Run(w1,(long)(w0&0x0fffffff)*8,depth+1,ref e2); pos+=8; break;
                }
                case 0x7: return false;                                     // RETURN
                case 0x8: pos+=8; break;                                    // NOP (reference: 0x80000000)
                default:
                    Once("op"+op,"Unknown VGLite opcode {0:X8}",w0); pos+=8; break;
                }
            }
            return false;
        }
        private void SetState(uint reg,uint value) {
            state[reg]=value;
            if(reg==0xa28) lastSrcBank=1; else if(reg==0xa29) lastSrcBank=0;
            if(reg>=0xb00 && reg<0xc00) clut[reg-0xb00]=value;            // push_clut 0x1059ec4c via vg_lite_set_CLUT
        }
        private uint S(uint reg) {return state.TryGetValue(reg,out var v)?v:0;}
        private float F(uint reg) {return BitConverter.ToSingle(BitConverter.GetBytes(S(reg)),0);}

        // 0xA00 control: [1:0] 1=rectangle; bit2 = PE clear (vg_lite_clear 0x1059f86c); otherwise path.
        // [11:8] blend (convert_blend 0x1059e5ec), [14:12] image mode, bit15 transparency.
        private void OnData(byte[] payload) {
            uint ctrl=S(0xa00);
            if((ctrl&4)!=0 && (ctrl&3)==0) {PeClear();return;}
            if((ctrl&3)==1) {
                int x=BitConverter.ToUInt16(payload,0),y=BitConverter.ToUInt16(payload,2),w=BitConverter.ToUInt16(payload,4),h=BitConverter.ToUInt16(payload,6);
                Rectangle(x,y,w,h,ctrl);return;
            }
            Path(payload,ctrl);
        }

        // ---------------- target ----------------
        private struct Target {public uint Address,Format;public int Stride,Width,Height;}
        private Target GetTarget() {
            // set_render_target 0x1059f12c: 0xA10 format, 0xA11 address, 0xA12 stride(|tile), 0xA13 width|height<<16.
            var t=new Target{Format=S(0xa10)&0x43f,Address=S(0xa11),Stride=(int)(S(0xa12)&0xfffffff),Width=(int)(S(0xa13)&0xffff),Height=(int)(S(0xa13)>>16)};
            if((S(0xa12)&0x10000000)!=0) Once("tile","Tiled target not implemented");
            return t;
        }
        private static int TargetBpp(uint f) {
            switch(f&0x40f) {case 0x0: case 0x6: return 1; case 0x1: case 0x4: case 0x5: case 0x400: return 2; case 0x9: case 0xa: return 3; case 0x2: case 0x3: return 4; default: return 0;}
        }

        private void PeClear() {
            var t=GetTarget(); FillRect(t,0,0,t.Width,t.Height,Unpack(S(0xa02)),0,false);
        }
        private void Rectangle(int x,int y,int w,int h,uint ctrl) {
            var t=GetTarget();
            uint image=(ctrl>>12)&7, blend=(ctrl>>8)&0xf;
            if(image==0 && blend==0) {FillRect(t,x,y,w,h,Unpack(S(0xa02)),0,false);return;} // vg_lite_clear path
            Blit(t,x,y,w,h,ctrl);
        }

        // ---------------- pixel access ----------------
        private struct C {public float R,G,B,A;}
        private static C Unpack(uint abgr) {return new C{R=(abgr&255)/255f,G=((abgr>>8)&255)/255f,B=((abgr>>16)&255)/255f,A=(abgr>>24)/255f};} // vg_lite colour = 0xAABBGGRR
        private C ReadTarget(Target t,byte[] row,int x) {
            int bpp=TargetBpp(t.Format); int o=x*bpp; uint f=t.Format; int sw=(int)((f>>4)&3);
            switch(f&0x40f) {
            case 0x0: return new C{A=row[o]/255f};
            case 0x6: {float l=row[o]/255f;return new C{R=l,G=l,B=l,A=1};}
            case 0x1: {int v=row[o]|(row[o+1]<<8);return Swz565(v,sw);}
            case 0x2: case 0x3: return Swz8888(row,o,sw,(f&0xf)==0x2);
            case 0x9: return sw==2?new C{R=row[o]/255f,G=row[o+1]/255f,B=row[o+2]/255f,A=1}:new C{B=row[o]/255f,G=row[o+1]/255f,R=row[o+2]/255f,A=1};
            case 0xa: {var c=Swz565(row[o]|(row[o+1]<<8),0);c.A=row[o+2]/255f;return c;}
            default: return new C();
            }
        }
        private void WriteTarget(Target t,byte[] row,int x,C c) {
            int bpp=TargetBpp(t.Format); int o=x*bpp; uint f=t.Format; int sw=(int)((f>>4)&3);
            byte r=B8(c.R),g=B8(c.G),b=B8(c.B),a=B8(c.A);
            switch(f&0x40f) {
            case 0x0: row[o]=a;break;
            case 0x6: row[o]=B8(0.2126f*c.R+0.7152f*c.G+0.0722f*c.B);break;
            case 0x1: {int v=sw==2?((b>>3)<<11)|((g>>2)<<5)|(r>>3):((r>>3)<<11)|((g>>2)<<5)|(b>>3);row[o]=(byte)v;row[o+1]=(byte)(v>>8);break;}
            case 0x2: case 0x3: {
                if((f&0xf)==0x2) a=255;
                switch(sw){case 0: row[o]=b;row[o+1]=g;row[o+2]=r;row[o+3]=a;break; case 1: row[o]=a;row[o+1]=b;row[o+2]=g;row[o+3]=r;break;
                           case 2: row[o]=r;row[o+1]=g;row[o+2]=b;row[o+3]=a;break; default: row[o]=a;row[o+1]=r;row[o+2]=g;row[o+3]=b;break;}
                break;}
            case 0x9: if(sw==2){row[o]=r;row[o+1]=g;row[o+2]=b;}else{row[o]=b;row[o+1]=g;row[o+2]=r;} break;
            case 0xa: {int v=((r>>3)<<11)|((g>>2)<<5)|(b>>3);row[o]=(byte)v;row[o+1]=(byte)(v>>8);row[o+2]=a;break;}
            }
        }
        private static C Swz565(int v,int sw) {
            float hi=((v>>11)&31)/31f, mid=((v>>5)&63)/63f, lo=(v&31)/31f;
            return sw==2?new C{R=lo,G=mid,B=hi,A=1}:new C{R=hi,G=mid,B=lo,A=1};          // 0x01/0x05 = std RGB565 (R high)
        }
        private static C Swz8888(byte[] d,int o,int sw,bool x) {
            C c;
            switch(sw){case 0: c=new C{B=d[o]/255f,G=d[o+1]/255f,R=d[o+2]/255f,A=d[o+3]/255f};break;   // BGRA = LVGL ARGB8888
                       case 1: c=new C{A=d[o]/255f,B=d[o+1]/255f,G=d[o+2]/255f,R=d[o+3]/255f};break;
                       case 2: c=new C{R=d[o]/255f,G=d[o+1]/255f,B=d[o+2]/255f,A=d[o+3]/255f};break;
                       default: c=new C{A=d[o]/255f,R=d[o+1]/255f,G=d[o+2]/255f,B=d[o+3]/255f};break;}
            if(x) c.A=1; return c;
        }
        private static byte B8(float v) {return (byte)Math.Max(0,Math.Min(255,(int)Math.Round(v*255f)));}

        // ---------------- blending ----------------
        private static C Blend(C s,C d,uint mode,float cov) {
            float sa=s.A*cov; C o;
            switch(mode) {
            case 0x0: o=new C{R=Lerp(d.R,s.R,cov),G=Lerp(d.G,s.G,cov),B=Lerp(d.B,s.B,cov),A=Lerp(d.A,s.A,cov)};break; // BLEND_NONE
            case 0x1: o=new C{R=s.R*sa+d.R*(1-sa),G=s.G*sa+d.G*(1-sa),B=s.B*sa+d.B*(1-sa),A=sa+d.A*(1-sa)};break;       // SRC_OVER
            case 0x2: {float da=d.A;o=new C{R=d.R*da+s.R*sa*(1-da),G=d.G*da+s.G*sa*(1-da),B=d.B*da+s.B*sa*(1-da),A=da+sa*(1-da)};break;} // DST_OVER
            case 0x3: o=new C{R=Lerp(d.R,s.R,cov),G=Lerp(d.G,s.G,cov),B=Lerp(d.B,s.B,cov),A=Lerp(d.A,s.A*d.A,cov)};break; // SRC_IN
            case 0x4: o=new C{R=d.R,G=d.G,B=d.B,A=Lerp(d.A,d.A*s.A,cov)};break;                                          // DST_IN
            case 0x5: o=Mix(s,d,sa,(a,b)=>a*b);break;                                                                   // MULTIPLY
            case 0x6: o=Mix(s,d,sa,(a,b)=>a+b-a*b);break;                                                               // SCREEN
            case 0x7: o=Mix(s,d,sa,Math.Min);break;
            case 0x8: o=Mix(s,d,sa,Math.Max);break;
            case 0x9: o=new C{R=Math.Min(1,d.R+s.R*sa),G=Math.Min(1,d.G+s.G*sa),B=Math.Min(1,d.B+s.B*sa),A=Math.Min(1,d.A+sa)};break; // ADDITIVE
            case 0xa: case 0xc: o=new C{R=Math.Max(0,d.R-s.R*sa),G=Math.Max(0,d.G-s.G*sa),B=Math.Max(0,d.B-s.B*sa),A=d.A};break;    // SUBTRACT
            default: o=new C{R=s.R*sa+d.R*(1-sa),G=s.G*sa+d.G*(1-sa),B=s.B*sa+d.B*(1-sa),A=sa+d.A*(1-sa)};break;
            }
            return o;
        }
        private static C Mix(C s,C d,float sa,Func<float,float,float> f) {
            return new C{R=Lerp(d.R,f(s.R,d.R),sa),G=Lerp(d.G,f(s.G,d.G),sa),B=Lerp(d.B,f(s.B,d.B),sa),A=sa+d.A*(1-sa)};
        }
        private static float Lerp(float a,float b,float t) {return a+(b-a)*t;}

        // ---------------- clipping ----------------
        private void Clip(Target t,ref int x0,ref int y0,ref int x1,ref int y1,bool tess) {
            x0=Math.Max(x0,0);y0=Math.Max(y0,0);x1=Math.Min(x1,t.Width);y1=Math.Min(y1,t.Height);
            if(tess && S(0xa3a)!=0) {                       // vg_lite_draw repeats the path per tessellation window
                int tx=(int)(S(0xa39)&0xffff),ty=(int)(S(0xa39)>>16),tw=(int)(S(0xa3a)&0xffff),th=(int)(S(0xa3a)>>16);
                x0=Math.Max(x0,tx);y0=Math.Max(y0,ty);x1=Math.Min(x1,tx+tw);y1=Math.Min(y1,ty+th);
            }
        }

        private void FillRect(Target t,int x,int y,int w,int h,C c,uint blend,bool doBlend) {
            int x1=x+w,y1=y+h; Clip(t,ref x,ref y,ref x1,ref y1,false);
            int bpp=TargetBpp(t.Format); if(bpp==0) {Once("tf"+t.Format,"Unsupported target format {0:X}",t.Format);return;}
            if(x>=x1||y>=y1) return;
            var r=ReadRect(t,x,y,x1,y1,bpp); var row=new byte[r.RowLen];
            for(int yy=y;yy<y1;yy++) {
                r.Get(yy-y,row);
                for(int xx=0;xx<x1-x;xx++) WriteTarget(t,row,xx,doBlend?Blend(c,ReadTarget(t,row,xx),blend,1):c);
                r.Put(yy-y,row);
            }
            r.Write(bus);
        }

        // ---------------- image source ----------------
        private struct Src {public uint Address,Format,Filter;public int Stride,Width,Height;public bool Valid;}
        private Src GetSource() {
            // vg_lite_blit_rect 0x1059f9b4 writes 0xA25 format|filter, 0xA29 address, 0xA2B stride, 0xA2F w|h<<16.
            // vg_lite_draw_pattern also writes the 0xA24/0xA28/0xA2A/0xA2E bank; prefer the bank that was most recently given an address.
            uint fA25=S(0xa25),fA24=S(0xa24);
            bool useB=lastSrcBank==1 && S(0xa28)!=0;
            uint f=useB?fA24:fA25;
            // 0x01000100 = src_premultiply_enable (vg_lite.c), not part of the format code.
            return new Src{Valid=true,Format=f&~0x30000u&~0x01000100u,Filter=f&0x30000,Address=useB?S(0xa28):S(0xa29),
                           Stride=(int)((useB?S(0xa2a):S(0xa2b))&0xfffffff),
                           Width=(int)((useB?S(0xa2e):S(0xa2f))&0xffff),Height=(int)((useB?S(0xa2e):S(0xa2f))>>16)};
        }
        private int lastSrcBank;
        private C Fetch(Src s,int x,int y,Dictionary<int,byte[]> rows) {
            if(x<0||y<0||x>=s.Width||y>=s.Height) return new C();
            if(!rows.TryGetValue(y,out var row)) {row=bus.ReadBytes(s.Address+(ulong)(y*s.Stride),s.Stride);rows[y]=row;}
            uint f=s.Format;
            if((f&0x60000000)==0x20000000) {int o=x*3;return (f&0x30)==0x20?new C{R=row[o]/255f,G=row[o+1]/255f,B=row[o+2]/255f,A=1}:new C{B=row[o]/255f,G=row[o+1]/255f,R=row[o+2]/255f,A=1};} // BGR888/RGB888
            if((f&0x60000000)==0x40000000) {int o=x*3;var c=Swz565(row[o]|(row[o+1]<<8),0);c.A=row[o+2]/255f;return c;}                                    // 8565 (LVGL ARGB8565)
            uint idx=f&0xe00;
            if(idx!=0 && (f&0x1000)==0) {                                     // INDEX_1/2/4/8 with CLUT from 0xB00 states
                int bits=idx==0x200?1:idx==0x400?2:idx==0x600?4:8; int bit=x*bits;
                int v=(row[bit>>3]>>(8-bits-(bit&7)))&((1<<bits)-1);           // MSB-first (LVGL I1/I2/I4 order)
                uint p=clut.TryGetValue((uint)v,out var e)?e:0;                // palette word as stored by LVGL lv_color32_t (0xAARRGGBB)
                return new C{B=(p&255)/255f,G=((p>>8)&255)/255f,R=((p>>16)&255)/255f,A=(p>>24)/255f};
            }
            switch(f) {
            case 0x0: {float l=row[x]/255f;return new C{R=l,G=l,B=l,A=1};}                                   // L8
            case 0x2: return new C{R=1,G=1,B=1,A=row[x]/255f};                                                // A8
            case 0x1: {int v=(row[x>>1]>>((x&1)==0?4:0))&15;return new C{R=1,G=1,B=1,A=v/15f};}              // A4 (high nibble first, LVGL)
            case 0x80003: {int v=(row[x>>3]>>(7-(x&7)))&1;return new C{R=1,G=1,B=1,A=v};}                     // A1
            case 0x80001: {int v=(row[x>>2]>>(6-2*(x&3)))&3;return new C{R=1,G=1,B=1,A=v/3f};}               // A2
            case 0x80000: {int v=(row[x>>1]>>((x&1)==0?4:0))&15;float l=v/15f;return new C{R=l,G=l,B=l,A=1};} // L4
            }
            int sw=(int)((f>>4)&3);
            switch(f&0xf) {
            case 0x5: return Swz565(row[x*2]|(row[x*2+1]<<8),sw==2?2:0);
            case 0x6: return Swz8888(row,x*4,sw,true);
            case 0x7: return Swz8888(row,x*4,sw,false);
            case 0x3: {int v=row[x*2]|(row[x*2+1]<<8);return new C{B=(v&15)/15f,G=((v>>4)&15)/15f,R=((v>>8)&15)/15f,A=(v>>12)/15f};} // BGRA4444
            case 0x4: {int v=row[x*2]|(row[x*2+1]<<8);return new C{B=(v&31)/31f,G=((v>>5)&31)/31f,R=((v>>10)&31)/31f,A=v>>15};}       // BGRA5551
            }
            Once("sf"+f,"Unsupported source format {0:X}",f);return new C();
        }
        private C Sample(Src s,float u,float v,Dictionary<int,byte[]> rows) {
            if(s.Filter==0) return Fetch(s,(int)Math.Floor(u),(int)Math.Floor(v),rows);   // VG_LITE_FILTER_POINT
            float fx=u-0.5f,fy=v-0.5f; int x0=(int)Math.Floor(fx),y0=(int)Math.Floor(fy); float ax=fx-x0,ay=fy-y0;
            C a=Fetch(s,x0,y0,rows),b=Fetch(s,x0+1,y0,rows),c=Fetch(s,x0,y0+1,rows),d=Fetch(s,x0+1,y0+1,rows);
            Func<float,float,float,float,float> bl=(p,q,r,t)=>(p*(1-ax)+q*ax)*(1-ay)+(r*(1-ax)+t*ax)*ay;
            return new C{R=bl(a.R,b.R,c.R,d.R),G=bl(a.G,b.G,c.G,d.G),B=bl(a.B,b.B,c.B,d.B),A=bl(a.A,b.A,c.A,d.A)};
        }
        // Inverse-mapped texture steps (0xA18..0xA22, reference vg_lite_blit): u=(c0+x*x0+y*y0)/w*W, v=(c1+x*x1+y*y1)/w*H, w=c2+x*x2+y*y2.
        private bool Uv(Src s,int x,int y,out float u,out float v) {
            var m=uvm;
            float w=m[2]+x*m[6]+y*m[10];
            if(Math.Abs(w)<1e-9f) {u=v=-1;return false;}
            u=(m[0]+x*m[4]+y*m[8])/w*s.Width; v=(m[1]+x*m[5]+y*m[9])/w*s.Height; return true;
        }
        // Paint state read once per primitive instead of per pixel: colour 0xA02, texture steps 0xA18..0xA22.
        private void PrepPaint() {
            paintCol=Unpack(S(0xa02));
            for(int i=0;i<11;i++) uvm[i]=F(0xa18+(uint)i);
        }
        private C paintCol;
        private readonly float[] uvm=new float[11];
        // A target rectangle read and written back as one block: every bus write into RAM from a model
        // invalidates translated code on all CPUs, so one write per primitive instead of one per row.
        private sealed class Rect {
            public byte[] Data; public ulong Base; public int Stride, RowLen;
            public void Get(int r,byte[] row) {Array.Copy(Data,r*Stride,row,0,RowLen);}
            public void Put(int r,byte[] row) {Array.Copy(row,0,Data,r*Stride,RowLen);}
            public void Write(Antmicro.Renode.Peripherals.Bus.IBusController bus) {bus.WriteBytes(Data,Base);}
        }
        private Rect ReadRect(Target t,int x0,int y0,int x1,int y1,int bpp) {
            int rowLen=(x1-x0)*bpp, stride=Math.Max(t.Stride,rowLen);
            ulong b=t.Address+(ulong)(y0*t.Stride+x0*bpp);
            if(t.Stride<rowLen) stride=rowLen;      // not expected; keep rows apart in the buffer
            int len=(y1-y0-1)*stride+rowLen;
            if(t.Stride<rowLen) {var d=new byte[len]; for(int r=0;r<y1-y0;r++) Array.Copy(bus.ReadBytes(b+(ulong)(r*t.Stride),rowLen),0,d,r*stride,rowLen); return new Rect{Data=d,Base=b,Stride=stride,RowLen=rowLen};}
            return new Rect{Data=bus.ReadBytes(b,len),Base=b,Stride=stride,RowLen=rowLen};
        }
        private C Paint(uint ctrl,Src s,int x,int y,Dictionary<int,byte[]> rows,out bool inside) {
            inside=true;
            uint image=(ctrl>>12)&7; C col=paintCol;
            if(!s.Valid || image==0) return col;
            if(!Uv(s,x,y,out float u,out float v) || u<0||v<0||u>=s.Width||v>=s.Height) {inside=false;return new C();}
            C t=Sample(s,u,v,rows);
            switch(image) {
            case 1: return t;                                                                    // NORMAL
            case 2: return new C{R=t.R*col.R,G=t.G*col.G,B=t.B*col.B,A=t.A*col.A};               // MULTIPLY (LVGL opacity / tint)
            case 3: return new C{R=col.R,G=col.G,B=col.B,A=t.A*col.A};                           // STENCIL (A8/A4 glyphs)
            case 6: return new C{R=col.R,G=col.G,B=col.B,A=t.A};                                 // RECOLOR
            default: Once("im"+image,"Image mode {0:X} not implemented",image); return t;
            }
        }

        private void Blit(Target t,int x,int y,int w,int h,uint ctrl) {
            int x1=x+w,y1=y+h; Clip(t,ref x,ref y,ref x1,ref y1,false);
            int bpp=TargetBpp(t.Format); if(bpp==0||x>=x1||y>=y1) return;
            var s=GetSource(); var rows=new Dictionary<int,byte[]>(); uint blend=(ctrl>>8)&0xf; PrepPaint();
            var r=ReadRect(t,x,y,x1,y1,bpp); var row=new byte[r.RowLen];
            for(int yy=y;yy<y1;yy++) {
                r.Get(yy-y,row);
                for(int xx=x;xx<x1;xx++) {
                    C p=Paint(ctrl,s,xx,yy,rows,out bool inside); if(!inside) continue;
                    WriteTarget(t,row,xx-x,Blend(p,ReadTarget(t,row,xx-x),blend,1));
                }
                r.Put(yy-y,row);
            }
            r.Write(bus);
        }

        // ---------------- paths ----------------
        // 0xA34 path control (vg_lite_draw 0x105a1fd6): bit24 always, [21:20] format (0 S8,1 S16,2 S32,3 FP32),
        // [1:0] quality, bit4 even-odd (fill_rule==0x1900). Matrix 0xA40..0xA45 = m00 m01 m02 m10 m11 m12.
        private void Path(byte[] d,uint ctrl) {
            uint pc=S(0xa34); int fmt=(int)((pc>>20)&3); int size=fmt==0?1:fmt==1?2:4; bool evenOdd=(pc&0x10)!=0;
            float m00=F(0xa40),m01=F(0xa41),m02=F(0xa42),m10=F(0xa43),m11=F(0xa44),m12=F(0xa45);
            if(F(0xacd)!=m02 || F(0xace)!=m12) Once("acd","0xACD/0xACE differ from translation; treating matrix as affine");
            var segs=new List<float[]>(); float sx=0,sy=0,cx=0,cy=0; int p=0;
            Func<float> rd=()=>{float v;switch(fmt){case 0:v=(sbyte)d[p];break;case 1:v=BitConverter.ToInt16(d,p);break;case 2:v=BitConverter.ToInt32(d,p);break;default:v=BitConverter.ToSingle(d,p);break;}p+=size;return v;};
            Action<float,float,float,float> line=(ax,ay,bx,by)=>segs.Add(new[]{m00*ax+m01*ay+m02,m10*ax+m11*ay+m12,m00*bx+m01*by+m02,m10*bx+m11*by+m12});
            while(p<d.Length) {
                int op=d[p]; p+=size;                                          // opcode byte, padded to the coordinate size
                bool rel=(op&1)==1 && op>=3;
                if(op==0) break;
                if(op==1){line(cx,cy,sx,sy);cx=sx;cy=sy;continue;}
                if(p+size>d.Length) break;
                switch(op&~1) {
                case 2: {float x=rd(),y=rd(); if(rel){x+=cx;y+=cy;} if(cx!=sx||cy!=sy) line(cx,cy,sx,sy); cx=sx=x;cy=sy=y; break;}
                case 4: {float x=rd(),y=rd(); if(rel){x+=cx;y+=cy;} line(cx,cy,x,y);cx=x;cy=y;break;}
                case 6: {float x1=rd(),y1=rd(),x=rd(),y=rd(); if(rel){x1+=cx;y1+=cy;x+=cx;y+=cy;}
                         float ox=cx,oy=cy; for(int i=1;i<=16;i++){float t=i/16f,u=1-t;float nx=u*u*ox+2*u*t*x1+t*t*x,ny=u*u*oy+2*u*t*y1+t*t*y;line(cx,cy,nx,ny);cx=nx;cy=ny;} break;}
                case 8: {float x1=rd(),y1=rd(),x2=rd(),y2=rd(),x=rd(),y=rd(); if(rel){x1+=cx;y1+=cy;x2+=cx;y2+=cy;x+=cx;y+=cy;}
                         float ox=cx,oy=cy; for(int i=1;i<=24;i++){float t=i/24f,u=1-t;float nx=u*u*u*ox+3*u*u*t*x1+3*u*t*t*x2+t*t*t*x,ny=u*u*u*oy+3*u*u*t*y1+3*u*t*t*y2+t*t*t*y;line(cx,cy,nx,ny);cx=nx;cy=ny;} break;}
                default: Once("pop"+op,"Path opcode {0:X} not implemented (arcs are converted by vg_lite before upload)",op); return;
                }
            }
            if(cx!=sx||cy!=sy) line(cx,cy,sx,sy);
            Fill(segs,evenOdd,ctrl,(pc&3)!=0);
        }
        private void Fill(List<float[]> segs,bool evenOdd,uint ctrl,bool aa) {
            if(segs.Count==0) return;
            var t=GetTarget(); int bpp=TargetBpp(t.Format); if(bpp==0) {Once("tf"+t.Format,"Unsupported target format {0:X}",t.Format);return;}
            float minx=float.MaxValue,miny=float.MaxValue,maxx=float.MinValue,maxy=float.MinValue;
            foreach(var s in segs){minx=Math.Min(minx,Math.Min(s[0],s[2]));maxx=Math.Max(maxx,Math.Max(s[0],s[2]));miny=Math.Min(miny,Math.Min(s[1],s[3]));maxy=Math.Max(maxy,Math.Max(s[1],s[3]));}
            int x0=(int)Math.Floor(minx),y0=(int)Math.Floor(miny),x1=(int)Math.Ceiling(maxx)+1,y1=(int)Math.Ceiling(maxy)+1;
            Clip(t,ref x0,ref y0,ref x1,ref y1,true); if(x0>=x1||y0>=y1) return;
            int sub=aa?4:1; var cov=new float[x1-x0];
            var s2=GetSource(); var rows=new Dictionary<int,byte[]>(); uint blend=(ctrl>>8)&0xf; PrepPaint();
            var rect=ReadRect(t,x0,y0,x1,y1,bpp); var row=new byte[rect.RowLen]; bool anyDirty=false;
            // Edges sorted by their top; the sample rows fy only increase, so an edge joins the active list once
            // fy reaches its top and leaves it for good once fy reaches its bottom (the same lo<=fy<hi test as before).
            var edges=new List<float[]>(); foreach(var s in segs) if(s[1]!=s[3]) edges.Add(s);
            edges.Sort((a,b)=>Math.Min(a[1],a[3]).CompareTo(Math.Min(b[1],b[3])));
            var active=new List<float[]>(); int next=0;
            var xk=new float[edges.Count]; var xd=new int[edges.Count];
            for(int y=y0;y<y1;y++) {
                Array.Clear(cov,0,cov.Length);
                for(int k=0;k<sub;k++) {
                    float fy=y+(k+0.5f)/sub;
                    while(next<edges.Count&&Math.Min(edges[next][1],edges[next][3])<=fy) active.Add(edges[next++]);
                    active.RemoveAll(s=>fy>=Math.Max(s[1],s[3]));
                    int n=0;
                    foreach(var s in active) {
                        float ay=s[1],by=s[3];
                        xd[n]=by>ay?1:-1; xk[n++]=s[0]+(fy-ay)*(s[2]-s[0])/(by-ay);
                    }
                    // Crossings with equal x bound an empty span, so their order does not change the coverage.
                    Array.Sort(xk,xd,0,n);
                    int wind=0;
                    for(int i=0;i+1<n;i++) {
                        wind+=xd[i]; bool inside=evenOdd?(i&1)==0:wind!=0;
                        if(!inside) continue;
                        float a=Math.Max(xk[i],x0),b=Math.Min(xk[i+1],x1); if(b<=a) continue;
                        for(int px=(int)Math.Floor(a);px<Math.Ceiling(b)&&px<x1;px++) {
                            float c=Math.Min(b,px+1)-Math.Max(a,px); if(c>0) cov[px-x0]+=(aa?c:(c>=0.5f||(a<=px+0.5f&&b>px+0.5f)?1:0))/sub;
                        }
                    }
                }
                rect.Get(y-y0,row); bool dirty=false;
                for(int i=0;i<cov.Length;i++) {
                    float c=Math.Min(1,cov[i]); if(c<=0) continue;
                    C p=Paint(ctrl,s2,x0+i,y,rows,out bool inside); if(!inside) continue;
                    WriteTarget(t,row,i,Blend(p,ReadTarget(t,row,i),blend,c)); dirty=true;
                }
                if(dirty) {rect.Put(y-y0,row); anyDirty=true;}
            }
            if(anyDirty) rect.Write(bus);
        }

        private void Once(string key,string fmt,params object[] args) {if(seen.Add(key)) this.Log(LogLevel.Warning,fmt,args);}
        private readonly IMachine machine;
        private Antmicro.Renode.Peripherals.Bus.IBusController bus;
        private uint intrStatus,fetchPos;
        private readonly Dictionary<uint,uint> state=new Dictionary<uint,uint>();
        private readonly Dictionary<uint,uint> clut=new Dictionary<uint,uint>();
        private readonly HashSet<string> seen=new HashSet<string>();
    }
}
