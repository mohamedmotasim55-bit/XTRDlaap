//+------------------------------------------------------------------+
//| XTRD_EDGE_DISCOVERY.mq5                                          |
//| Hypothesis event measurement only. NO trading, NO orders.        |
//| Detects A/B/C/D conditions on real ticks, logs features + forward |
//| outcomes at 1/3/5/10/30/60/120/300s. Session (E) via hour/weekday.|
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Market edge discovery: hypothesis events + forward outcomes. No trading."

input int    InpCooldownSec       = 300;   // per-hypothesis cooldown (s)
input double InpExpansionMult     = 1.5;   // A: range > mult * avg range
input double InpCompressionRatio  = 0.7;   // A: avg60 < ratio * avg300
input double InpMomSpreadMult     = 3.0;   // B: |move3s| > mult * spread
input double InpBreakoutSpreadMult= 1.0;   // C: break by mult * spread
input double InpZThreshold        = 2.5;   // D: |z| threshold
input int    InpMeanBars          = 60;    // bars for mean/range
input int    InpRegimeBars        = 300;   // bars for regime reference
input string InpEventsFile        = "edge_events.csv";
input string InpOutcomesFile      = "edge_outcomes.csv";

#define HZ_COUNT 8
long   g_hz_ms[HZ_COUNT]   = {1000,3000,5000,10000,30000,60000,120000,300000};
string g_hz_name[HZ_COUNT] = {"1s","3s","5s","10s","30s","60s","120s","300s"};

#define TICK_CAP 8192
long   g_tTime[TICK_CAP];
double g_tBid[TICK_CAP];
double g_tAsk[TICK_CAP];
int    g_tHead = -1;
int    g_tCount = 0;

#define BAR_CAP 600
struct SBar { long sec; double ob,hb,lb,cb, oa,ha,la,ca; int ticks; };
SBar g_bars[BAR_CAP];
int  g_bHead = -1;
int  g_bCount = 0;
SBar g_cur;
bool g_curValid = false;

struct PendingSig { int id; long t_msc; int dir; double eb,ea; bool done[HZ_COUNT]; bool active; };
PendingSig g_pend[2048];
int g_pendCount = 0;
int g_eventId = 0;
int g_fhEv = INVALID_HANDLE;
int g_fhOut = INVALID_HANDLE;
double g_point = 0.0;

long g_lastA=0;
long g_lastB=0;
long g_lastC=0;
long g_lastD=0;

//--- ring helpers
int BarIdx(const int back)
{
   if(g_bCount<=0) return -1;
   int idx = (g_bHead - back) % BAR_CAP;
   if(idx<0) idx += BAR_CAP;
   if(back>=g_bCount) return -1;
   return idx;
}
double BarMid(const int back)
{
   int i=BarIdx(back); if(i<0) return 0.0;
   return (g_bars[i].cb + g_bars[i].ca)*0.5;
}
double BarRange(const int back)
{
   int i=BarIdx(back); if(i<0) return 0.0;
   return (g_bars[i].hb - g_bars[i].lb);
}

double AvgRange(const int fromBack, const int count)
{
   if(g_bCount < fromBack+count) return 0.0;
   double s=0.0;
   for(int k=0;k<count;k++) s += BarRange(fromBack+k);
   return s/count;
}

// mid price at or before target_msc, from tick ring (0 if none)
double MidAtMs(const long target_msc, bool &found)
{
   found=false;
   for(int k=0;k<g_tCount;k++)
   {
      int idx=(g_tHead - k) % TICK_CAP; if(idx<0) idx+=TICK_CAP;
      if(g_tTime[idx] <= target_msc)
      {
         found=true;
         return (g_tBid[idx]+g_tAsk[idx])*0.5;
      }
   }
   return 0.0;
}

void AddTick(const MqlTick &t)
{
   g_tHead=(g_tHead+1)%TICK_CAP;
   g_tTime[g_tHead]=t.time_msc;
   g_tBid[g_tHead]=t.bid;
   g_tAsk[g_tHead]=t.ask;
   if(g_tCount<TICK_CAP) g_tCount++;
}

