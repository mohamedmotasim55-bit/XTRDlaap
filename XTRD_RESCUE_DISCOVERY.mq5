//+------------------------------------------------------------------+
//| XTRD_RESCUE_DISCOVERY.mq5                                        |
//| Rescue research: longer horizons, delayed entry, first-passage.  |
//| NO trading, NO orders. Features use past data only.              |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"
#property description "Rescue discovery: longer horizons, delayed entry, first-passage. No trading."

input int    InpSampleSec = 60;
input int    InpWinMs     = 300000;   // 300s outcome window
input string InpFeatFile  = "rescue_features.csv";
input string InpOutFile   = "rescue_outcomes.csv";

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

void AddTick(const MqlTick &t){ g_tHead=(g_tHead+1)%TICK_CAP; g_tTime[g_tHead]=t.time_msc; g_tBid[g_tHead]=t.bid; g_tAsk[g_tHead]=t.ask; if(g_tCount<TICK_CAP) g_tCount++; }
int RingIdx(const int k){ int i=(g_tHead-k)%TICK_CAP; if(i<0) i+=TICK_CAP; return i; }
double RingMid(const int k){ int i=RingIdx(k); return (g_tBid[i]+g_tAsk[i])*0.5; }

double Imbalance(const long winMs,const long now)
{
   int cnt=0,up=0,dn=0;
   for(int k=0;k<g_tCount-1;k++){ int i=RingIdx(k); if(now-g_tTime[i]>winMs) break; double d=RingMid(k)-RingMid(k+1); if(d>0)up++; else if(d<0)dn++; cnt++; }
   if(cnt==0) return 0.0; return (double)(up-dn)/(double)cnt;
}

void Sample(const MqlTick &t)
{
   long now=t.time_msc; double pt=(g_point>0.0)?g_point:1.0;
   double mid=(t.bid+t.ask)*0.5;
   int up=0,dn=0,zr=0,tot=0;
   for(int k=0;k<g_tCount-1;k++){ int i=RingIdx(k); if(now-g_tTime[i]>1000) break; double d=RingMid(k)-RingMid(k+1); if(d>0)up++; else if(d<0)dn++; else zr++; tot++; }
   double tdu=(tot>0)?(double)up/tot:0;
   int bidUpd=0,askUpd=0,tt=0; bool first=true; double lb=0,la=0;
   for(int k=g_tCount-1;k>=0;k--){ int i=RingIdx(k); if(now-g_tTime[i]>1000) break; double b=g_tBid[i],a=g_tAsk[i]; if(!first){ if(b!=lb)bidUpd++; if(a!=la)askUpd++; tt++; } lb=b; la=a; first=false; }
   double asym=(bidUpd+askUpd>0)?(double)(bidUpd-askUpd)/(double)(bidUpd+askUpd):0.0;
   int n1=0; for(int k=0;k<g_tCount;k++){ int i=RingIdx(k); if(now-g_tTime[i]>1000) break; n1++; }
   double tickRate=(double)n1;
   int rev=0,ps=0;
   for(int k=0;k<g_tCount-1;k++){ int i=RingIdx(k); if(now-g_tTime[i]>1000) break; double d=RingMid(k)-RingMid(k+1); int s=(d>0)?1:((d<0)?-1:0); if(s!=0&&ps!=0&&s!=ps)rev++; if(s!=0)ps=s; }
   double mom1=0,mom5=0;
   for(int k=0;k<g_tCount;k++){ int i=RingIdx(k); if(now-g_tTime[i]>1000){ mom1=(mid-RingMid(k))/pt; break; } }
   for(int k=0;k<g_tCount;k++){ int i=RingIdx(k); if(now-g_tTime[i]>5000){ mom5=(mid-RingMid(k))/pt; break; } }
   double mu=0; int vn=0;
   for(int k=0;k<g_tCount-1;k++){ int i=RingIdx(k); if(now-g_tTime[i]>1000) break; mu+=(RingMid(k)-RingMid(k+1))/pt; vn++; }
   mu=(vn>0)?mu/vn:0; double ss=0;
   for(int k=0;k<g_tCount-1;k++){ int i=RingIdx(k); if(now-g_tTime[i]>1000) break; double d=(RingMid(k)-RingMid(k+1))/pt-mu; ss+=d*d; }
   double vol=(vn>0)?MathSqrt(ss/vn):0;
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
                DoubleToString(tdu,3),DoubleToString(asym,3),DoubleToString(tickRate,1),rev,
                DoubleToString(mom1,1),DoubleToString(mom5,1),DoubleToString(vol,2),
                DoubleToString(spAvg,1),DoubleToString(spNow-spAvg,1));
      FileFlush(g_fhF);
   }
   int idx=-1; for(int i=0;i<g_pendCount;i++){ if(g_pend[i].done){ idx=i; break; } }
   if(idx<0 && g_pendCount<64){ idx=g_pendCount; g_pendCount++; }
   if(idx>=0){ g_pend[idx].id=g_decId; g_pend[idx].t_msc=now; g_pend[idx].eb=t.bid; g_pend[idx].ea=t.ask; g_pend[idx].mid=mid; g_pend[idx].spread=spNow; g_pend[idx].done=false; }
}

