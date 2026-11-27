//+------------------------------------------------------------------+
//| XTRD_CONDITIONAL_DISCOVERY.mq5                                   |
//| Conditional predictability measurement. NO trading, NO orders.   |
//| Samples every InpSampleSec, logs market-state features + forward |
//| labels (net buy/sell at 1s..30m) + first-passage at 1/1.5/2/3x    |
//| spread. All features use past data only.                          |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Conditional predictability discovery: features + forward labels. No trading."

input int    InpSampleSec   = 120;    // decision sampling interval (s)
input int    InpShortWinMs  = 300000; // 300s window for short labels
input int    InpLongWinMs   = 1800000;// 1800s window for long labels
input string InpFeaturesFile= "cond_features.csv";
input string InpOutcomesFile= "cond_outcomes.csv";

#define HZ_S 8
long   g_hz_s[HZ_S]   = {1000,3000,5000,10000,30000,60000,120000,300000};
string g_hz_s_name[HZ_S] = {"1s","3s","5s","10s","30s","60s","120s","300s"};
#define HZ_L 4
long   g_hz_l[HZ_L]   = {300000,600000,900000,1800000};
string g_hz_l_name[HZ_L] = {"5m","10m","15m","30m"};
#define LVL 4
double g_lvl_mult[LVL] = {1.0,1.5,2.0,3.0};

#define TICK_CAP 8192
long   g_tTime[TICK_CAP];
double g_tBid[TICK_CAP];
double g_tAsk[TICK_CAP];
int    g_tHead=-1;
int    g_tCount=0;

#define BAR_CAP 400
struct SBar { long sec; double ob,hb,lb,cb, oa,ha,la,ca; int ticks; };
SBar g_bars[BAR_CAP];
int  g_bHead=-1;
int  g_bCount=0;
SBar g_cur;
bool g_curValid=false;

struct Pend { int id; long t_msc; double eb,ea,mid,spread; bool shortDone, longDone; };
Pend g_pend[256];
int  g_pendCount=0;
int  g_decId=0;
int  g_fhF=INVALID_HANDLE;
int  g_fhO=INVALID_HANDLE;
double g_point=0.0;
long g_lastSampleSec=0;

int BarIdx(const int back){ if(g_bCount<=0) return -1; if(back>=g_bCount) return -1; int i=(g_bHead-back)%BAR_CAP; if(i<0) i+=BAR_CAP; return i; }
double BarMid(const int back){ int i=BarIdx(back); if(i<0) return 0.0; return (g_bars[i].cb+g_bars[i].ca)*0.5; }
double BarRange(const int back){ int i=BarIdx(back); if(i<0) return 0.0; return (g_bars[i].hb-g_bars[i].lb); }

void AddTick(const MqlTick &t)
{
   g_tHead=(g_tHead+1)%TICK_CAP;
   g_tTime[g_tHead]=t.time_msc; g_tBid[g_tHead]=t.bid; g_tAsk[g_tHead]=t.ask;
   if(g_tCount<TICK_CAP) g_tCount++;
}

void UpdateBar(const MqlTick &t)
{
   if(!g_curValid || (long)t.time!=g_cur.sec)
   {
      if(g_curValid){ g_bHead=(g_bHead+1)%BAR_CAP; g_bars[g_bHead]=g_cur; if(g_bCount<BAR_CAP) g_bCount++; }
      g_cur.sec=(long)t.time; g_cur.ob=t.bid; g_cur.hb=t.bid; g_cur.lb=t.bid; g_cur.cb=t.bid;
      g_cur.oa=t.ask; g_cur.ha=t.ask; g_cur.la=t.ask; g_cur.ca=t.ask; g_cur.ticks=1; g_curValid=true;
   }
   else
   {
      if(t.bid>g_cur.hb) g_cur.hb=t.bid; if(t.bid<g_cur.lb) g_cur.lb=t.bid; g_cur.cb=t.bid;
      if(t.ask>g_cur.ha) g_cur.ha=t.ask; if(t.ask<g_cur.la) g_cur.la=t.ask; g_cur.ca=t.ask; g_cur.ticks++;
   }
}

