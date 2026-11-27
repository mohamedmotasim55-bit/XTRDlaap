//+------------------------------------------------------------------+
//| XTRD_NEXTGEN_DISCOVERY.mq5                                       |
//| Next-generation opportunity discovery. NO trading, NO orders.    |
//| Families: IMPULSE, LIQUIDITY_SWEEP, COMPRESSION_BREAK, SESSION.  |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"
#property description "Next-gen discovery: impulse, sweep, compression-breakout, session. No trading."

input int    InpCooldownSec = 300;
input string InpFeatFile    = "ng_events.csv";
input string InpOutFile     = "ng_outcomes.csv";

#define TICK_CAP 16384
long   g_tTime[TICK_CAP];
double g_tBid[TICK_CAP];
double g_tAsk[TICK_CAP];
int    g_tHead=-1;
int    g_tCount=0;

#define BAR_CAP 600
struct SBar { long sec; double ob,hb,lb,cb, oa,ha,la,ca; };
SBar g_bars[BAR_CAP];
int  g_bHead=-1;
int  g_bCount=0;
SBar g_cur;
bool g_curValid=false;

#define HZ 7
long   g_hz[HZ]      = {10000,30000,60000,120000,300000,600000,1800000};
string g_hz_name[HZ] = {"10s","30s","60s","120s","300s","600s","1800s"};

struct Pend { int id; long t_msc; double eb,ea,mid,spread; bool done; };
Pend g_pend[128];
int  g_pendCount=0;
int  g_evId=0;
int  g_fhE=INVALID_HANDLE;
int  g_fhO=INVALID_HANDLE;
double g_point=0.0;
long g_lastEvSec[8];
string g_lastEvName[8]={"","","","","","","",""};

void AddTick(const MqlTick &t){ g_tHead=(g_tHead+1)%TICK_CAP; g_tTime[g_tHead]=t.time_msc; g_tBid[g_tHead]=t.bid; g_tAsk[g_tHead]=t.ask; if(g_tCount<TICK_CAP) g_tCount++; }

void UpdateBar(const MqlTick &t)
{
   if(!g_curValid || (long)t.time!=g_cur.sec)
   {
      if(g_curValid){ g_bHead=(g_bHead+1)%BAR_CAP; g_bars[g_bHead]=g_cur; if(g_bCount<BAR_CAP) g_bCount++; }
      g_cur.sec=(long)t.time; g_cur.ob=t.bid; g_cur.hb=t.bid; g_cur.lb=t.bid; g_cur.cb=t.bid;
      g_cur.oa=t.ask; g_cur.ha=t.ask; g_cur.la=t.ask; g_cur.ca=t.ask; g_curValid=true;
   }
   else
   {
      if(t.bid>g_cur.hb)g_cur.hb=t.bid; if(t.bid<g_cur.lb)g_cur.lb=t.bid; g_cur.cb=t.bid;
      if(t.ask>g_cur.ha)g_cur.ha=t.ask; if(t.ask<g_cur.la)g_cur.la=t.ask; g_cur.ca=t.ask;
   }
}
int BarIdx(const int back){ if(back>=g_bCount) return -1; int i=(g_bHead-back)%BAR_CAP; if(i<0)i+=BAR_CAP; return i; }
double BarRange(const int back){ int i=BarIdx(back); if(i<0)return 0; return g_bars[i].hb-g_bars[i].lb; }
double BarClose(const int back){ int i=BarIdx(back); if(i<0)return 0; return g_bars[i].cb; }

void Emit(const string fam,const int dir,const MqlTick &t,const double atr,const double rng,const double z)
{
   // cooldown per family
   long nowSec=(long)t.time;
   for(int i=0;i<8;i++){ if(g_lastEvName[i]==fam){ if(nowSec-g_lastEvSec[i]<InpCooldownSec) return; g_lastEvSec[i]=nowSec; } }
   // register if new family name
   bool found=false; for(int i=0;i<8;i++) if(g_lastEvName[i]==fam) found=true;
   if(!found){ for(int i=0;i<8;i++) if(g_lastEvName[i]==""){ g_lastEvName[i]=fam; g_lastEvSec[i]=nowSec; break; } }
   double pt=(g_point>0.0)?g_point:1.0;
   double sp=(t.ask-t.bid)/pt;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   g_evId++;
   if(g_fhE!=INVALID_HANDLE)
   {
      FileWrite(g_fhE,g_evId,(long)t.time_msc,fam,(dir>0?"BUY":"SELL"),dt.hour,dt.day_of_week,
                DoubleToString(sp,1),DoubleToString(atr,1),DoubleToString(rng,1),DoubleToString(z,2),
                DoubleToString(t.bid,_Digits),DoubleToString(t.ask,_Digits));
      FileFlush(g_fhE);
   }
   int idx=-1; for(int i=0;i<g_pendCount;i++){ if(g_pend[i].done){ idx=i; break; } }
   if(idx<0 && g_pendCount<128){ idx=g_pendCount; g_pendCount++; }
   if(idx>=0){ g_pend[idx].id=g_evId; g_pend[idx].t_msc=t.time_msc; g_pend[idx].eb=t.bid; g_pend[idx].ea=t.ask;
               g_pend[idx].mid=(t.bid+t.ask)*0.5; g_pend[idx].spread=sp; g_pend[idx].done=false; }
}

