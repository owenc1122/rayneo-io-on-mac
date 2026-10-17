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
            pending.Add(new Activity { Index=idx, Start=start, Length=len, Mode=ctrl&7 });
            if(TraceEvents) this.Log(LogLevel.Info,"ET{0} mode {1} start {2} (now {3}) len {4}us",idx,ctrl&7,start,Now,len/2);
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
            }
            if(fifo.Count>0) raw|=FifoInt;
            Update();
            if(next!=ulong.MaxValue) {
                alarm.Enabled=false;
                alarm.Value=0;
                alarm.Limit=Math.Max(1UL,next-now);
                alarm.Enabled=true;
            }
        }
        private void Update() { IRQ.Set((raw&base.ReadDoubleWord(IntCntl))!=0); }
        // The free-running counter is 32 bits wide (35 min); extend it in software.
        private ulong Now { get { uint v=(uint)clock.Value; if(v<lastClock) clockHigh+=1UL<<32; lastClock=v; return clockHigh|v; } }
        private uint lastClock; private ulong clockHigh;

        private struct Activity { public int Index; public ulong Start; public ulong Length; public int Mode; }
        private const ulong TicksPerSecond=2000000UL;   // half-microseconds
        private const ulong HalfSlot=625;
        private const uint ClockMask=0x0fffffff;
        private const ulong LateLimit=2*HalfSlot;
        private const long IntCntl=0x18, IntStat=0x1c, IntAck=0x20, FifoStat=0x24;
        private const uint SwInt=1u<<3, FifoInt=1u<<15, EndAct=1u<<1, SkipAct=1u<<2;
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
    }
}