void Vel(double &v100,double &v250,double &v500,double &v1,double &v3,double &v5,double &v10,const long now)
{
   double pt=(g_point>0.0)? g_point : 1.0;
   long t[7]={100,250,500,1000,3000,5000,10000}; double out[7]; bool f[7];
   for(int j=0;j<7;j++){out[j]=0;f[j]=false;}
   double nowMid=(g_tBid[g_tHead]+g_tAsk[g_tHead])*0.5; int rem=7,sc=0;
   for(int k=0;k<g_tCount && rem>0 && sc<3000;k++,sc++)
   {
      int idx=(g_tHead-k)%TICK_CAP; if(idx<0) idx+=TICK_CAP; long age=now-g_tTime[idx];
      for(int j=0;j<7;j++) if(!f[j] && age>=t[j]){ out[j]=(nowMid-(g_tBid[idx]+g_tAsk[idx])*0.5)/pt; f[j]=true; rem--; }
   }
   v100=out[0];v250=out[1];v500=out[2];v1=out[3];v3=out[4];v5=out[5];v10=out[6];
}

void Resolve(const long now)
{
   for(int i=0;i<g_pendCount;i++)
   {
      if(!g_pend[i].shortDone && now >= g_pend[i].t_msc + InpShortWinMs)
      {
         MqlTick tk[]; int n=CopyTicksRange(_Symbol,tk,COPY_TICKS_ALL,(ulong)g_pend[i].t_msc,(ulong)(g_pend[i].t_msc+InpShortWinMs));
         double pt=(g_point>0.0)? g_point : 1.0;
         double eb=g_pend[i].eb, ea=g_pend[i].ea, mid=g_pend[i].mid, sp=g_pend[i].spread;
         if(n>0)
         {
            for(int h=0;h<HZ_S;h++)
            {
               long b=g_pend[i].t_msc+g_hz_s[h]; int last=-1;
               for(int k=0;k<n;k++){ if(tk[k].time_msc<=b) last=k; else break; }
               double xb=(last>=0)?tk[last].bid:eb, xa=(last>=0)?tk[last].ask:ea;
               double nb=(xb-ea)/pt, ns=(eb-xa)/pt;
               if(g_fhO!=INVALID_HANDLE)
                  FileWrite(g_fhO,g_pend[i].id,"NET_SHORT",g_hz_s_name[h],DoubleToString(mid,_Digits),DoubleToString(sp,_Digits),
                            DoubleToString(nb,2),DoubleToString(ns,2),"NA","NA","NA","NA",n);
            }
            // first passage per level (UP/DOWN relative to mid), window short
            for(int l=0;l<LVL;l++)
            {
               double lev=g_lvl_mult[l]*sp*g_point;
               long upT=-1, dnT=-1;
               for(int k=0;k<n;k++)
               {
                  double m=(tk[k].bid+tk[k].ask)*0.5;
                  if(upT<0 && m>=mid+lev) upT=(tk[k].time_msc-g_pend[i].t_msc);
                  if(dnT<0 && m<=mid-lev) dnT=(tk[k].time_msc-g_pend[i].t_msc);
                  if(upT>=0 || dnT>=0) { if(upT>=0 && dnT>=0) break; }
               }
               string side="NONE"; if(upT>=0 && (dnT<0 || upT<dnT)) side="UP"; else if(dnT>=0) side="DOWN";
               if(g_fhO!=INVALID_HANDLE)
                  FileWrite(g_fhO,g_pend[i].id,"FIRST",DoubleToString(g_lvl_mult[l],1)+"x",DoubleToString(mid,_Digits),DoubleToString(sp,_Digits),
                            "NA","NA","NA","NA",
                            (upT>=0?DoubleToString(upT/1000.0,2):"NA"),(dnT>=0?DoubleToString(dnT/1000.0,2):"NA"),side,n);
            }
         }
         g_pend[i].shortDone=true;
      }
      if(!g_pend[i].longDone && now >= g_pend[i].t_msc + InpLongWinMs)
      {
         MqlTick tk[]; int n=CopyTicksRange(_Symbol,tk,COPY_TICKS_ALL,(ulong)g_pend[i].t_msc,(ulong)(g_pend[i].t_msc+InpLongWinMs));
         double pt=(g_point>0.0)? g_point : 1.0;
         double eb=g_pend[i].eb, ea=g_pend[i].ea, mid=g_pend[i].mid, sp=g_pend[i].spread;
         if(n>0)
         {
            for(int h=0;h<HZ_L;h++)
            {
               long b=g_pend[i].t_msc+g_hz_l[h]; int last=-1;
               for(int k=0;k<n;k++){ if(tk[k].time_msc<=b) last=k; else break; }
               double xb=(last>=0)?tk[last].bid:eb, xa=(last>=0)?tk[last].ask:ea;
               double nb=(xb-ea)/pt, ns=(eb-xa)/pt;
               if(g_fhO!=INVALID_HANDLE)
                  FileWrite(g_fhO,g_pend[i].id,"NET_LONG",g_hz_l_name[h],DoubleToString(mid,_Digits),DoubleToString(sp,_Digits),
                            DoubleToString(nb,2),DoubleToString(ns,2),"NA","NA","NA","NA",n);
            }
         }
         g_pend[i].longDone=true;
      }
   }
}