double ExitAt(const MqlTick &tk[],int n,long base,long off,bool buy,double defv,double pt)
{
   long b=base+off; int last=-1;
   for(int k=0;k<n;k++){ if(tk[k].time_msc<=b) last=k; else break; }
   if(last<0) return defv;
   return buy? tk[last].bid : tk[last].ask;
}

void Resolve(const long now)
{
   for(int i=0;i<g_pendCount;i++)
   {
      if(g_pend[i].done) continue;
      if(now < g_pend[i].t_msc + InpWinMs) continue;
      MqlTick tk[]; int n=CopyTicksRange(_Symbol,tk,COPY_TICKS_ALL,(ulong)g_pend[i].t_msc,(ulong)(g_pend[i].t_msc+InpWinMs));
      double pt=(g_point>0.0)?g_point:1.0;
      double eb=g_pend[i].eb, ea=g_pend[i].ea, mid=g_pend[i].mid, sp=g_pend[i].spread;
      if(n>0)
      {
         // NET at 30,60,120,300s from decision entry
         long hs[4]={30000,60000,120000,300000}; string hn[4]={"30s","60s","120s","300s"};
         for(int h=0;h<4;h++){
            double xb=ExitAt(tk,n,g_pend[i].t_msc,hs[h],true,eb,pt);
            double xa=ExitAt(tk,n,g_pend[i].t_msc,hs[h],false,ea,pt);
            double nb=(xb-ea)/pt, ns=(eb-xa)/pt;
            if(g_fhO!=INVALID_HANDLE) FileWrite(g_fhO,g_pend[i].id,"NET",hn[h],DoubleToString(nb,2),DoubleToString(ns,2),"NA","NA","NA");
         }
         // DELAYED entry: enter at +1s/+5s, hold to +60s/+120s (price at entry time)
         long dl[3]={1000,5000,1000}; long dh[3]={60000,60000,120000}; string dn[3]={"d1s_h60s","d5s_h60s","d1s_h120s"};
         for(int d=0;d<3;d++){
            // entry price at decision+dl: last tick <= that
            long be=g_pend[i].t_msc+dl[d]; int le=-1;
            for(int k=0;k<n;k++){ if(tk[k].time_msc<=be) le=k; else break; }
            if(le<0) continue;
            double deb=tk[le].bid, dea=tk[le].ask;
            long bx=g_pend[i].t_msc+dl[d]+dh[d]; int lx=-1;
            for(int k=0;k<n;k++){ if(tk[k].time_msc<=bx) lx=k; else break; }
            if(lx<0) continue;
            double xb=tk[lx].bid, xa=tk[lx].ask;
            double nb=(xb-dea)/pt, ns=(deb-xa)/pt;
            if(g_fhO!=INVALID_HANDLE) FileWrite(g_fhO,g_pend[i].id,"DELAY",dn[d],DoubleToString(nb,2),DoubleToString(ns,2),"NA","NA","NA");
         }
         // FIRST PASSAGE: targets/stops in spread units; use executable exit side
         double T[3]={2.0,3.0,3.0}; double S[3]={1.0,1.0,2.0}; string kn[3]={"T2_S1","T3_S1","T3_S2"};
         for(int c=0;c<3;c++){
            double levT=T[c]*sp*pt, levS=S[c]*sp*pt;
            // BUY: exit=bid; target=entry_ask+levT; stop=entry_ask-levS
            long bt=-1, bs=-1;
            for(int k=0;k<n;k++){
               double b=tk[k].bid;
               if(bt<0 && b>=ea+levT) bt=tk[k].time_msc;
               if(bs<0 && b<=ea-levS) bs=tk[k].time_msc;
               if(bt>=0||bs>=0){ if(bt>=0&&bs>=0) break; }
            }
            string sideB="NONE"; double pnlB=0;
            if(bt>=0 && (bs<0||bt<bs)){ sideB="TARGET"; pnlB=T[c]*sp; }
            else if(bs>=0){ sideB="STOP"; pnlB=-S[c]*sp; }
            else { sideB="TIME"; pnlB=(tk[n-1].bid-ea)/pt; }
            // SELL: exit=ask; target=entry_bid-levT; stop=entry_bid+levS
            long st=-1, ss2=-1;
            for(int k=0;k<n;k++){
               double a=tk[k].ask;
               if(st<0 && a<=eb-levT) st=tk[k].time_msc;
               if(ss2<0 && a>=eb+levS) ss2=tk[k].time_msc;
               if(st>=0||ss2>=0){ if(st>=0&&ss2>=0) break; }
            }
            string sideS="NONE"; double pnlS=0;
            if(st>=0 && (ss2<0||st<ss2)){ sideS="TARGET"; pnlS=T[c]*sp; }
            else if(ss2>=0){ sideS="STOP"; pnlS=-S[c]*sp; }
            else { sideS="TIME"; pnlS=(eb-tk[n-1].ask)/pt; }
            if(g_fhO!=INVALID_HANDLE) FileWrite(g_fhO,g_pend[i].id,"FIRST",kn[c],DoubleToString(pnlB,2),DoubleToString(pnlS,2),sideB,sideS,"NA");
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
                "imb100ms","imb250ms","imb500ms","imb1s","imb2s","imb5s",
                "tickdir_up","upd_asym","tick_rate","reversals","mom1s","mom5s","vol1s","spread_avg","spread_chg");
   FileSeek(g_fhF,0,SEEK_END);
   g_fhO=FileOpen(InpOutFile,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(g_fhO==INVALID_HANDLE){ Print("OUT_FAILED ",GetLastError()); return INIT_FAILED; }
   if(FileSize(g_fhO)==0)
      FileWrite(g_fhO,"decision_id","kind","key","val_buy","val_sell","side_buy","side_sell","extra");
   FileSeek(g_fhO,0,SEEK_END);
   for(int i=0;i<64;i++) g_pend[i].done=true;
   g_pendCount=0;
   Print("RESCUE_INIT point=",g_point," sample=",InpSampleSec);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_fhO!=INVALID_HANDLE){ FileFlush(g_fhO); FileClose(g_fhO); g_fhO=INVALID_HANDLE; }
   if(g_fhF!=INVALID_HANDLE){ FileFlush(g_fhF); FileClose(g_fhF); g_fhF=INVALID_HANDLE; }
   Print("RESCUE_DONE decisions=",g_decId);
}

void OnTick()
{
   MqlTick t; if(!SymbolInfoTick(_Symbol,t)) return;
   AddTick(t); Resolve(t.time_msc);
   long nowSec=(long)t.time;
   if(nowSec-g_lastSampleSec >= InpSampleSec && nowSec>0){ g_lastSampleSec=nowSec; Sample(t); }
}
