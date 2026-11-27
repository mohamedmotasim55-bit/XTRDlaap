//+------------------------------------------------------------------+
//| XTRD_M1_LIQ_RESEARCH.mq5                                         |
//| M1 liquidity sweep research. NO trading, NO orders.              |
//| Detectors: prev-day sweep, local-swing sweep, wick rejection.    |
//| Confirmations: MSS, displacement, momentum (closed bars only).   |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"
#property description "M1 liquidity sweep research EA. Measurement only."

input string InpEvFile  = "liq_events.csv";
input string InpOutFile = "liq_outcomes.csv";

#define M1CAP 2000
struct MB { long t; double o,h,l,c; };
MB g_m1[M1CAP];
int g_mHead=-1;
int g_mCount=0;
MB g_cur;
bool g_curValid=false;

#define HZ 6
long   g_hz[HZ]      = {60000,180000,300000,600000,1800000,3600000};
string g_hz_name[HZ] = {"1m","3m","5m","10m","30m","60m"};

struct Pend { int id; long t_msc; double eb,ea,mid,R; bool done; };
Pend g_pend[128];
int  g_pendCount=0;
int  g_evId=0;
int  g_fhE=INVALID_HANDLE;
int  g_fhO=INVALID_HANDLE;
double g_point=0.0;
int  g_lastSweepBar=-1000;

int M1Idx(const int back){ if(back>=g_mCount) return -1; int i=(g_mHead-back)%M1CAP; if(i<0)i+=M1CAP; return i; }
MB M1(const int back){ int i=M1Idx(back); if(i<0){ MB z; z.t=0;z.o=z.h=z.l=z.c=0; return z;} return g_m1[i]; }

void CloseM1()
{
   g_mHead=(g_mHead+1)%M1CAP; g_m1[g_mHead]=g_cur; if(g_mCount<M1CAP) g_mCount++;
}

void Emit(const string kind,const int dir,const MqlTick &t,const double R,const int mss,const int disp,const int mom)
{
   double pt=(g_point>0.0)?g_point:1.0;
   double sp=(t.ask-t.bid)/pt;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   g_evId++;
   if(g_fhE!=INVALID_HANDLE)
   {
      FileWrite(g_fhE,g_evId,(long)t.time_msc,kind,(dir>0?"BUY":"SELL"),dt.hour,dt.day_of_week,
                DoubleToString(sp,1),DoubleToString(R/pt,1),mss,disp,mom,
                DoubleToString(t.bid,_Digits),DoubleToString(t.ask,_Digits));
      FileFlush(g_fhE);
   }
   int idx=-1; for(int i=0;i<g_pendCount;i++){ if(g_pend[i].done){ idx=i; break; } }
   if(idx<0 && g_pendCount<128){ idx=g_pendCount; g_pendCount++; }
   if(idx>=0){ g_pend[idx].id=g_evId; g_pend[idx].t_msc=t.time_msc; g_pend[idx].eb=t.bid; g_pend[idx].ea=t.ask;
               g_pend[idx].mid=(t.bid+t.ask)*0.5; g_pend[idx].R=R; g_pend[idx].done=false; }
}

