//+------------------------------------------------------------------+
//| XTRD_MICROSTRUCTURE_DISCOVERY.mq5                                |
//| Sub-second microstructure measurement. NO trading, NO orders.    |
//| Features from tick stream (100ms-10s), forward labels 100ms-10s. |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"
#property description "Sub-second microstructure discovery. Features + forward labels. No trading."

input int    InpSampleSec = 60;
input int    InpMaxWinMs  = 10000;
input string InpFeatFile  = "micro_features.csv";
input string InpOutFile   = "micro_outcomes.csv";

#define HZ 7
long   g_hz[HZ]      = {100,250,500,1000,2000,5000,10000};
string g_hz_name[HZ] = {"100ms","250ms","500ms","1s","2s","5s","10s"};

#define TICK_CAP 16384
long   g_tTime[TICK_CAP];
double g_tBid[TICK_CAP];
double g_tAsk[TICK_CAP];
int    g_tHead=-1;
int    g_tCount=0;

struct Pend { int id; long t_msc; double eb,ea,mid,spread; bool done; };
Pend g_pend[64];
int  g_pendCount=0;
int  g_decId=0;
int  g_fhF=INVALID_HANDLE;
int  g_fhO=INVALID_HANDLE;
double g_point=0.0;
long g_lastSampleSec=0;

void AddTick(const MqlTick &t)
{
   g_tHead=(g_tHead+1)%TICK_CAP;
   g_tTime[g_tHead]=t.time_msc; g_tBid[g_tHead]=t.bid; g_tAsk[g_tHead]=t.ask;
   if(g_tCount<TICK_CAP) g_tCount++;
}
int RingIdx(const int k){ int i=(g_tHead-k)%TICK_CAP; if(i<0) i+=TICK_CAP; return i; }
double RingMid(const int k){ int i=RingIdx(k); return (g_tBid[i]+g_tAsk[i])*0.5; }

// signed tick imbalance over window (ms): sum sign(mid_k-mid_{k-1}) / count
double Imbalance(const long winMs, const long now)
{
   int cnt=0, up=0, dn=0;
   for(int k=0;k<g_tCount-1;k++)
   {
      int i=RingIdx(k); if(now-g_tTime[i] > winMs) break;
      double d=RingMid(k)-RingMid(k+1);
      if(d>0) up++; else if(d<0) dn++;
      cnt++;
   }
   if(cnt==0) return 0.0;
   return (double)(up-dn)/(double)cnt;
}