void UpdateBar(const MqlTick &t)
{
   if(!g_curValid || (long)t.time != g_cur.sec)
   {
      if(g_curValid)
      {
         g_bHead=(g_bHead+1)%BAR_CAP;
         g_bars[g_bHead]=g_cur;
         if(g_bCount<BAR_CAP) g_bCount++;
      }
      g_cur.sec=(long)t.time;
      g_cur.ob=t.bid; g_cur.hb=t.bid; g_cur.lb=t.bid; g_cur.cb=t.bid;
      g_cur.oa=t.ask; g_cur.ha=t.ask; g_cur.la=t.ask; g_cur.ca=t.ask;
      g_cur.ticks=1;
      g_curValid=true;
   }
   else
   {
      if(t.bid>g_cur.hb) g_cur.hb=t.bid;
      if(t.bid<g_cur.lb) g_cur.lb=t.bid;
      g_cur.cb=t.bid;
      if(t.ask>g_cur.ha) g_cur.ha=t.ask;
      if(t.ask<g_cur.la) g_cur.la=t.ask;
      g_cur.ca=t.ask;
      g_cur.ticks++;
   }
}

//--- forward resolution (measurement only)
void ResolveForward(const long now_msc)
{
   for(int i=0;i<g_pendCount;i++)
   {
      if(!g_pend[i].active) continue;
      bool allDone=true;
      for(int h=0;h<HZ_COUNT;h++)
      {
         if(g_pend[i].done[h]) continue;
         long boundary=g_pend[i].t_msc + g_hz_ms[h];
         if(now_msc < boundary){ allDone=false; continue; }
         MqlTick tk[];
         int n=CopyTicksRange(_Symbol, tk, COPY_TICKS_ALL, (ulong)g_pend[i].t_msc, (ulong)boundary);
         if(n<=0)
         {
            if(g_fhOut!=INVALID_HANDLE)
               FileWrite(g_fhOut, g_pend[i].id, (g_pend[i].dir>0?"BUY":"SELL"), g_hz_name[h],
                         DoubleToString(g_pend[i].eb,_Digits), DoubleToString(g_pend[i].ea,_Digits),
                         "NA","NA","NA","NA","NA","NA",0);
            g_pend[i].done[h]=true; continue;
         }
         double eb=g_pend[i].eb, ea=g_pend[i].ea;
         double xb=tk[n-1].bid, xa=tk[n-1].ask;
         double mfe=-1.0e18, mae=1.0e18;
         for(int k=0;k<n;k++)
         {
            double fav=(g_pend[i].dir>0)? (tk[k].bid-ea) : (eb-tk[k].ask);
            if(fav>mfe) mfe=fav;
            if(fav<mae) mae=fav;
         }
         double net=(g_pend[i].dir>0)? (xb-ea) : (eb-xa);
         double pt=(g_point>0.0)? g_point : 1.0;
         if(g_fhOut!=INVALID_HANDLE)
            FileWrite(g_fhOut, g_pend[i].id, (g_pend[i].dir>0?"BUY":"SELL"), g_hz_name[h],
                      DoubleToString(eb,_Digits), DoubleToString(ea,_Digits),
                      DoubleToString(xb,_Digits), DoubleToString(xa,_Digits),
                      DoubleToString(net/pt,2), DoubleToString(mfe/pt,2), DoubleToString(mae/pt,2),
                      (net>0.0?1:0), n);
         g_pend[i].done[h]=true;
      }
      if(allDone) g_pend[i].active=false;
   }
}

void RecordEvent(const string type, const int dir, const double bid, const double ask,
                 const double atrPts, const double rangePts, const double z,
                 const double v100, const double v250, const double v500, const double v1,
                 const double v3, const double v5, const double v10, const double compRatio,
                 const long t_msc)
{
   g_eventId++;
   datetime now=TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   int hour=dt.hour;
   int wday=dt.day_of_week;
   double spreadPts=(g_point>0.0)? (ask-bid)/g_point : 0.0;
   if(g_fhEv!=INVALID_HANDLE)
   {
      FileWrite(g_fhEv, g_eventId, (long)t_msc, type, (dir>0?"BUY":"SELL"), hour, wday,
                DoubleToString(spreadPts,1), DoubleToString(atrPts,1), DoubleToString(rangePts,1),
                DoubleToString(z,2), DoubleToString(v100,2), DoubleToString(v250,2),
                DoubleToString(v500,2), DoubleToString(v1,2), DoubleToString(v3,2),
                DoubleToString(v5,2), DoubleToString(v10,2), DoubleToString(compRatio,3),
                DoubleToString(bid,_Digits), DoubleToString(ask,_Digits));
      FileFlush(g_fhEv);
   }
   int idx=-1;
   for(int i=0;i<g_pendCount;i++){ if(!g_pend[i].active){ idx=i; break; } }
   if(idx<0 && g_pendCount<2048){ idx=g_pendCount; g_pendCount++; }
   if(idx<0) return;
   g_pend[idx].id=g_eventId; g_pend[idx].t_msc=t_msc; g_pend[idx].dir=dir;
   g_pend[idx].eb=bid; g_pend[idx].ea=ask; g_pend[idx].active=true;
   for(int h=0;h<HZ_COUNT;h++) g_pend[idx].done[h]=false;
}