void Sample(const MqlTick &t)
{
   if(g_bCount < 62) return;
   double pt=(g_point>0.0)? g_point : 1.0;
   double v100,v250,v500,v1,v3,v5,v10; Vel(v100,v250,v500,v1,v3,v5,v10,t.time_msc);
   double accel=v1-v3;
   double range60=0, atr60=0, atr300=0;
   for(int k=1;k<=60;k++) atr60 += BarRange(k);
   atr60/=60.0;
   int nb=MathMin(300,g_bCount-1);
   for(int k=1;k<=nb;k++) atr300 += BarRange(k);
   atr300/=(double)nb;
   double hi=0,lo=0;
   for(int k=1;k<=60;k++){ double h=g_bars[BarIdx(k)].hb, l=g_bars[BarIdx(k)].lb; if(k==1){hi=h;lo=l;} else {if(h>hi)hi=h; if(l<lo)lo=l;} }
   range60=hi-lo;
   double comp=(atr300>0)? atr60/atr300 : 0.0;
   // efficiency + reversals from 1s mid deltas over last 60
   double path=0, net=0, prev=BarMid(60); int rev=0, prevSign=0;
   for(int k=59;k>=0;k--){ double m=BarMid(k); double d=m-prev; path+=MathAbs(d); net+=d;
      int s=(d>0)?1:((d<0)?-1:0); if(s!=0 && prevSign!=0 && s!=prevSign) rev++; if(s!=0) prevSign=s; prev=m; }
   double eff=(path>0)? MathAbs(net)/path : 0.0;
   double mid=(t.bid+t.ask)*0.5;
   double dhi=(atr60>0)? (mid-hi)/atr60 : 0.0;
   double dlo=(atr60>0)? (mid-lo)/atr60 : 0.0;
   // spread stats + update rates over last 5s
   double spNow=(t.ask-t.bid)/pt;
   double spSum=0; int spN=0;
   long cutoff=t.time_msc-5000; int bidUpd=0, askUpd=0, both=0, tot=0;
   double lastBid=0,lastAsk=0; bool first=true;
   for(int k=g_tCount-1;k>=0;k--)
   {
      int idx=(g_tHead-k)%TICK_CAP; if(idx<0) idx+=TICK_CAP;
      if(g_tTime[idx]<cutoff) break;
      double b=g_tBid[idx], a=g_tAsk[idx];
      spSum+=(a-b)/pt; spN++;
      if(!first){ bool bc=(b!=lastBid), ac=(a!=lastAsk); if(bc)bidUpd++; if(ac)askUpd++; if(bc&&ac)both++; tot++; }
      lastBid=b; lastAsk=a; first=false;
   }
   double spAvg=(spN>0)? spSum/spN : spNow;
   double bidRate=(tot>0)? (double)bidUpd/tot : 0.0;
   double askRate=(tot>0)? (double)askUpd/tot : 0.0;
   double sync=(tot>0)? (double)both/tot : 0.0;
   // z
   double mean=0; for(int k=1;k<=60;k++) mean+=BarMid(k); mean/=60.0;
   double ss=0; for(int k=1;k<=60;k++){ double d=BarMid(k)-mean; ss+=d*d; }
   double sd=MathSqrt(ss/60.0);
   double z=(sd>0)? (mid-mean)/sd : 0.0;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   g_decId++;
   if(g_fhF!=INVALID_HANDLE)
   {
      FileWrite(g_fhF,g_decId,(long)t.time_msc,dt.hour,dt.day_of_week,
                DoubleToString(t.bid,_Digits),DoubleToString(t.ask,_Digits),DoubleToString(spNow,1),
                DoubleToString(mid,_Digits),
                DoubleToString(v100,2),DoubleToString(v250,2),DoubleToString(v500,2),DoubleToString(v1,2),
                DoubleToString(v3,2),DoubleToString(v5,2),DoubleToString(v10,2),DoubleToString(accel,2),
                DoubleToString(range60/pt,1),DoubleToString(atr60/pt,1),DoubleToString(atr300/pt,1),
                DoubleToString(comp,3),DoubleToString(eff,3),rev,
                DoubleToString(dhi,2),DoubleToString(dlo,2),
                DoubleToString(spAvg,1),DoubleToString(spNow-spAvg,1),
                DoubleToString(bidRate,3),DoubleToString(askRate,3),DoubleToString(sync,3),DoubleToString(z,2));
      FileFlush(g_fhF);
   }
   int idx=-1; for(int i=0;i<g_pendCount;i++){ if(g_pend[i].shortDone && g_pend[i].longDone){ idx=i; break; } }
   if(idx<0 && g_pendCount<256){ idx=g_pendCount; g_pendCount++; }
   if(idx>=0){ g_pend[idx].id=g_decId; g_pend[idx].t_msc=t.time_msc; g_pend[idx].eb=t.bid; g_pend[idx].ea=t.ask;
               g_pend[idx].mid=mid; g_pend[idx].spread=spNow; g_pend[idx].shortDone=false; g_pend[idx].longDone=false; }
}