void Sample(const MqlTick &t)
{
   long now=t.time_msc;
   double pt=(g_point>0.0)?g_point:1.0;
   double mid=(t.bid+t.ask)*0.5;
   // tick direction classification over last 1s (tick rule on mid)
   int up=0,dn=0,zr=0,tot=0;
   for(int k=0;k<g_tCount-1;k++)
   {
      int i=RingIdx(k); if(now-g_tTime[i]>1000) break;
      double d=RingMid(k)-RingMid(k+1);
      if(d>0) up++; else if(d<0) dn++; else zr++;
      tot++;
   }
   double tdu=(tot>0)?(double)up/tot:0, tdd=(tot>0)?(double)dn/tot:0, tdz=(tot>0)?(double)zr/tot:0;
   // bid/ask update rates over last 1s
   int bidUpd=0,askUpd=0,both=0,tt=0; bool first=true; double lb=0,la=0;
   for(int k=g_tCount-1;k>=0;k--)
   {
      int i=RingIdx(k); if(now-g_tTime[i]>1000) break;
      double b=g_tBid[i],a=g_tAsk[i];
      if(!first){ bool bc=(b!=lb),ac=(a!=la); if(bc)bidUpd++; if(ac)askUpd++; if(bc&&ac)both++; tt++; }
      lb=b; la=a; first=false;
   }
   double bidR=(tt>0)?(double)bidUpd/tt:0, askR=(tt>0)?(double)askUpd/tt:0;
   double asym=(bidUpd+askUpd>0)?(double)(bidUpd-askUpd)/(double)(bidUpd+askUpd):0.0;
   // tick rate + inter-arrival over last 1s
   int n1=0; double sumGap=0; long prevT=-1;
   for(int k=0;k<g_tCount;k++)
   {
      int i=RingIdx(k); if(now-g_tTime[i]>1000) break;
      if(prevT>=0) sumGap += (prevT-g_tTime[i]);
      prevT=g_tTime[i]; n1++;
   }
   double tickRate=(double)n1; // per second
   double iat=(n1>1)? sumGap/(n1-1) : 0.0;
   // reversal count in last 1s
   int rev=0, prevSign=0;
   for(int k=0;k<g_tCount-1;k++)
   {
      int i=RingIdx(k); if(now-g_tTime[i]>1000) break;
      double d=RingMid(k)-RingMid(k+1);
      int s=(d>0)?1:((d<0)?-1:0);
      if(s!=0 && prevSign!=0 && s!=prevSign) rev++;
      if(s!=0) prevSign=s;
   }
   // momentum over 1s and 5s (pts)
   double mom1=0, mom5=0;
   for(int k=0;k<g_tCount;k++){ int i=RingIdx(k); if(now-g_tTime[i]>1000){ mom1=(mid-RingMid(k))/pt; break; } }
   for(int k=0;k<g_tCount;k++){ int i=RingIdx(k); if(now-g_tTime[i]>5000){ mom5=(mid-RingMid(k))/pt; break; } }
   double accel=mom1-mom5/5.0;
   // volatility: std of mid changes over 1s
   double mu=0; int vn=0;
   for(int k=0;k<g_tCount-1;k++){ int i=RingIdx(k); if(now-g_tTime[i]>1000) break; mu+=(RingMid(k)-RingMid(k+1))/pt; vn++; }
   mu=(vn>0)?mu/vn:0; double ss=0;
   for(int k=0;k<g_tCount-1;k++){ int i=RingIdx(k); if(now-g_tTime[i]>1000) break; double d=(RingMid(k)-RingMid(k+1))/pt-mu; ss+=d*d; }
   double vol=(vn>0)?MathSqrt(ss/vn):0;
   // spread
   double spNow=(t.ask-t.bid)/pt; double spSum=0; int spN=0;
   for(int k=0;k<g_tCount;k++){ int i=RingIdx(k); if(now-g_tTime[i]>1000) break; spSum+=(g_tAsk[i]-g_tBid[i])/pt; spN++; }
   double spAvg=(spN>0)?spSum/spN:spNow;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   g_decId++;
   if(g_fhF!=INVALID_HANDLE)
   {
      FileWrite(g_fhF,g_decId,now,dt.hour,dt.day_of_week,DoubleToString(t.bid,_Digits),DoubleToString(t.ask,_Digits),
                DoubleToString(spNow,1),DoubleToString(mid,_Digits),
                DoubleToString(Imbalance(100,now),3),DoubleToString(Imbalance(250,now),3),
                DoubleToString(Imbalance(500,now),3),DoubleToString(Imbalance(1000,now),3),
                DoubleToString(Imbalance(2000,now),3),DoubleToString(Imbalance(5000,now),3),
                DoubleToString(Imbalance(10000,now),3),
                DoubleToString(tdu,3),DoubleToString(tdd,3),DoubleToString(tdz,3),
                DoubleToString(bidR,3),DoubleToString(askR,3),DoubleToString(asym,3),
                DoubleToString(tickRate,1),DoubleToString(iat,1),rev,
                DoubleToString(mom1,1),DoubleToString(mom5,1),DoubleToString(accel,2),
                DoubleToString(vol,2),DoubleToString(spAvg,1),DoubleToString(spNow-spAvg,1));
      FileFlush(g_fhF);
   }
   int idx=-1; for(int i=0;i<g_pendCount;i++){ if(g_pend[i].done){ idx=i; break; } }
   if(idx<0 && g_pendCount<64){ idx=g_pendCount; g_pendCount++; }
   if(idx>=0){ g_pend[idx].id=g_decId; g_pend[idx].t_msc=now; g_pend[idx].eb=t.bid; g_pend[idx].ea=t.ask; g_pend[idx].mid=mid; g_pend[idx].spread=spNow; g_pend[idx].done=false; }
}