void ComputeVel(double &v100,double &v250,double &v500,double &v1,double &v3,double &v5,double &v10, const long t_msc)
{
   double pt=(g_point>0.0)? g_point : 1.0;
   long t[7]={100,250,500,1000,3000,5000,10000};
   double out[7]; bool found[7];
   for(int j=0;j<7;j++){ out[j]=0.0; found[j]=false; }
   double nowMid=(g_tBid[g_tHead]+g_tAsk[g_tHead])*0.5;
   int remaining=7; int scanned=0;
   for(int k=0;k<g_tCount && remaining>0 && scanned<3000;k++,scanned++)
   {
      int idx=(g_tHead - k) % TICK_CAP; if(idx<0) idx+=TICK_CAP;
      long age=t_msc - g_tTime[idx];
      for(int j=0;j<7;j++)
         if(!found[j] && age>=t[j])
         { out[j]=(nowMid-(g_tBid[idx]+g_tAsk[idx])*0.5)/pt; found[j]=true; remaining--; }
   }
   v100=out[0]; v250=out[1]; v500=out[2]; v1=out[3]; v3=out[4]; v5=out[5]; v10=out[6];
}

void Detect(const MqlTick &t)
{
   if(g_bCount < InpRegimeBars+2) return;   // warmup
   long nowSec=(long)t.time;
   double pt=(g_point>0.0)? g_point : 1.0;
   double spread=(t.ask-t.bid);
   double v100,v250,v500,v1,v3,v5,v10; ComputeVel(v100,v250,v500,v1,v3,v5,v10,t.time_msc);

   double avg60 = AvgRange(1, InpMeanBars);
   double avg300= AvgRange(1, InpRegimeBars);
   double lastRange = BarRange(0);          // last completed bar
   double compRatio = (avg300>0.0)? avg60/avg300 : 0.0;

   // A: volatility expansion out of compression (follow bar direction)
   if(avg300>0.0 && avg60 < InpCompressionRatio*avg300 && lastRange > InpExpansionMult*avg60)
   {
      if(nowSec - g_lastA >= InpCooldownSec)
      {
         int dir = (g_bars[BarIdx(0)].cb >= g_bars[BarIdx(0)].ob) ? 1 : -1;
         RecordEvent("A_EXPANSION", dir, t.bid, t.ask, avg60/pt, lastRange/pt, 0.0,
                     v100,v250,v500,v1,v3,v5,v10, compRatio, t.time_msc);
         g_lastA=nowSec;
      }
   }

   // B: momentum persistence (follow)
   if(spread>0.0 && MathAbs(v3*pt) > InpMomSpreadMult*spread)
   {
      if(nowSec - g_lastB >= InpCooldownSec)
      {
         int dir = (v3>0.0)? 1 : -1;
         RecordEvent("B_MOMENTUM", dir, t.bid, t.ask, avg60/pt, lastRange/pt, 0.0,
                     v100,v250,v500,v1,v3,v5,v10, compRatio, t.time_msc);
         g_lastB=nowSec;
      }
   }

   // C: breakout of short range (follow)
   double hi=0.0, lo=0.0;
   for(int k=1;k<=InpMeanBars;k++){ double h=g_bars[BarIdx(k)].hb; double l=g_bars[BarIdx(k)].lb;
      if(k==1){hi=h;lo=l;} else {if(h>hi)hi=h; if(l<lo)lo=l;} }
   if(spread>0.0 && t.bid > hi + InpBreakoutSpreadMult*spread)
   {
      if(nowSec - g_lastC >= InpCooldownSec)
      { RecordEvent("C_BREAKOUT", 1, t.bid, t.ask, avg60/pt, lastRange/pt, 0.0,
                    v100,v250,v500,v1,v3,v5,v10, compRatio, t.time_msc); g_lastC=nowSec; }
   }
   else if(spread>0.0 && t.bid < lo - InpBreakoutSpreadMult*spread)
   {
      if(nowSec - g_lastC >= InpCooldownSec)
      { RecordEvent("C_BREAKOUT", -1, t.bid, t.ask, avg60/pt, lastRange/pt, 0.0,
                    v100,v250,v500,v1,v3,v5,v10, compRatio, t.time_msc); g_lastC=nowSec; }
   }

   // D: mean reversion (fade)
   double mean=0.0, ss=0.0;
   for(int k=1;k<=InpMeanBars;k++) mean += BarMid(k);
   mean/=InpMeanBars;
   for(int k=1;k<=InpMeanBars;k++){ double d=BarMid(k)-mean; ss+=d*d; }
   double sd=MathSqrt(ss/InpMeanBars);
   if(sd>0.0)
   {
      double midNow=(t.bid+t.ask)*0.5;
      double z=(midNow-mean)/sd;
      if(MathAbs(z)>InpZThreshold)
      {
         if(nowSec - g_lastD >= InpCooldownSec)
         {
            int dir=(z>0.0)? -1 : 1;   // fade
            RecordEvent("D_REVERSION", dir, t.bid, t.ask, avg60/pt, lastRange/pt, z,
                        v100,v250,v500,v1,v3,v5,v10, compRatio, t.time_msc);
            g_lastD=nowSec;
         }
      }
   }
}