int OnInit()
{
   g_point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   g_fhF=FileOpen(InpFeaturesFile,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(g_fhF==INVALID_HANDLE){ Print("FEAT_FAILED ",GetLastError()); return INIT_FAILED; }
   if(FileSize(g_fhF)==0)
      FileWrite(g_fhF,"decision_id","time_msc","hour","weekday","bid","ask","spread_pts","mid",
                "v100ms","v250ms","v500ms","v1s","v3s","v5s","v10s","accel",
                "range60_pts","atr60_pts","atr300_pts","comp_ratio","efficiency","reversals",
                "dist_high","dist_low","spread_avg60","spread_change","bid_upd_rate","ask_upd_rate","sync","z");
   FileSeek(g_fhF,0,SEEK_END);
   g_fhO=FileOpen(InpOutcomesFile,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(g_fhO==INVALID_HANDLE){ Print("OUT_FAILED ",GetLastError()); return INIT_FAILED; }
   if(FileSize(g_fhO)==0)
      FileWrite(g_fhO,"decision_id","kind","key","entry_mid","spread_pts","net_buy","net_sell",
                "mfe","mae","up_time_s","down_time_s","first_side","ticks");
   FileSeek(g_fhO,0,SEEK_END);
   for(int i=0;i<256;i++){ g_pend[i].shortDone=true; g_pend[i].longDone=true; }
   g_pendCount=0;
   Print("COND_DISCOVERY_INIT point=",g_point," sample=",InpSampleSec);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_fhO!=INVALID_HANDLE){ FileFlush(g_fhO); FileClose(g_fhO); g_fhO=INVALID_HANDLE; }
   if(g_fhF!=INVALID_HANDLE){ FileFlush(g_fhF); FileClose(g_fhF); g_fhF=INVALID_HANDLE; }
   Print("COND_DISCOVERY_DONE decisions=",g_decId);
}

void OnTick()
{
   MqlTick t; if(!SymbolInfoTick(_Symbol,t)) return;
   AddTick(t); UpdateBar(t); Resolve(t.time_msc);
   long nowSec=(long)t.time;
   if(nowSec-g_lastSampleSec >= InpSampleSec && nowSec>0){ g_lastSampleSec=nowSec; Sample(t); }
}
