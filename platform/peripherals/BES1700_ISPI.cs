// Synchronous internal SPI register transport. IDs are configurable assumptions
// until a physical chip-ID readback is supplied; no firmware instructions are patched.
using System;
using System.Collections.Generic;
using Antmicro.Renode.Core;
using Antmicro.Renode.Peripherals;
using Antmicro.Renode.Peripherals.Bus;
namespace Antmicro.Renode.Peripherals.SPI
{
    public sealed class BES1700_ISPI : IDoubleWordPeripheral, IKnownSize
    {
        public BES1700_ISPI(uint socId = 0x1700, uint pmuId = 0x18f0, uint pmuSubtype = 0x650) { this.socId=socId;this.pmuId=pmuId;this.pmuSubtype=pmuSubtype; }
        public uint ReadDoubleWord(long offset)
        {
            if(offset==0xc) return 3u | (fifo.Count>0?4u:0u); // TX empty/not full, RX not empty, not busy
            if(offset==8) return fifo.Count>0?fifo.Dequeue():0;
            return registers.TryGetValue(offset,out var value)?value:0;
        }
        public void WriteDoubleWord(long offset,uint value)
        {
            if(offset!=8) {registers[offset]=value;return;}
            uint cs=(ReadDoubleWord(4)>>7)&15;
            bool wide=(((ReadDoubleWord(0)>>16)&31)+1)>25;
            uint address=wide?(value>>18)&0x3ff:(value>>16)&0xff;
            bool read=(value&(wide?0x10000000u:0x1000000u))!=0;
            uint key=cs*0x1000+address;
            uint response=0;
            if(read) {
                if(address==0 && cs==7) response=socId;
                else if(address==0 && cs==0) response=pmuId;
                else if(address==1 && cs==0) response=pmuSubtype;
                // PSRAM analog DLL status: lock bit 6, delay tap count bits 5:0.
                // Ideal functional PHY (no analog timing or range-error simulation).
                else if(address==0x51 && cs==5) response=0x50;
                else if(cs==0 && (address>=0x17d && address<=0x180)) response=ReadRtc(address);
                else {
                    analog.TryGetValue(key,out response);
                    // PMU RTC calendar enable (pmu_rtc_calendar_enabled: 0x11 bit 1 / 0x128 bit 0).
                    if(cs==0 && address==0x11) response|=2;
                    if(cs==0 && address==0x128) response|=1;
                    // Boot calibration: write 0xa000 to PMU 0x4f starts a conversion.
                    // The firmware polls bits 7:6 for 01. Conversion is instantaneous
                    // in this functional model; analog timing is not calibrated.
                    if(cs==0 && address==0x4f && (response&0xa000)==0xa000)
                        response=(response&~0xc0u)|0x40u;
                }
            } else if(address!=0 || (cs!=0 && cs!=7)) {
                analog[key]=(wide?value>>2:value)&0xffff;
                if(cs==0 && address>=0x17d && address<=0x180) WriteRtc(address,analog[key]);
            }
            if(fifo.Count<32) fifo.Enqueue(wide?response<<2:response);
        }
        // PMU RTC calendar (pmu_rtc_calendar_get/_set in the stock AP image), BCD fields:
        //   0x17d min[14:12|11:8] sec[6:4|3:0]   0x17e hour[5:4|3:0]
        //   0x17f weekday[15:13] month[12|11:8] day[5:4|3:0]; with PMU 0x114 bit 0 set: year-2000 [5:4|3:0]
        //   0x180 year-2000 [7:4|3:0] (other PMU variant)
        // The calendar runs from the host's local clock (the firmware keeps UTC+offset otherwise
        // set by the phone; with no phone the offset stays 0, so local time is shown as on a
        // glasses that last synced in this time zone). Firmware writes move it relative to host time.
        private DateTime RtcNow() { return DateTime.Now+rtcOffset; }
        private static uint Bcd(int v) { return (uint)(((v/10)<<4)|(v%10)); }
        private static int FromBcd(uint v,int tensBits) { return (int)(((v>>4)&((1u<<tensBits)-1))*10+(v&15)); }
        private uint ReadRtc(uint address)
        {
            var t=RtcNow();
            analog.TryGetValue(0x114,out var sel);
            switch(address) {
                case 0x17d: return (Bcd(t.Minute)<<8)|Bcd(t.Second);
                case 0x17e: return Bcd(t.Hour);
                case 0x17f:
                    if((sel&1)!=0) return Bcd(t.Year%100);
                    return ((uint)t.DayOfWeek<<13)|(t.Month>=10?0x1000u:0)|((uint)(t.Month%10)<<8)|Bcd(t.Day);
                default: return Bcd(t.Year%100);
            }
        }
        private void WriteRtc(uint address,uint v)
        {
            var t=RtcNow();
            analog.TryGetValue(0x114,out var sel);
            int year=t.Year,month=t.Month,day=t.Day,hour=t.Hour,minute=t.Minute,second=t.Second;
            switch(address) {
                case 0x17d: minute=FromBcd(v>>8,3);second=FromBcd(v,3);break;
                case 0x17e: hour=FromBcd(v,2);break;
                case 0x17f:
                    if((sel&1)!=0) year=2000+FromBcd(v,2);
                    else {month=((v&0x1000)!=0?10:0)+(int)((v>>8)&15);day=FromBcd(v,2);}
                    break;
                default: year=2000+FromBcd(v,4);break;
            }
            try { rtcOffset=new DateTime(year,month,day,hour,minute,second)-DateTime.Now; } catch(ArgumentOutOfRangeException) {}
        }
        private TimeSpan rtcOffset=TimeSpan.Zero;
        public void Reset(){registers.Clear();analog.Clear();fifo.Clear();}
        public long Size=>0x1000;
        private readonly uint socId,pmuId,pmuSubtype;
        private readonly Dictionary<long,uint> registers=new Dictionary<long,uint>();
        private readonly Dictionary<uint,uint> analog=new Dictionary<uint,uint>();
        private readonly Queue<uint> fifo=new Queue<uint>();
    }
}
