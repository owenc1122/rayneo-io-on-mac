// BES1700 BT controller digital block (CEVA RW-IP style dual-mode baseband), one instance per IP:
// 0x6d040000 (exchange table at 0x6d020000, common IRQ = BTC IRQ 1) and 0x6d060000
// (exchange table at 0x6d070000, common IRQ = BTC IRQ 39). Semantics below are taken from how
// the stock BTC firmware (rwip/sch_prog code at 0x60485xxx/0x60474xxx) uses the registers.
//
// Common block (+0x000):
//   0x00  control; bit31 soft reset (self-clearing), bit27 SW interrupt request (-> INTSTAT1 bit3)
//   0x18  INTCNTL1 (mask) / 0x1c INTSTAT1 (masked status) / 0x20 INTACK1 (write 1 to clear)
//         bit3 SWINT, bit5/6/7 timestamp target 1/2/3, bit15 activity FIFO
//   0x24  ACTFIFOSTAT: [27:24] current ET index, [31:28] skipped ET index, bit1 end of activity,
//         bit2 skip, bit3/bit4 TX/RX frame (unused here); acking INTSTAT1 bit15 pops one entry
//   0xe8/0xec, 0xf0/0xf4, 0xf8/0xfc  timer targets: half-slot clock (28 bit) and 624-halfus
//   0x100 bit31: sample the half-slot clock into 0x100 and the fine counter (624..0) into 0x104
//   0x110 ACTSCHCNTL: bit31 start activity, [3:0] ET index
// Exchange table entry (16 bytes): +0 ctrl ([2:0] mode 1=BT 2=BLE, [5:3] status),
//   +2/+4 raw start half-slot (16+12 bits), +6 624-halfus, +0xa max duration (bit15: half-slots,
//   else microseconds). Status: 1 programmed, 2 started, 3 ended normally, 6 skipped.
// No radio: activities run for their programmed duration and end without RX traffic.
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Logging;
using Antmicro.Renode.Time;
using Antmicro.Renode.Peripherals.Timers;
namespace Antmicro.Renode.Peripherals.Miscellaneous
{
    public sealed class BES1700_BTController : BES1700_RegisterBank, IGPIOSender
    {
        public BES1700_BTController(IMachine machine, uint versionWord = 0, ulong exchangeTable = 0):base(machine) {
            this.machine=machine;
            this.versionWord=versionWord;
            this.exchangeTable=exchangeTable;
            IRQ=new GPIO();
            clock=new LimitTimer(machine.ClockSource,TicksPerSecond,this,"btFineClock",uint.MaxValue,
                direction:Direction.Ascending,enabled:true,eventEnabled:false,autoUpdate:true);
            alarm=new LimitTimer(machine.ClockSource,TicksPerSecond,this,"btAlarm",1,
                direction:Direction.Ascending,enabled:false,workMode:WorkMode.OneShot,eventEnabled:true,autoUpdate:true);
            // Runs inline: cores execute serially (make-resc.py), so the clock and MMIO never race.
            // Deferring it (ScheduleAction) made activities start late and get skipped.
            alarm.LimitReached+=()=>{ lock(sync) Process(); };
        }
        public GPIO IRQ { get; }
        public bool TraceEvents { get; set; }

