//+------------------------------------------------------------------+
//| XTRD_OMIGA_EDGE_LAB_v2_0_1.mq5                                  |
//| Research-only collector. NEVER sends trade orders.               |
//+------------------------------------------------------------------+
#property strict
#property version   "2.01"
#property description "XTRD OMIGA EDGE LAB v2.0.1 - research data collector only"

input string InpSymbol              = "";       // Empty = chart symbol
input int    InpForwardSeconds      = 300;      // Forward-path horizon
input int    InpMaxTicksInMemory    = 200000;   // RAM safety cap
input int    InpFlushEveryTicks     = 5000;     // Batch flush
input int    InpMinSpreadPoints     = 1;
input int    InpMaxSpreadPoints     = 500;
input bool   InpEnableH1            = true;
input bool   InpEnableH2            = true;
input bool   InpEnableH3            = true;
input bool   InpEnableRandomBaseline= true;
input int    InpRandomEverySeconds  = 60;
input double InpH1ImpulseATRFactor  = 1.8;
input double InpH2BreakoutSpreadFrac= 0.35;
input int    InpH3LookbackSeconds   = 900;
input int    InpH3MaxSweepSeconds   = 15;

struct TickRec
{
   ulong seq;
   long  time_msc;
   double bid, ask, mid, spread_pts;
};
TickRec ticks[];
int tick_count=0;
ulong next_seq=1;
int ticks_since_flush=0;
int fh_ticks=INVALID_HANDLE, fh_signals=INVALID_HANDLE;
string sym;
double point_size=0.0, tick_size=0.0;
int digits_n=0;
long last_random_sec=-1;
long last_h1_sec=-1, last_h2_sec=-1, last_h3_sec=-1;
ulong next_signal_id=1;
long last_tick_msc=-1;
int server_utc_offset_sec=0;