void Detect(const MqlTick &t)
{
   if(g_mCount<25) return;
   MB b1=M1(1); // just-closed bar
   // previous day high/low (scan back up to 1440 bars)
   MqlDateTime dt1; TimeToStruct((datetime)b1.t,dt1);
   double pdh=-1, pdl=1e18;
   for(int k=2;k<MathMin(g_mCount,1500);k++){
      MB b=M1(k); MqlDateTime dd; TimeToStruct((datetime)b.t,dd);
      if(dd.day!=dt1.day || dd.mon!=dt1.mon){ if(b.h>pdh)pdh=b.h; if(b.l<pdl)pdl=b.l; }
   }
   // local swing (bars 3..22)
   double swH=-1, swL=1e18;
   for(int k=3;k<=22;k++){ MB b=M1(k); if(b.h>swH)swH=b.h; if(b.l<swL)swL=b.l; }
   double body=MathAbs(b1.c-b1.o);
   double upW=b1.h-MathMax(b1.o,b1.c);
   double dnW=MathMin(b1.o,b1.c)-b1.l;
   // avg body last 20
   double ab=0; for(int k=2;k<=21;k++) ab+=MathAbs(M1(k).c-M1(k).o); ab/=20.0;
   // confirmations (closed-bar only)
   double hh=-1, ll=1e18; for(int k=2;k<=5;k++){ MB b=M1(k); if(b.h>hh)hh=b.h; if(b.l<ll)ll=b.l; }
   int mssSell = (b1.c<ll)?1:0;
   int mssBuy  = (b1.c>hh)?1:0;
   int disp = (ab>0 && body>1.5*ab)?1:0;
   int momSell = (b1.c<b1.o && M1(2).c<M1(2).o)?1:0;
   int momBuy  = (b1.c>b1.o && M1(2).c>M1(2).o)?1:0;
   double pt=(g_point>0.0)?g_point:1.0;

   // SWEEP of previous-day high -> SELL (false break + close back)
   if(pdh>0 && b1.h>pdh && b1.c<pdh)
   {
      double R=(b1.h-t.ask);
      if(R>0) Emit("SWEEP_PD_HIGH",-1,t,R,mssSell,disp,momSell);
   }
   if(pdl<1e17 && b1.l<pdl && b1.c>pdl)
   {
      double R=(t.bid-b1.l);
      if(R>0) Emit("SWEEP_PD_LOW",1,t,R,mssBuy,disp,momBuy);
   }
   // SWEEP of local swing high -> SELL
   if(swH>0 && b1.h>swH && b1.c<swH)
   {
      double R=(b1.h-t.ask);
      if(R>0) Emit("SWEEP_SW_HIGH",-1,t,R,mssSell,disp,momSell);
   }
   if(swL<1e17 && b1.l<swL && b1.c>swL)
   {
      double R=(t.bid-b1.l);
      if(R>0) Emit("SWEEP_SW_LOW",1,t,R,mssBuy,disp,momBuy);
   }
   // WICK rejection high -> SELL
   if(body>0 && upW>2.0*body && upW>1.5*dnW && b1.c<b1.o)
   {
      double R=(b1.h-t.ask); if(R>0) Emit("WICK_HIGH",-1,t,R,mssSell,disp,momSell);
   }
   if(body>0 && dnW>2.0*body && dnW>1.5*upW && b1.c>b1.o)
   {
      double R=(t.bid-b1.l); if(R>0) Emit("WICK_LOW",1,t,R,mssBuy,disp,momBuy);
   }
}