        public override void WriteDoubleWord(long offset,uint value) {
            lock(sync) {
            // Stock controller initialization requests bit 31 then waits for it to clear.
            // Reset the digital control/interrupt state synchronously; preserve RF setup.
            if(offset==0 && (value&0x80000000u)!=0) {
                for(long o=0;o<=0x30;o+=4)base.WriteDoubleWord(o,0);
                value&=0x7fffffffu;
                raw=0; fifo.Clear(); pending.Clear(); current=-1; for(int i=0;i<3;i++) armed[i]=false;
            }
            if(offset==0 && (value&0x08000000u)!=0) { value&=~0x08000000u; raw|=SwInt; }
            // Second core control block at +0x400 (written by BTC init right after the version
            // check): bit 31 is a self-clearing soft reset the firmware polls for.
            // Same for the third block at +0x800 (version 0x0B001200).
            if((offset==0x400 || offset==0x800) && (value&0x80000000u)!=0) {
                for(long o=offset+8;o<=offset+0x30;o+=4) base.WriteDoubleWord(o,0);
                value&=0x7fffffffu;
            }
            if(offset==0x100 && (value&0x80000000u)!=0) {
                // Firmware reads a 28-bit half-slot clock and a 625-step fine counter.
                // One half-slot is 312.5 us; capture both from the same virtual instant.
                ulong ticks=Now;
                value=(uint)((ticks/HalfSlot)&ClockMask);
                base.WriteDoubleWord(0x104,(uint)(HalfSlot-1-ticks%HalfSlot));
                base.WriteDoubleWord(0x9c4,(uint)(ticks/2));
            }
            // +0x100 bit 30: clock adjust request; the controller polls until the hardware clears it.
            if(offset==0x100 && (value&0x40000000u)!=0) value&=~0x40000000u;
            if(offset==IntAck) { Ack(value); Update(); return; }
            base.WriteDoubleWord(offset,value);
            switch(offset) {
                case IntCntl: break;
                case 0xec: Arm(0); break;
                case 0xf4: Arm(1); break;
                case 0xfc: Arm(2); break;
                case 0x110:
                    if((value&0x80000000u)!=0 && exchangeTable!=0) Program((int)(value&0xf));
                    break;
            }
            Process();
            }
        }
        // Core IP versions the BTC init asserts on the radio block: +0x404 = 0x0B000600, +0x804 = 0x0B001200.
        public override uint ReadDoubleWord(long offset) {
            if(offset==0x404 && versionWord!=0) return versionWord;
            if(offset==0x804 && versionWord!=0) return 0x0b001200;      // second core block version
            lock(sync) {
                if(offset==IntStat) { Process(); return raw&base.ReadDoubleWord(IntCntl); }
                if(offset==0x14) return raw;
                if(offset==FifoStat) return fifo.Count>0 ? fifo.Peek() : 0;
            }
            return base.ReadDoubleWord(offset);
        }