int OnInit()
{
   g_point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   g_fhEv=FileOpen(InpEventsFile, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(g_fhEv==INVALID_HANDLE){ Print("EVENTS_FILE_FAILED ", GetLastError()); return INIT_FAILED; }
   if(FileSize(g_fhEv)==0)
      FileWrite(g_fhEv,"event_id","time_msc","type","direction","hour","weekday","spread_pts",
                "atr_pts","range_pts","z","v100ms","v250ms","v500ms","v1s","v3s","v5s","v10s",
                "comp_ratio","bid","ask");
   FileSeek(g_fhEv,0,SEEK_END);
   g_fhOut=FileOpen(InpOutcomesFile, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(g_fhOut==INVALID_HANDLE){ Print("OUTCOMES_FILE_FAILED ", GetLastError()); return INIT_FAILED; }
   if(FileSize(g_fhOut)==0)
      FileWrite(g_fhOut,"event_id","direction","horizon","entry_bid","entry_ask","exit_bid",
                "exit_ask","net_pts","mfe_pts","mae_pts","positive","ticks");
   FileSeek(g_fhOut,0,SEEK_END);
   for(int i=0;i<2048;i++){ g_pend[i].active=false; for(int h=0;h<HZ_COUNT;h++) g_pend[i].done[h]=false; }
   g_pendCount=0;
   Print("EDGE_DISCOVERY_INIT | point=", g_point, " cooldown=", InpCooldownSec);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_fhOut!=INVALID_HANDLE)
   {
      for(int i=0;i<g_pendCount;i++)
      {
         if(!g_pend[i].active) continue;
         for(int h=0;h<HZ_COUNT;h++)
         {
            if(g_pend[i].done[h]) continue;
            FileWrite(g_fhOut, g_pend[i].id, (g_pend[i].dir>0?"BUY":"SELL"), g_hz_name[h],
                      DoubleToString(g_pend[i].eb,_Digits), DoubleToString(g_pend[i].ea,_Digits),
                      "NA","NA","NA","NA","NA","NA",0);
         }
      }
      FileFlush(g_fhOut); FileClose(g_fhOut); g_fhOut=INVALID_HANDLE;
   }
   if(g_fhEv!=INVALID_HANDLE){ FileFlush(g_fhEv); FileClose(g_fhEv); g_fhEv=INVALID_HANDLE; }
   Print("EDGE_DISCOVERY_DONE | events=", g_eventId);
}

void OnTick()
{
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t)) return;
   bool newSec = (!g_curValid || (long)t.time != g_cur.sec);
   AddTick(t);
   UpdateBar(t);
   ResolveForward(t.time_msc);
   if(newSec) Detect(t);
}