void Detect(const MqlTick &t)
{
   if(g_bCount<310) return;
   double pt=(g_point>0.0)?g_point:1.0;
   double atr60=0; for(int k=1;k<=60;k++) atr60+=BarRange(k); atr60/=60.0;
   double atr300=0; for(int k=1;k<=300;k++) atr300+=BarRange(k); atr300/=300.0;
   double rng=BarRange(0);
   // 1) IMPULSE: current bar range > 2.5x atr60 and expanding
   if(atr60>0 && rng > 2.5*atr60)
   {
      int i=BarIdx(0); double o=g_bars[i].ob, c=g_bars[i].cb;
      int dir=(c>o)?1:-1;
      Emit("IMPULSE",dir,t,atr60, rng, (atr300>0)?atr60/atr300:0);
   }
   // 2) LIQUIDITY_SWEEP: break local high/low then close back inside
   double hi=0,lo=0; for(int k=2;k<=120;k++){ int i=BarIdx(k); if(i<0)break; if(k==2){hi=g_bars[i].hb;lo=g_bars[i].lb;} else {if(g_bars[i].hb>hi)hi=g_bars[i].hb; if(g_bars[i].lb<lo)lo=g_bars[i].lb;} }
   int i0=BarIdx(0);
   if(i0>=0)
   {
      if(g_bars[i0].hb>hi && g_bars[i0].cb<hi) Emit("SWEEP",-1,t,atr60,rng,0); // swept high, closed back -> SHORT
      if(g_bars[i0].lb<lo && g_bars[i0].cb>lo) Emit("SWEEP",1,t,atr60,rng,0);  // swept low -> LONG
   }
   // 3) COMPRESSION_BREAK: low comp then expansion
   double comp=(atr300>0)?atr60/atr300:1.0;
   if(comp<0.6 && atr60>0 && rng>1.5*atr60)
   {
      int i=BarIdx(0); double o=g_bars[i].ob, c=g_bars[i].cb; int dir=(c>o)?1:-1;
      Emit("COMPRESSION_BREAK",dir,t,atr60,rng,comp);
   }
   // 4) SESSION: at London(7) / NY(13) / overlap(14) open hours
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(dt.hour==7||dt.hour==13||dt.hour==14)
   {
      double m5=BarClose(0)-BarClose(5); int dir=(m5>=0)?1:-1;
      Emit("SESSION",dir,t,atr60,rng,(double)dt.hour);
   }
}

void Resolve(const long now)
{
   for(int i=0;i<g_pendCount;i++)
   {
      if(g_pend[i].done) continue;
      if(now < g_pend[i].t_msc + 1800000) continue;
      MqlTick tk[]; int n=CopyTicksRange(_Symbol,tk,COPY_TICKS_ALL,(ulong)g_pend[i].t_msc,(ulong)(g_pend[i].t_msc+1800000));
      double pt=(g_point>0.0)?g_point:1.0;
      double eb=g_pend[i].eb, ea=g_pend[i].ea;
      if(n>0)
      {
         for(int h=0;h<HZ;h++)
         {
            long b=g_pend[i].t_msc+g_hz[h]; int last=-1;
            for(int k=0;k<n;k++){ if(tk[k].time_msc<=b) last=k; else break; }
            double xb=(last>=0)?tk[last].bid:eb, xa=(last>=0)?tk[last].ask:ea;
            double nb=(xb-ea)/pt, ns=(eb-xa)/pt;
            if(g_fhO!=INVALID_HANDLE) FileWrite(g_fhO,g_pend[i].id,g_hz_name[h],DoubleToString(nb,2),DoubleToString(ns,2),n);
         }
      }
      g_pend[i].done=true;
   }
}

int OnInit()
{
   g_point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   g_fhE=FileOpen(InpFeatFile,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(g_fhE==INVALID_HANDLE){ Print("EV_FAILED ",GetLastError()); return INIT_FAILED; }
   if(FileSize(g_fhE)==0) FileWrite(g_fhE,"event_id","time_msc","family","direction","hour","weekday","spread_pts","atr60","range","comp","bid","ask");
   FileSeek(g_fhE,0,SEEK_END);
   g_fhO=FileOpen(InpOutFile,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(g_fhO==INVALID_HANDLE){ Print("OUT_FAILED ",GetLastError()); return INIT_FAILED; }
   if(FileSize(g_fhO)==0) FileWrite(g_fhO,"event_id","horizon","net_buy","net_sell","ticks");
   FileSeek(g_fhO,0,SEEK_END);
   for(int i=0;i<128;i++) g_pend[i].done=true;
   g_pendCount=0;
   for(int i=0;i<8;i++) g_lastEvSec[i]=0;
   Print("NEXTGEN_INIT point=",g_point," cooldown=",InpCooldownSec);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_fhO!=INVALID_HANDLE){ FileFlush(g_fhO); FileClose(g_fhO); g_fhO=INVALID_HANDLE; }
   if(g_fhE!=INVALID_HANDLE){ FileFlush(g_fhE); FileClose(g_fhE); g_fhE=INVALID_HANDLE; }
   Print("NEXTGEN_DONE events=",g_evId);
}

void OnTick()
{
   MqlTick t; if(!SymbolInfoTick(_Symbol,t)) return;
   bool newSec=(!g_curValid || (long)t.time!=g_cur.sec);
   AddTick(t); UpdateBar(t); Resolve(t.time_msc);
   if(newSec) Detect(t);
}