        private void Ack(uint bits) {
            if((bits&FifoInt)!=0 && fifo.Count>0) fifo.Dequeue();
            raw&=~bits;
            if(fifo.Count>0) raw|=FifoInt;
        }
        private void Arm(int i) {
            uint clkn=base.ReadDoubleWord(0xe8+8*i)&ClockMask;
            uint fine=base.ReadDoubleWord(0xec+8*i)&0x3ff;
            target[i]=clkn*HalfSlot+(HalfSlot-1-Math.Min(fine,HalfSlot-1));
            armed[i]=true;
        }
        private void Program(int idx) {
            ulong a=exchangeTable+(ulong)idx*16;
            var bus=machine.SystemBus;
            ushort ctrl=bus.ReadWord(a);
            ulong slot=bus.ReadWord(a+2)|((ulong)(bus.ReadWord(a+4)&0xfff)<<16);
            ulong fine=Math.Min((ulong)bus.ReadWord(a+6)&0x3ff,HalfSlot-1);
            ushort dur=bus.ReadWord(a+0xa);
            ulong start=Unwrap(slot*HalfSlot+(HalfSlot-1-fine));
            ulong len=(dur&0x8000)!=0 ? (ulong)(dur&0x7fff)*HalfSlot : (ulong)dur*2;
            if(len==0) len=HalfSlot;
            SetStatus(a,1);
            pending.Add(new Activity { Index=idx, Start=start, Planned=start, Length=len, Mode=ctrl&7, Cs=exchangeTable+(ulong)bus.ReadWord(a+8)*8 });
            if(TraceEvents) {
                // Research aid: scheduler callback (sch_prog env 0x68008898) and the control structure.
                uint cb=bus.ReadDoubleWord(0x68008898UL+(ulong)idx*16+4);
                ulong cs=exchangeTable+(ulong)bus.ReadWord(a+8)*8;
                var words=new System.Text.StringBuilder();
                if(dumped.Add(cs)) for(ulong o=0;o<0xb0;o+=2) words.AppendFormat("{0:x4} ",bus.ReadWord(cs+o));
                this.Log(LogLevel.Info,"ET{0} mode {1} ctrl {5:x4} start {2} (now {3}) len {4}us cb {6:x} cs {7:x} {8}",idx,ctrl&7,start,Now,len/2,ctrl,cb,cs,words);
            }
        }
        // Clock values are 28-bit half-slot counts; place a target within half a wrap of now.
        private ulong Unwrap(ulong ticks) {
            const ulong span=(ClockMask+1UL)*HalfSlot;
            ulong now=Now, baseTicks=now-now%span;
            ulong t=baseTicks+ticks%span;
            if(t+span/2<now) t+=span; else if(t>now+span/2 && t>=span) t-=span;
            return t;
        }
        private void SetStatus(ulong a,int st) {
            var bus=machine.SystemBus;
            ushort ctrl=bus.ReadWord(a);
            bus.WriteWord(a,(ushort)((ctrl&~0x38)|(st<<3)));
        }
        // Advance timers and the activity sequencer to the current time, then re-arm the alarm.
        private void Process() {
            ulong now=Now;
            ulong next=ulong.MaxValue;
            uint mask=base.ReadDoubleWord(IntCntl);
            for(int i=0;i<3;i++) {
                // A target fires once its interrupt is enabled (firmware writes target, acks, then enables).
                if(!armed[i] || (mask&(1u<<(5+i)))==0) continue;
                ulong t=Unwrap(target[i]);
                if(t<=now) { armed[i]=false; raw|=1u<<(5+i); }
                else next=Math.Min(next,t);
            }
            for(int guard=0;guard<32;guard++) {
                if(current>=0) {
                    var act=running;
                    // The programmed duration is a maximum: the sequencer ends the running activity
                    // when the next exchange-table entry is due (the scheduler overlaps them on purpose).
                    ulong end=act.Start+act.Length;
                    if(pending.Count>0 && pending[0].Start<end) end=Math.Max(act.Start,pending[0].Start);
                    if(end>now) { next=Math.Min(next,end); break; }
                    SetStatus(exchangeTable+(ulong)act.Index*16,3);
                    fifo.Enqueue(((uint)act.Index<<24)|EndAct);
                    if(TraceEvents) this.Log(LogLevel.Info,"ET{0} end",act.Index);
                    current=-1;
                    continue;
                }
                if(pending.Count==0) break;
                var nextAct=pending[0];
                if(nextAct.Start>now) { next=Math.Min(next,nextAct.Start); break; }
                pending.RemoveAt(0);
                if(now-nextAct.Start>LateLimit) {
                    SetStatus(exchangeTable+(ulong)nextAct.Index*16,6);
                    fifo.Enqueue(((uint)nextAct.Index<<28)|((uint)nextAct.Index<<24)|SkipAct);
                    if(TraceEvents) this.Log(LogLevel.Info,"ET{0} skipped ({1}us late)",nextAct.Index,(now-nextAct.Start)/2);
                    continue;
                }
                SetStatus(exchangeTable+(ulong)nextAct.Index*16,2);
                running=nextAct; running.Start=now; current=nextAct.Index;
                if(running.Mode==2 && PeerPort!=0) AirExchange(ref running);
            }
            if(fifo.Count>0) raw|=FifoInt;
            Update();
            if(next!=ulong.MaxValue) {
                alarm.Enabled=false;
                alarm.Value=0;
                alarm.Limit=next>now ? next-now : 1UL;   // ulong: never let a past deadline underflow
                alarm.Enabled=true;
            }
        }
        private void Update() { IRQ.Set((raw&base.ReadDoubleWord(IntCntl))!=0); }
        // The free-running counter is 32 bits wide (35 min); extend it in software.
        private ulong Now { get { uint v=(uint)clock.Value; if(v<lastClock) clockHigh+=1UL<<32; lastClock=v; return clockHigh|v; } }
        private uint lastClock; private ulong clockHigh;

        private struct Activity { public int Index; public ulong Start; public ulong Planned; public ulong Length; public int Mode; public ulong Cs; }