//+------------------------------------------------------------------+
int OnInit()
{
   sym=(InpSymbol=="") ? _Symbol : InpSymbol;
   if(!SymbolSelect(sym,true))
   {
      Print("ERROR: cannot select symbol ",sym);
      return INIT_FAILED;
   }
   point_size=SymbolInfoDouble(sym,SYMBOL_POINT);
   tick_size=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
   digits_n=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
   if(point_size<=0 || tick_size<=0)
   {
      Print("ERROR: invalid point/tick size");
      return INIT_FAILED;
   }
   ArrayResize(ticks,0);
   string prefix="XTRD_"+sym+"_";
   fh_ticks=FileOpen(prefix+"Market_Ticks.csv",FILE_WRITE|FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ,',');
   fh_signals=FileOpen(prefix+"Signal_Snapshot.csv",FILE_WRITE|FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ,',');
   if(fh_ticks==INVALID_HANDLE || fh_signals==INVALID_HANDLE)
   {
      Print("ERROR opening CSV files. code=",GetLastError());
      return INIT_FAILED;
   }
   if(FileSize(fh_ticks)==0)
      FileWrite(fh_ticks,"tick_seq","tick_time_msc","bid","ask","mid","spread_pts","flags");
   if(FileSize(fh_signals)==0)
      FileWrite(fh_signals,"signal_id","wave_id","hypothesis_type","direction","signal_time_msc",
                "trigger_tick_seq","server_utc_offset_sec","entry_bid","entry_ask","entry_spread_pts",
                "raw_move_pts","raw_velocity_pts_s","raw_efficiency","raw_realized_vol_pts",
                "raw_vol_percentile","raw_quote_rate_s","structural_sl_price","structural_sl_pts",
                "spread_is_static","collector_version","feature_version","data_quality_flag");
   FileSeek(fh_ticks,0,SEEK_END);
   FileSeek(fh_signals,0,SEEK_END);
   Print("XTRD EDGE LAB v2.0.1 started. Symbol=",sym,
         " Point=",DoubleToString(point_size,digits_n),
         " TickSize=",DoubleToString(tick_size,digits_n),
         ". Research only: no trading functions are used.");
   return INIT_SUCCEEDED;
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   FlushAll();
   if(fh_ticks!=INVALID_HANDLE) FileClose(fh_ticks);
   if(fh_signals!=INVALID_HANDLE) FileClose(fh_signals);
   Print("XTRD EDGE LAB stopped. reason=",reason," ticks=",tick_count);
}
//+------------------------------------------------------------------+
void OnTick()
{
   MqlTick q;
   if(!SymbolInfoTick(sym,q)) return;
   if(q.bid<=0 || q.ask<=0 || q.ask<q.bid) return;
   long tm=(long)q.time_msc;
   if(tm<=0) return;

   // Preserve every received tick, including equal millisecond timestamps.
   TickRec r;
   r.seq=next_seq++;
   r.time_msc=tm;
   r.bid=q.bid; r.ask=q.ask;
   r.mid=(q.bid+q.ask)*0.5;
   r.spread_pts=(q.ask-q.bid)/point_size;

   int n=ArraySize(ticks);
   if(n>=InpMaxTicksInMemory && n>0)
   {
      // Keep a rolling RAM window; already-written raw ticks remain on disk.
      int keep=MathMax(1000,InpMaxTicksInMemory/2);
      int remove=n-keep;
      for(int i=0;i<keep;i++) ticks[i]=ticks[i+remove];
      ArrayResize(ticks,keep);
      n=keep;
   }
   ArrayResize(ticks,n+1);
   ticks[n]=r;
   tick_count++;

   uint flags=(uint)q.flags;
   FileWrite(fh_ticks,(long)r.seq,r.time_msc,
             DoubleToString(r.bid,digits_n),DoubleToString(r.ask,digits_n),
             DoubleToString(r.mid,digits_n),DoubleToString(r.spread_pts,2),flags);
   ticks_since_flush++;
   if(ticks_since_flush>=InpFlushEveryTicks) FlushAll();

   // Reject stale/out-of-order timestamps for feature generation, but retain them in raw log.
   if(last_tick_msc>0 && tm<last_tick_msc) return;
   last_tick_msc=tm;
   if(r.spread_pts<InpMinSpreadPoints || r.spread_pts>InpMaxSpreadPoints) return;

   DetectH1(r);
   DetectH2(r);
   DetectH3(r);
   DetectRandom(r);
}
//+------------------------------------------------------------------+
void FlushAll()
{
   if(fh_ticks!=INVALID_HANDLE) FileFlush(fh_ticks);
   if(fh_signals!=INVALID_HANDLE) FileFlush(fh_signals);
   ticks_since_flush=0;
}
//+------------------------------------------------------------------+
int FindAtOrBefore(long target_msc)
{
   for(int i=ArraySize(ticks)-1;i>=0;i--)
      if(ticks[i].time_msc<=target_msc) return i;
   return -1;
}
//+------------------------------------------------------------------+
double MidAtOrBefore(long target_msc)
{
   int i=FindAtOrBefore(target_msc);
   if(i<0) return 0;
   return ticks[i].mid;
}
//+------------------------------------------------------------------+
double RangeHigh(long from_msc,long to_msc)
{
   double v=-DBL_MAX;
   for(int i=0;i<ArraySize(ticks);i++)
      if(ticks[i].time_msc>=from_msc && ticks[i].time_msc<=to_msc)
         v=MathMax(v,ticks[i].mid);
   return (v==-DBL_MAX ? 0 : v);
}
double RangeLow(long from_msc,long to_msc)
{
   double v=DBL_MAX;
   for(int i=0;i<ArraySize(ticks);i++)
      if(ticks[i].time_msc>=from_msc && ticks[i].time_msc<=to_msc)
         v=MathMin(v,ticks[i].mid);
   return (v==DBL_MAX ? 0 : v);
}
double PathAbsMove(long from_msc,long to_msc)
{
   double sum=0,prev=0;
   bool have=false;
   for(int i=0;i<ArraySize(ticks);i++)
      if(ticks[i].time_msc>=from_msc && ticks[i].time_msc<=to_msc)
      {
         if(have) sum+=MathAbs(ticks[i].mid-prev);
         prev=ticks[i].mid; have=true;
      }
   return sum;
}
double QuoteRate(long from_msc,long to_msc)
{
   int c=0;
   for(int i=0;i<ArraySize(ticks);i++)
      if(ticks[i].time_msc>=from_msc && ticks[i].time_msc<=to_msc) c++;
   double secs=(to_msc-from_msc)/1000.0;
   return (secs>0 ? c/secs : 0);
}
double RealizedVolPts(long from_msc,long to_msc)
{
   double sum=0, sum2=0; int c=0;
   double prev=0; bool have=false;
   for(int i=0;i<ArraySize(ticks);i++)
      if(ticks[i].time_msc>=from_msc && ticks[i].time_msc<=to_msc)
      {
         if(have)
         {
            double d=(ticks[i].mid-prev)/point_size;
            sum+=d; sum2+=d*d; c++;
         }
         prev=ticks[i].mid; have=true;
      }
   if(c<2) return 0;
   double mean=sum/c;
   return MathSqrt(MathMax(0,(sum2/c)-mean*mean));
}
double MedianSpread(long from_msc,long to_msc)
{
   double a[]; int c=0;
   for(int i=0;i<ArraySize(ticks);i++)
      if(ticks[i].time_msc>=from_msc && ticks[i].time_msc<=to_msc)
      { ArrayResize(a,c+1); a[c++]=ticks[i].spread_pts; }
   if(c==0) return 0;
   ArraySort(a);
   if(c%2==1) return a[c/2];
   return (a[c/2-1]+a[c/2])*0.5;
}
void EmitSignal(string hyp,int dir,TickRec &r,double move_pts,double vel,
                double eff,double vol,double qrate,double sl_price)
{
   if(sl_price<=0) return;
   double sl_pts=(dir>0 ? (r.ask-sl_price) : (sl_price-r.bid))/point_size;
   FileWrite(fh_signals,(long)next_signal_id++,0,hyp,dir,r.time_msc,(long)r.seq,
      server_utc_offset_sec,DoubleToString(r.bid,digits_n),DoubleToString(r.ask,digits_n),
      DoubleToString(r.spread_pts,2),DoubleToString(move_pts,2),DoubleToString(vel,3),
      DoubleToString(eff,4),DoubleToString(vol,3),"NA",DoubleToString(qrate,3),
      DoubleToString(sl_price,digits_n),DoubleToString(sl_pts,2),0,
      "2.0.1","H1H2H3_draft_1","OK");
}
//+------------------------------------------------------------------+
// H1: completed impulse over 5-20s, pullback 25-55%, then micro-break.
void DetectH1(TickRec &r)
{
   if(!InpEnableH1 || r.time_msc-last_h1_sec<1000) return;
   long t=r.time_msc;
   int i20=FindAtOrBefore(t-20000), i5=FindAtOrBefore(t-5000);
   int i3=FindAtOrBefore(t-3000);
   if(i20<0 || i5<0 || i3<0) return;
   double base=ticks[i20].mid;
   double high=RangeHigh(t-20000,t-5000), low=RangeLow(t-20000,t-5000);
   double vol=RealizedVolPts(t-60000,t-1000);
   double medsp=MedianSpread(t-60000,t-1000);
   if(vol<=0 || medsp<=0) return;
   double path=PathAbsMove(t-20000,t-5000);
   double netUp=(high-base)/point_size, netDn=(base-low)/point_size;
   double effUp=(path>0 ? MathAbs(high-base)/point_size/path : 0);
   double effDn=(path>0 ? MathAbs(base-low)/point_size/path : 0);
   double recentHigh=RangeHigh(t-3000,t), recentLow=RangeLow(t-3000,t);
   double currentPullLow=RangeLow(t-45000,t-3000);
   double currentPullHigh=RangeHigh(t-45000,t-3000);
   double impUp=(high-base)/point_size, pbUp=(high-currentPullLow)/point_size;
   double impDn=(base-low)/point_size, pbDn=(currentPullHigh-low)/point_size;
   double qrate=QuoteRate(t-5000,t);
   if(impUp>=MathMax(2.0*medsp,InpH1ImpulseATRFactor*vol) && effUp>=0.60 &&
      impUp>0 && pbUp/impUp>=0.25 && pbUp/impUp<=0.55 && r.mid>recentHigh &&
      r.spread_pts<=1.2*medsp)
   {
      EmitSignal("H1_IMP_PB",1,r,impUp,impUp/15.0,effUp,vol,qrate,currentPullLow-0.25*vol*point_size);
      last_h1_sec=t;
   }
   else if(impDn>=MathMax(2.0*medsp,InpH1ImpulseATRFactor*vol) && effDn>=0.60 &&
      impDn>0 && pbDn/impDn>=0.25 && pbDn/impDn<=0.55 && r.mid<recentLow &&
      r.spread_pts<=1.2*medsp)
   {
      EmitSignal("H1_IMP_PB",-1,r,impDn,impDn/15.0,effDn,vol,qrate,currentPullHigh+0.25*vol*point_size);
      last_h1_sec=t;
   }
}
//+------------------------------------------------------------------+
// H2: five-minute low realized movement vs rolling 60-minute reference,
// then break of the completed box with quote-rate expansion.
void DetectH2(TickRec &r)
{
   if(!InpEnableH2 || r.time_msc-last_h2_sec<1000) return;
   long t=r.time_msc;
   int boxStart=FindAtOrBefore(t-301000), refStart=FindAtOrBefore(t-3600000);
   if(boxStart<0 || refStart<0) return;
   double boxVol=RealizedVolPts(t-301000,t-1000);
   double refVol=RealizedVolPts(t-3600000,t-1000);
   if(boxVol<=0 || refVol<=0 || boxVol>refVol*0.65) return; // conservative proxy; percentile computed offline
   double hi=RangeHigh(t-301000,t-1000), lo=RangeLow(t-301000,t-1000);
   double rateSq=QuoteRate(t-301000,t-1000), rateNow=QuoteRate(t-3000,t);
   double path=PathAbsMove(t-3000,t);
   double net=MathAbs(r.mid-MidAtOrBefore(t-3000));
   double eff=(path>0 ? net/path : 0);
   double qrate=QuoteRate(t-5000,t);
   if(hi>0 && r.mid>hi+InpH2BreakoutSpreadFrac*r.spread_pts*point_size &&
      rateNow>=2.0*rateSq && eff>=0.70)
   {
      double sl=(hi+lo)*0.5;
      EmitSignal("H2_VOL_EXP",1,r,(r.mid-hi)/point_size,(r.mid-hi)/point_size/3.0,eff,boxVol,qrate,sl);
      last_h2_sec=t;
   }
   else if(lo>0 && r.mid<lo-InpH2BreakoutSpreadFrac*r.spread_pts*point_size &&
      rateNow>=2.0*rateSq && eff>=0.70)
   {
      double sl=(hi+lo)*0.5;
      EmitSignal("H2_VOL_EXP",-1,r,(lo-r.mid)/point_size,(lo-r.mid)/point_size/3.0,eff,boxVol,qrate,sl);
      last_h2_sec=t;
   }
}
//+------------------------------------------------------------------+
// H3: sweep of prior 15-minute high/low, reclaim within 15s,
// then micro break. This is a first-pass operational definition.
void DetectH3(TickRec &r)
{
   if(!InpEnableH3 || r.time_msc-last_h3_sec<1000) return;
   long t=r.time_msc;
   double hi=RangeHigh(t-InpH3LookbackSeconds*1000,t-10000);
   double lo=RangeLow(t-InpH3LookbackSeconds*1000,t-10000);
   if(hi<=0 || lo<=0) return;
   double medsp=MedianSpread(t-60000,t-1000);
   double vol=RealizedVolPts(t-60000,t-1000);
   if(medsp<=0 || vol<=0) return;
   double penetration=MathMax(0.20*r.spread_pts,0.0);
   double maxPen=1.5*vol;
   double qrate=QuoteRate(t-5000,t);
   double path=PathAbsMove(t-3000,t);
   double net=MathAbs(r.mid-MidAtOrBefore(t-3000));
   double eff=(path>0 ? net/path : 0);
   // A reclaim is recognized only if the recent path crossed beyond level and returned.
   double recentHi=RangeHigh(t-InpH3MaxSweepSeconds*1000,t);
   double recentLo=RangeLow(t-InpH3MaxSweepSeconds*1000,t);
   if(recentHi>hi+penetration*point_size && recentHi-hi<=maxPen*point_size &&
      r.mid<hi-0.15*r.spread_pts*point_size && eff<0.90)
   {
      double microLow=RangeLow(t-3000,t);
      EmitSignal("H3_SWEEP",-1,r,(recentHi-hi)/point_size,0,eff,vol,qrate,recentHi+r.spread_pts*point_size);
      last_h3_sec=t;
   }
   else if(recentLo<lo-penetration*point_size && lo-recentLo<=maxPen*point_size &&
      r.mid>lo+0.15*r.spread_pts*point_size && eff<0.90)
   {
      double microHigh=RangeHigh(t-3000,t);
      EmitSignal("H3_SWEEP",1,r,(lo-recentLo)/point_size,0,eff,vol,qrate,recentLo-r.spread_pts*point_size);
      last_h3_sec=t;
   }
}
//+------------------------------------------------------------------+
void DetectRandom(TickRec &r)
{
   if(!InpEnableRandomBaseline || InpRandomEverySeconds<=0) return;
   long sec=r.time_msc/1000;
   if(last_random_sec<0) { last_random_sec=sec; return; }
   if(sec-last_random_sec<InpRandomEverySeconds) return;
   // Deterministic alternating direction baseline; not a true randomized control.
   int dir=((sec/InpRandomEverySeconds)%2==0 ? 1 : -1);
   double vol=RealizedVolPts(r.time_msc-60000,r.time_msc-1000);
   double qr=QuoteRate(r.time_msc-5000,r.time_msc);
   double sl=(dir>0 ? r.ask-50*point_size : r.bid+50*point_size);
   EmitSignal("RND_BASE",dir,r,0,0,0,vol,qr,sl);
   last_random_sec=sec;
}
//+------------------------------------------------------------------+