void Resolve(const long now)
{
   for(int i=0;i<g_pendCount;i++)
   {
      if(g_pend[i].done) continue;
      if(now < g_pend[i].t_msc + 3600000) continue;
      MqlTick tk[]; int n=CopyTicksRange(_Symbol,tk,COPY_TICKS_ALL,(ulong)g_pend[i].t_msc,(ulong)(g_pend[i].t_msc+3600000));
      double pt=(g_point>0.0)?g_point:1.0;
      double eb=g_pend[i].eb, ea=g_pend[i].ea, R=g_pend[i].R;
      if(n>0)
      {
         for(int h=0;h<HZ;h++){
            long b=g_pend[i].t_msc+g_hz[h]; int last=-1;
            for(int k=0;k<n;k++){ if(tk[k].time_msc<=b) last=k; else break; }
            double xb=(last>=0)?tk[last].bid:eb, xa=(last>=0)?tk[last].ask:ea;
            double nb=(xb-ea)/pt, ns=(eb-xa)/pt;
            if(g_fhO!=INVALID_HANDLE) FileWrite(g_fhO,g_pend[i].id,"NET",g_hz_name[h],DoubleToString(nb,2),DoubleToString(ns,2),"NA","NA");
         }
         // first passage 2R target / 1R stop (BUY: exit bid, target=entry_ask+2R, stop=entry_ask-1R)
         double levT=2.0*R, levS=1.0*R;
         long bt=-1,bs=-1;
         for(int k=0;k<n;k++){ double b=tk[k].bid; if(bt<0&&b>=ea+levT)bt=tk[k].time_msc; if(bs<0&&b<=ea-levS)bs=tk[k].time_msc; if(bt>=0&&bs>=0)break; }
         string sb="NONE"; double pb=0;
         if(bt>=0&&(bs<0||bt<bs)){sb="TARGET";pb=levT/pt;} else if(bs>=0){sb="STOP";pb=-levS/pt;} else {sb="TIME";pb=(tk[n-1].bid-ea)/pt;}
         long st=-1,ss2=-1;
         for(int k=0;k<n;k++){ double a=tk[k].ask; if(st<0&&a<=eb-levT)st=tk[k].time_msc; if(ss2<0&&a>=eb+levS)ss2=tk[k].time_msc; if(st>=0&&ss2>=0)break; }
         string sss="NONE"; double ps=0;
         if(st>=0&&(ss2<0||st<ss2)){sss="TARGET";ps=levT/pt;} else if(ss2>=0){sss="STOP";ps=-levS/pt;} else {sss="TIME";ps=(eb-tk[n-1].ask)/pt;}
         if(g_fhO!=INVALID_HANDLE) FileWrite(g_fhO,g_pend[i].id,"FIRST","2R_1R",DoubleToString(pb,2),DoubleToString(ps,2),sb,sss);
      }
      g_pend[i].done=true;
   }
}

int OnInit()
{
   g_point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   g_fhE=FileOpen(InpEvFile,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(g_fhE==INVALID_HANDLE){ Print("EV_FAILED ",GetLastError()); return INIT_FAILED; }
   if(FileSize(g_fhE)==0) FileWrite(g_fhE,"event_id","time_msc","kind","direction","hour","weekday","spread_pts","R_pts","mss","disp","mom","bid","ask");
   FileSeek(g_fhE,0,SEEK_END);
   g_fhO=FileOpen(InpOutFile,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(g_fhO==INVALID_HANDLE){ Print("OUT_FAILED ",GetLastError()); return INIT_FAILED; }
   if(FileSize(g_fhO)==0) FileWrite(g_fhO,"event_id","kind","key","val_buy","val_sell","side_buy","side_sell");
   FileSeek(g_fhO,0,SEEK_END);
   for(int i=0;i<128;i++) g_pend[i].done=true;
   g_pendCount=0;
   Print("LIQ_RESEARCH_INIT point=",g_point);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   if(g_fhO!=INVALID_HANDLE){ FileFlush(g_fhO); FileClose(g_fhO); g_fhO=INVALID_HANDLE; }
   if(g_fhE!=INVALID_HANDLE){ FileFlush(g_fhE); FileClose(g_fhE); g_fhE=INVALID_HANDLE; }
   Print("LIQ_RESEARCH_DONE events=",g_evId);
}
void OnTick()
{
   MqlTick t; if(!SymbolInfoTick(_Symbol,t)) return;
   bool newMin=(!g_curValid || (long)t.time/60 != g_cur.t/60);
   if(newMin)
   {
      if(g_curValid){ CloseM1(); Detect(t); }
      g_cur.t=((long)t.time/60)*60; g_cur.o=t.bid; g_cur.h=t.bid; g_cur.l=t.bid; g_cur.c=t.bid; g_curValid=true;
   }
   else
   {
      if(t.bid>g_cur.h)g_cur.h=t.bid; if(t.bid<g_cur.l)g_cur.l=t.bid; g_cur.c=t.bid;
   }
   Resolve(t.time_msc);
}