        // ---- Virtual BLE peer ("air" bridge) -------------------------------------------------
        // With PeerPort set, every BLE activity is handed in lock step to a peer process on
        // 127.0.0.1:PeerPort (text lines). The peer plays the remote device: it may answer an
        // advertising event with a CONNECT_IND and supplies the central's PDU for each connection
        // event; the glasses' own PDUs (TX descriptors) are reported back. This replaces the radio.
        //   model -> peer: "ADV <cs> <fmt> <hdr>:<payload> ..."   peer -> model: "CONNECT <hex>" | "NONE"
        //   model -> peer: "EVT <cs> <fmt>"                        peer -> model: "RX <hdr> <hex>" | "NONE"
        //   model -> peer: "TX <cs> <hdr>:<payload> ..."           peer -> model: "OK"
        // BLE exchange memory (BTC IP 1): RX descriptor ring (32 B, word0 = RXDONE bit15 | next>>3),
        // current RX descriptor in BLE core register 0x828; descriptor +2 status, +4 header,
        // +6 channel/rate, +8/+0xa sync half-slot clock, +0xc fine count, +0x10 RAL ptr,
        // +0x14 data ptr (halfwords). Control structure: +0 format, +0x24 TX descriptor ptr (>>3);
        // TX descriptor: +0 TXDONE bit15 | next>>3, +2 header, +4 data ptr (halfwords).
        public int PeerPort { get; set; }