void Resolve(const long now)
{
   for(int i=0;i<g_pendCount;i++)
   {
      if(g_pend[i].done) continue;
      if(now < g_pend[i].t_msc + InpMaxWinMs) continue;
      MqlTick tk[]; int n=CopyTicksRange(_Symbol,tk,COPY_TICKS_ALL,(ulong)g_pend[i].t_msc,(ulong)(g_pend[i].t_msc+InpMaxWinMs));
      double pt=(g_point>0.0)?g_point:1.0;
      double eb=g_pend[i].eb, ea=g_pend[i].ea, mid=g_pend[i].mid;
      if(n>0)
      {
         for(int h=0;h<HZ;h++)
         {
            long b=g_pend[i].t_msc+g_hz[h]; int last=-1;
            for(int k=0;k<n;k++){ if(tk[k].time_msc<=b) last=k; else break; }
            double xb=(last>=0)?tk[last].bid:eb, xa=(last>=0)?tk[last].ask:ea;
            double nb=(xb-ea)/pt, ns=(eb-xa)/pt;
            if(g_fhO!=INVALID_HANDLE)
               FileWrite(g_fhO,g_pend[i].id,g_hz_name[h],DoubleToString(mid,_Digits),DoubleToString(g_pend[i].spread,1),
                         DoubleToString(nb,2),DoubleToString(ns,2),n);
         }
      }
      g_pend[i].done=true;
   }
}

int OnInit()
{
   g_point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   g_fhF=FileOpen(InpFeatFile,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(g_fhF==INVALID_HANDLE){ Print("FEAT_FAILED ",GetLastError()); return INIT_FAILED; }
   if(FileSize(g_fhF)==0)
      FileWrite(g_fhF,"decision_id","time_msc","hour","weekday","bid","ask","spread_pts","mid",
                "imb100ms","imb250ms","imb500ms","imb1s","imb2s","imb5s","imb10s",
                "tickdir_up","tickdir_dn","tickdir_zero","bid_upd_rate","ask_upd_rate","upd_asym",
                "tick_rate","iat_ms","reversals","mom1s","mom5s","accel","vol1s","spread_avg","spread_chg");
   FileSeek(g_fhF,0,SEEK_END);
   g_fhO=FileOpen(InpOutFile,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(g_fhO==INVALID_HANDLE){ Print("OUT_FAILED ",GetLastError()); return INIT_FAILED; }
   if(FileSize(g_fhO)==0)
      FileWrite(g_fhO,"decision_id","horizon","entry_mid","spread_pts","net_buy","net_sell","ticks");
   FileSeek(g_fhO,0,SEEK_END);
   for(int i=0;i<64;i++) g_pend[i].done=true;
   g_pendCount=0;
   Print("MICRO_DISCOVERY_INIT point=",g_point," sample=",InpSampleSec);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_fhO!=INVALID_HANDLE){ FileFlush(g_fhO); FileClose(g_fhO); g_fhO=INVALID_HANDLE; }
   if(g_fhF!=INVALID_HANDLE){ FileFlush(g_fhF); FileClose(g_fhF); g_fhF=INVALID_HANDLE; }
   Print("MICRO_DISCOVERY_DONE decisions=",g_decId);
}

void OnTick()
{
   MqlTick t; if(!SymbolInfoTick(_Symbol,t)) return;
   AddTick(t); Resolve(t.time_msc);
   long nowSec=(long)t.time;
   if(nowSec-g_lastSampleSec >= InpSampleSec && nowSec>0){ g_lastSampleSec=nowSec; Sample(t); }
}