        private void AirExchange(ref Activity act) {
            var bus=machine.SystemBus;
            int fmt=bus.ReadWord(act.Cs)&0x1f;
            try {
                if(fmt==AdvFormat) {
                    var line=new System.Text.StringBuilder();
                    line.AppendFormat("ADV {0:x} {1} {2}",act.Cs,fmt,BdAddr(act.Cs));
                    foreach(var d in TxChain(act.Cs,false)) line.Append(' ').Append(d);
                    string reply=PeerCall(line.ToString());
                    if(reply.StartsWith("CONNECT ")) {
                        var payload=Hex(reply.Substring(8));
                        WriteRx(0x05|(payload.Length<<8)|0x40,payload,act.Start+600);
                        act.Length=Math.Min(act.Length,1200);   // reception ends the event
                    }
                    return;
                }
                string rx=PeerCall(string.Format("EVT {0:x} {1}",act.Cs,fmt));
                if(rx.StartsWith("RX ")) {
                    var parts=rx.Split(' ');
                    int hdr=Convert.ToInt32(parts[1],16);
                    var payload=parts.Length>2 ? Hex(parts[2]) : new byte[0];
                    // Sync point the peripheral scheduler expects: programmed start + its RX prefetch/widening
                    // margin (77.5 us at 1M PHY, measured from the firmware's anchor updates).
                    WriteRx((hdr&0xff)|(payload.Length<<8),payload,act.Planned+SyncOffset);
                    fifo.Enqueue(((uint)act.Index<<24)|RxAct);
                    var tx=new System.Text.StringBuilder();
                    tx.AppendFormat("TX {0:x}",act.Cs);
                    var sent=TxChain(act.Cs,true);
                    foreach(var d in sent) tx.Append(' ').Append(d);
                    PeerCall(tx.ToString());
                    // TX frame interrupt: the link layer frees acknowledged (TXDONE) descriptors there.
                    if(sent.Count>0) fifo.Enqueue(((uint)act.Index<<24)|TxAct);
                }
                act.Length=Math.Min(act.Length,2500);
            } catch(Exception e) {
                this.Log(LogLevel.Warning,"BLE peer: {0}",e.Message);
                peer?.Dispose(); peer=null;
            }
        }
        private string BdAddr(ulong cs) {
            var bus=machine.SystemBus; var sb=new System.Text.StringBuilder();
            for(ulong i=0;i<6;i++) sb.AppendFormat("{0:x2}",bus.ReadByte(cs+0x8+i));
            return sb.ToString();
        }
        // Walk the control structure's TX descriptor list. Advertising: report the whole ring.
        // Connection: the hardware stays on the last transmitted descriptor (TXDONE set) until
        // software links a new one through its next pointer; send the first pending descriptor,
        // mark it done and make it the list head.
        private List<string> TxChain(ulong cs,bool consume) {
            var bus=machine.SystemBus; var res=new List<string>();
            ushort head=bus.ReadWord(cs+0x24);
            ushort p=head;
            for(int n=0;n<16 && (p&0x7fff)!=0;n++) {
                ulong d=exchangeTable+(ulong)(p&0x7fff)*8;
                ushort w0=bus.ReadWord(d);
                if(consume && (w0&0x8000)!=0) {
                    p=(ushort)(w0&0x7fff);
                    if(p!=0) bus.WriteWord(cs+0x24,p);
                    continue;
                }
                int hdr=bus.ReadWord(d+2), len=hdr>>8;
                ulong data=exchangeTable+(ulong)bus.ReadWord(d+4)*2;
                var sb=new System.Text.StringBuilder(); sb.AppendFormat("{0:x4}:",hdr);
                int dlen=consume ? len : Math.Max(0,len-6);
                if(bus.ReadWord(d+4)!=0) for(int i=0;i<dlen;i++) sb.AppendFormat("{0:x2}",bus.ReadByte(data+(ulong)i));
                res.Add(sb.ToString());
                if(consume) { bus.WriteWord(d,(ushort)(w0|0x8000)); break; }
                p=(ushort)(w0&0x7fff);
                if(p==head) break;
            }
            return res;
        }
        // Fill the RX descriptor the BLE core currently points at (register 0x828) and advance.
        private void WriteRx(int header,byte[] payload,ulong when) {
            var bus=machine.SystemBus;
            uint cur=base.ReadDoubleWord(0x828)&0x7fff;
            if(cur==0) return;
            ulong d=exchangeTable+cur*8;
            ushort w0=bus.ReadWord(d);
            ulong data=exchangeTable+(ulong)bus.ReadWord(d+0x14)*2;
            for(int i=0;i<payload.Length;i++) bus.WriteByte(data+(ulong)i,payload[i]);
            bus.WriteWord(d+2,0);                       // status: no sync/CRC/length errors
            bus.WriteWord(d+4,(ushort)header);
            bus.WriteWord(d+6,0);                       // 1M PHY
            bus.WriteWord(d+8,(ushort)((when/HalfSlot)&0xffff));
            bus.WriteWord(d+0xa,(ushort)(((when/HalfSlot)>>16)&0xfff));
            bus.WriteWord(d+0xc,(ushort)(HalfSlot-1-when%HalfSlot));
            bus.WriteWord(d+0x10,0);                    // no resolving-list match
            bus.WriteWord(d,(ushort)(w0|0x8000));       // RXDONE
            base.WriteDoubleWord(0x828,(uint)(w0&0x7fff));
        }
        private string PeerCall(string line) {
            if(peer==null) {
                peer=new System.Net.Sockets.TcpClient();
                peer.Connect("127.0.0.1",PeerPort);
                peer.ReceiveTimeout=60000;
                peerIn=new System.IO.StreamReader(peer.GetStream());
                peerOut=new System.IO.StreamWriter(peer.GetStream()) { AutoFlush=true, NewLine="\n" };
            }
            peerOut.WriteLine(line);
            string reply=peerIn.ReadLine() ?? throw new Exception("peer closed");
            if(TraceEvents) this.Log(LogLevel.Info,"air> {0} | {1}",line,reply);
            return reply.Trim();
        }
        private static byte[] Hex(string h) {
            h=h.Trim(); var b=new byte[h.Length/2];
            for(int i=0;i<b.Length;i++) b[i]=Convert.ToByte(h.Substring(2*i,2),16);
            return b;
        }
        private System.Net.Sockets.TcpClient peer;
        private System.IO.StreamReader peerIn;
        private System.IO.StreamWriter peerOut;
        private const int AdvFormat=4;
        private const ulong SyncOffset=155;
        private const ulong TicksPerSecond=2000000UL;   // half-microseconds
        private const ulong HalfSlot=625;
        private const uint ClockMask=0x0fffffff;
        private const ulong LateLimit=2*HalfSlot;
        private const long IntCntl=0x18, IntStat=0x1c, IntAck=0x20, FifoStat=0x24;
        private const uint SwInt=1u<<3, FifoInt=1u<<15, EndAct=1u<<1, SkipAct=1u<<2, TxAct=1u<<3, RxAct=1u<<4;
        private readonly object sync=new object();
        private readonly IMachine machine;
        private readonly LimitTimer clock, alarm;
        private readonly uint versionWord;
        private readonly ulong exchangeTable;
        private uint raw;
        private readonly ulong[] target=new ulong[3];
        private readonly bool[] armed=new bool[3];
        private readonly Queue<uint> fifo=new Queue<uint>();
        private readonly List<Activity> pending=new List<Activity>();
        private Activity running;
        private int current=-1;
        private readonly HashSet<ulong> dumped=new HashSet<ulong>();
    }
}
