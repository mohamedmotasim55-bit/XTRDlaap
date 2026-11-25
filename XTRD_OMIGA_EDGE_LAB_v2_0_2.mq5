//+------------------------------------------------------------------+
//| XTRD_OMIGA_EDGE_LAB_v2_0_2.mq5                                   |
//| Research-only collector. NEVER sends trade orders.               |
//|                                                                  |
//| v2.0.2 is an engineering correction of v2.0.1. Every feature     |
//| formula is documented in V2_0_2_FEATURE_DEFINITIONS.md.          |
//| No trading function is referenced anywhere in this file.         |
//+------------------------------------------------------------------+
#property strict
#property version   "2.02"
#property description "XTRD OMIGA EDGE LAB v2.0.2 - research-only signal collector with causal features"

#define FEATURE_VERSION   "2.0.2"
#define COLLECTOR_VERSION "2.0.2"
#define DIAG_MAX          96

//====================== INPUTS ======================================
input string InpSymbol               = "";        // Empty = chart symbol
input int    InpMaxTicksInMemory     = 200000;    // Soft RAM cap (never trims inside the required lookback)
input int    InpFlushEveryTicks      = 5000;      // Batch flush interval (never per row)
input int    InpMinSpreadPoints      = 1;
input int    InpMaxSpreadPoints      = 500;
input bool   InpEnableH1             = true;
input bool   InpEnableH2             = true;
input bool   InpEnableH3             = true;
input bool   InpEnableRandomBaseline = true;
input int    InpRandomEverySeconds   = 60;
input uint   InpRandomSeed           = 20261125;  // Reproducible control sample
input bool   InpWriteRawTicks        = true;      // Raw tick archive (one row per tick)
input int    InpDiagDumpSeconds      = 300;       // Diagnostics flush interval

// H1
input double InpH1MinImpulseSec      = 5.0;
input double InpH1MaxImpulseSec      = 20.0;
input double InpH1DispSpreadMult     = 2.0;       // displacement >= max(mult*spread, sigmaMult*sigma60)
input double InpH1DispSigmaMult      = 1.8;
input double InpH1MinEfficiency      = 0.60;
input double InpH1PullbackMin        = 0.25;
input double InpH1PullbackMax        = 0.55;
input double InpH1MaxPullbackSec     = 45.0;
input double InpH1SpreadMult         = 1.2;       // spread <= mult * median spread60
input double InpH1StopSigmaMargin    = 0.25;

// H2
input int    InpH2BoxSeconds         = 300;
input double InpH2VolPctMax          = 25.0;      // sigma300 percentile must be <= 25
input double InpH2BreakoutSpreadFrac = 0.35;
input double InpH2QuoteRateMult      = 2.0;
input double InpH2MinEfficiency      = 0.70;

// H3
input int    InpH3LookbackSeconds    = 900;
input int    InpH3ExcludeLastSec     = 10;
input double InpH3MaxSweepSeconds    = 15.0;
input double InpH3MinPenetrationSpreadFrac = 0.20;
input double InpH3MaxPenetrationSigmaMult  = 1.5;
input double InpH3MaxStallEfficiency = 0.30;
input double InpH3MinStallScore      = 0.50;
input double InpH3ReclaimSpreadFrac  = 0.15;
input double InpH3StopSpreadMult     = 1.0;

// Reference sampling
input int    InpRefSampleSeconds     = 60;        // push one sigma300 sample per minute
input int    InpRefCapacity          = 60;        // 60 samples == 60 minutes
input int    InpRefMinSamples        = 20;        // below this -> INSUFFICIENT_HISTORY

//====================== TYPES =======================================
struct TickRec
{
   ulong  seq;
   long   t;          // time_msc
   double bid;
   double ask;
   double mid;
   double spread;     // points
};

//====================== GLOBALS =====================================
TickRec g_ticks[];
int     g_n        = 0;       // number of stored ticks
int     g_head     = 0;       // first live index (0 unless trimmed)
int     g_cap      = 200000;  // soft cap

ulong   g_next_seq   = 1;
long    g_last_t     = -1;    // last appended timestamp (ordering guard)

int     g_fh_ticks   = INVALID_HANDLE;
int     g_fh_sig     = INVALID_HANDLE;
int     g_fh_rnd     = INVALID_HANDLE;
int     g_fh_diag    = INVALID_HANDLE;

string  g_sym         = "";
double  g_point       = 0.0;
double  g_tick_size   = 0.0;
int     g_digits      = 0;
long    g_utc_offset  = 0;

// counters
long    g_ticks_received   = 0;
long    g_ticks_written    = 0;
long    g_ticks_rejected   = 0;   // bad quote (bid/ask)
long    g_ticks_out_order  = 0;   // time_msc went backwards (logged, not used for features)
long    g_ticks_trimmed    = 0;
long    g_ticks_dup_ts     = 0;   // equal time_msc (kept, ordered by seq)
long    g_signals_emitted  = 0;
long    g_signals_dropped  = 0;   // structural stop not computable
long    g_flush_counter    = 0;

// throttles
long    g_last_h1_ms = 0;
long    g_last_h2_ms = 0;
long    g_last_h3_ms = 0;
long    g_last_rnd_ms = 0;

// reference cache (recomputed every InpRefSampleSeconds, causal)
double  g_sigma60      = 0.0;
double  g_sigma300     = 0.0;
double  g_medspread60  = 0.0;
double  g_quote_rate60 = 0.0;
long    g_ref_last_ms  = 0;
long    g_ref_samples  = 0;
double  g_ref_vol[];        // ring of sigma300 samples
int     g_ref_head = 0;
int     g_ref_n    = 0;

// diagnostics
string  g_diag_name[DIAG_MAX];
long    g_diag_eval[DIAG_MAX];
long    g_diag_pass[DIAG_MAX];
int     g_diag_count = 0;
long    g_diag_last_ms = 0;

int D_H1_HIST, D_H1_WIN, D_H1_IMP, D_H1_DISP, D_H1_EFF, D_H1_PB, D_H1_PBDUR,
    D_H1_VOLDEC, D_H1_TRIG, D_H1_SPREAD, D_H1_EMIT;
int D_H2_HIST, D_H2_PCTL, D_H2_BOX, D_H2_BREAK, D_H2_RATE, D_H2_EFF, D_H2_EMIT;
int D_H3_HIST, D_H3_SWEEP, D_H3_PEN, D_H3_STALL, D_H3_EFF, D_H3_RECLAIM, D_H3_BOS, D_H3_EMIT;
int D_RND_EMIT;

//====================== SMALL HELPERS ===============================
double Pts(const double price_delta)
{
   return (g_point>0.0 ? price_delta/g_point : 0.0);
}

string F2(const double v) { return DoubleToString(v,2); }
string F3(const double v) { return DoubleToString(v,3); }
string F4(const double v) { return DoubleToString(v,4); }

int DiagSlot(const string name)
{
   for(int i=0;i<g_diag_count;i++)
      if(g_diag_name[i]==name) return i;
   if(g_diag_count>=DIAG_MAX) return -1;
   g_diag_name[g_diag_count]=name;
   g_diag_eval[g_diag_count]=0;
   g_diag_pass[g_diag_count]=0;
   return g_diag_count++;
}

void Diag(const int slot,const bool ok)
{
   if(slot<0) return;
   g_diag_eval[slot]++;
   if(ok) g_diag_pass[slot]++;
}

//====================== INDEX LOOKUP (binary search) ================
// g_ticks[g_head..g_n-1] is strictly non-decreasing in t.
int IdxLE(const long target)      // last index with t <= target, else -1
{
   int lo=g_head, hi=g_n-1, res=-1;
   while(lo<=hi)
   {
      int mid=(lo+hi)/2;
      if(g_ticks[mid].t<=target) { res=mid; lo=mid+1; }
      else                        { hi=mid-1; }
   }
   return res;
}

int IdxGE(const long target)      // first index with t >= target, else -1
{
   int lo=g_head, hi=g_n-1, res=-1;
   while(lo<=hi)
   {
      int mid=(lo+hi)/2;
      if(g_ticks[mid].t>=target) { res=mid; hi=mid-1; }
      else                        { lo=mid+1; }
   }
   return res;
}

//====================== WINDOW STATISTICS ===========================
double WndHigh(const int i0,const int i1)
{
   if(i0<0 || i1<0 || i1<i0 || i1>=g_n) return 0.0;
   double v=-DBL_MAX;
   for(int i=i0;i<=i1;i++) v=MathMax(v,g_ticks[i].mid);
   return (v==-DBL_MAX ? 0.0 : v);
}

double WndLow(const int i0,const int i1)
{
   if(i0<0 || i1<0 || i1<i0 || i1>=g_n) return 0.0;
   double v=DBL_MAX;
   for(int i=i0;i<=i1;i++) v=MathMin(v,g_ticks[i].mid);
   return (v==DBL_MAX ? 0.0 : v);
}

int WndArgHigh(const int i0,const int i1)
{
   if(i0<0 || i1<0 || i1<i0 || i1>=g_n) return -1;
   double v=-DBL_MAX; int k=-1;
   for(int i=i0;i<=i1;i++) if(g_ticks[i].mid>v) { v=g_ticks[i].mid; k=i; }
   return k;
}

int WndArgLow(const int i0,const int i1)
{
   if(i0<0 || i1<0 || i1<i0 || i1>=g_n) return -1;
   double v=DBL_MAX; int k=-1;
   for(int i=i0;i<=i1;i++) if(g_ticks[i].mid<v) { v=g_ticks[i].mid; k=i; }
   return k;
}

double WndPathPts(const int i0,const int i1)     // sum of |tick-to-tick mid changes| in points
{
   if(i0<0 || i1<0 || i1<=i0 || i1>=g_n) return 0.0;
   double sum=0.0;
   for(int i=i0+1;i<=i1;i++) sum+=MathAbs(g_ticks[i].mid-g_ticks[i-1].mid);
   return Pts(sum);
}

double WndSigmaPts(const int i0,const int i1)    // stdev of tick-to-tick mid changes in points
{
   if(i0<0 || i1<0 || i1-i0<2 || i1>=g_n) return 0.0;
   double s=0.0,s2=0.0; int c=0;
   for(int i=i0+1;i<=i1;i++)
   {
      double d=Pts(g_ticks[i].mid-g_ticks[i-1].mid);
      s+=d; s2+=d*d; c++;
   }
   if(c<2) return 0.0;
   double m=s/c;
   return MathSqrt(MathMax(0.0,s2/c-m*m));
}

double WndMedianSpread(const int i0,const int i1)
{
   if(i0<0 || i1<0 || i1<i0 || i1>=g_n) return 0.0;
   double a[]; int c=0;
   ArrayResize(a,i1-i0+1);
   for(int i=i0;i<=i1;i++) a[c++]=g_ticks[i].spread;
   if(c==0) return 0.0;
   ArraySort(a);
   if((c%2)==1) return a[c/2];
   return (a[c/2-1]+a[c/2])*0.5;
}

double WndQuoteRate(const int i0,const int i1)    // ticks per second
{
   if(i0<0 || i1<0 || i1<i0 || i1>=g_n) return 0.0;
   double secs=(double)(g_ticks[i1].t-g_ticks[i0].t)/1000.0;
   if(secs<=0.0) return 0.0;
   return (double)(i1-i0+1)/secs;
}

double WndSpreadStd(const int i0,const int i1)
{
   if(i0<0 || i1<0 || i1<=i0 || i1>=g_n) return 0.0;
   double s=0.0,s2=0.0; int c=0;
   for(int i=i0;i<=i1;i++) { s+=g_ticks[i].spread; s2+=g_ticks[i].spread*g_ticks[i].spread; c++; }
   if(c<2) return 0.0;
   double m=s/c;
   return MathSqrt(MathMax(0.0,s2/c-m*m));
}

//====================== REFERENCE CACHE =============================
void RefPush(const double v)
{
   int cap=MathMax(5,InpRefCapacity);
   if(ArraySize(g_ref_vol)!=cap) ArrayResize(g_ref_vol,cap);
   g_ref_vol[g_ref_head]=v;
   g_ref_head=(g_ref_head+1)%cap;
   if(g_ref_n<cap) g_ref_n++;
   g_ref_samples++;
}

double RefPercentile(const double v)   // 0..100, or -1 when history is insufficient
{
   if(g_ref_n<MathMax(5,InpRefMinSamples)) return -1.0;
   int le=0;
   for(int i=0;i<g_ref_n;i++) if(g_ref_vol[i]<=v) le++;
   return 100.0*(double)le/(double)g_ref_n;
}

void UpdateReference(const long t)
{
   if(g_ref_last_ms>0 && t-g_ref_last_ms < (long)MathMax(10,InpRefSampleSeconds)*1000) return;
   int i60  = IdxGE(t-60000);
   int i300 = IdxGE(t-300000);
   int i1   = IdxLE(t-1);
   if(i1<0) return;
   if(i60<0) i60=g_head;
   if(i300<0) i300=g_head;
   g_sigma60      = WndSigmaPts(i60,i1);
   g_medspread60  = WndMedianSpread(i60,i1);
   g_quote_rate60 = WndQuoteRate(i60,i1);
   g_sigma300     = WndSigmaPts(i300,i1);
   if(g_sigma300>0.0) RefPush(g_sigma300);
   g_ref_last_ms=t;
}

//====================== DIAGNOSTICS OUTPUT ==========================
void DumpDiagnostics()
{
   if(g_fh_diag==INVALID_HANDLE) return;
   FileSeek(g_fh_diag,0,SEEK_SET);
   FileWrite(g_fh_diag,"hypothesis","condition_id","condition","evaluated","passed","failed","pass_rate_pct");
   for(int i=0;i<g_diag_count;i++)
   {
      long failed=g_diag_eval[i]-g_diag_pass[i];
      double rate=(g_diag_eval[i]>0 ? 100.0*(double)g_diag_pass[i]/(double)g_diag_eval[i] : 0.0);
      FileWrite(g_fh_diag,StringSubstr(g_diag_name[i],0,2),i,g_diag_name[i],g_diag_eval[i],g_diag_pass[i],failed,F2(rate));
   }
   FileFlush(g_fh_diag);
}

void DumpRunSummary()
{
   if(g_fh_diag==INVALID_HANDLE) return;
   int h=FileOpen("XTRD_"+g_sym+"_Run_Summary.csv",FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(h==INVALID_HANDLE) return;
   FileWrite(h,"metric","value");
   FileWrite(h,"ticks_received",g_ticks_received);
   FileWrite(h,"ticks_written",g_ticks_written);
   FileWrite(h,"ticks_rejected_bad_quote",g_ticks_rejected);
   FileWrite(h,"ticks_out_of_order",g_ticks_out_order);
   FileWrite(h,"ticks_equal_timestamp",g_ticks_dup_ts);
   FileWrite(h,"ticks_trimmed_from_ram",g_ticks_trimmed);
   FileWrite(h,"signals_emitted",g_signals_emitted);
   FileWrite(h,"signals_dropped_no_stop",g_signals_dropped);
   FileWrite(h,"ref_samples",g_ref_n);
   FileWrite(h,"sigma60_last",F4(g_sigma60));
   FileWrite(h,"sigma300_last",F4(g_sigma300));
   FileWrite(h,"median_spread60_last",F2(g_medspread60));
   FileWrite(h,"utc_offset_sec",g_utc_offset);
   FileWrite(h,"feature_version",FEATURE_VERSION);
   FileClose(h);
}

//====================== BUFFER MANAGEMENT ===========================
void TrimIfNeeded(const long t)
{
   if(g_n < g_cap) return;
   // Never drop ticks that a live lookback still needs.
   long need_ms = (long)MathMax(InpH3LookbackSeconds,3600)*1000 + 120000;
   int keep_from=IdxGE(t-need_ms);
   if(keep_from<0) keep_from=g_head;
   int drop=keep_from-g_head;
   if(drop<=0) return;                      // still inside the required window: grow instead of losing data
   for(int i=keep_from;i<g_n;i++) g_ticks[i-drop]=g_ticks[i];
   g_n-=drop;
   g_head=0;
   g_ticks_trimmed+=drop;
}

void AppendTick(const TickRec &r)
{
   TrimIfNeeded(r.t);
   if(g_n>=ArraySize(g_ticks)) ArrayResize(g_ticks,g_n+4096);
   g_ticks[g_n]=r;
   g_n++;
}

//====================== SIGNAL EMIT =================================
// wave_id is intentionally left unset: the causal wave model is not
// validated yet, so no identifier is invented (see feature doc).
void EmitSignal(const string fh_target_kind,const string hyp,const int dir,const TickRec &r,
                const double move_pts,const long move_window_ms,const string move_source,
                const double vel,const double eff,const double vol,const double vol_pct,
                const double qrate,const double sl_price,const string dq)
{
   if(sl_price<=0.0)
   {
      g_signals_dropped++;
      return;
   }
   double sl_pts=(dir>0 ? Pts(r.ask-sl_price) : Pts(sl_price-r.bid));
   int fh=(fh_target_kind=="RND" ? g_fh_rnd : g_fh_sig);
   if(fh==INVALID_HANDLE) return;
   string vel_s=(move_source=="NA" ? "NA" : F3(vel));
   string pct_s=(vol_pct<0.0 ? "INSUFFICIENT_HISTORY" : F2(vol_pct));
   FileWrite(fh,(long)g_signals_emitted+1,"NA",hyp,dir,r.t,(long)r.seq,g_utc_offset,
      DoubleToString(r.bid,g_digits),DoubleToString(r.ask,g_digits),F2(r.spread),
      F2(move_pts),move_window_ms,move_source,vel_s,F4(eff),F3(vol),pct_s,
      (long)g_ref_n,F3(qrate),DoubleToString(sl_price,g_digits),F2(sl_pts),
      (WndSpreadStd(MathMax(g_head,g_n-600),g_n-1)<=0.0 ? 1 : 0),
      COLLECTOR_VERSION,FEATURE_VERSION,dq);
   g_signals_emitted++;
}

//====================== H1 ==========================================
// Momentum continuation after pullback.
void DetectH1(const TickRec &r)
{
   if(!InpEnableH1) return;
   if(g_last_h1_ms>0 && r.t-g_last_h1_ms<1000) return;

   int i60=IdxGE(r.t-60000);
   int i1 =IdxLE(r.t-1);
   Diag(D_H1_HIST,(i60>=0 && i1>=0 && (i1-i60)>10));
   if(i60<0 || i1<0 || (i1-i60)<=10) return;
   Diag(D_H1_WIN,(true));

   int iStart=IdxGE(r.t-(long)(InpH1MaxImpulseSec*1000.0));
   int iEnd  =IdxLE(r.t-3000);
   if(iStart<0) iStart=g_head;
   if(iEnd<=iStart) return;

   int iMax=WndArgHigh(iStart,iEnd);
   int iMin=WndArgLow(iStart,iEnd);
   if(iMax<0 || iMin<0) return;

   bool up=(iMax>iMin);
   int iA=(up ? iMin : iMax);       // impulse origin
   int iB=(up ? iMax : iMin);       // impulse extreme
   double disp=Pts(MathAbs(g_ticks[iB].mid-g_ticks[iA].mid));
   double dur=(double)(g_ticks[iB].t-g_ticks[iA].t)/1000.0;

   bool imp_ok=(dur>=InpH1MinImpulseSec && dur<=InpH1MaxImpulseSec);
   Diag(D_H1_IMP,imp_ok);
   if(!imp_ok) return;

   double need=MathMax(InpH1DispSpreadMult*g_medspread60,InpH1DispSigmaMult*g_sigma60);
   Diag(D_H1_DISP,(disp>=need && disp>0.0));
   if(disp<need || disp<=0.0) return;

   double pathImp=WndPathPts(iA,iB);
   double effImp=(pathImp>0.0 ? disp/pathImp : 0.0);
   Diag(D_H1_EFF,(effImp>=InpH1MinEfficiency));
   if(effImp<InpH1MinEfficiency) return;

   int iPull = (up ? WndArgLow(iB,i1) : WndArgHigh(iB,i1));
   if(iPull<0) return;
   double pb=Pts(MathAbs(g_ticks[iB].mid-g_ticks[iPull].mid));
   double ratio=(disp>0.0 ? pb/disp : 0.0);
   Diag(D_H1_PB,(ratio>=InpH1PullbackMin && ratio<=InpH1PullbackMax));
   if(ratio<InpH1PullbackMin || ratio>InpH1PullbackMax) return;

   double pbDur=(double)(r.t-g_ticks[iB].t)/1000.0;
   Diag(D_H1_PBDUR,(pbDur<=InpH1MaxPullbackSec));
   if(pbDur>InpH1MaxPullbackSec) return;

   double sigImp=WndSigmaPts(iA,iB);
   double sigPb =WndSigmaPts(iB,iPull);
   Diag(D_H1_VOLDEC,(sigPb<sigImp));
   if(sigPb>=sigImp) return;

   int iTrig=IdxGE(r.t-3000);
   if(iTrig<0) iTrig=iPull;
   bool trig=(up ? (r.mid>WndHigh(iTrig,i1)) : (r.mid<WndLow(iTrig,i1)));
   Diag(D_H1_TRIG,trig);
   if(!trig) return;

   Diag(D_H1_SPREAD,(r.spread<=InpH1SpreadMult*g_medspread60));
   if(r.spread>InpH1SpreadMult*g_medspread60) return;

   double sl=(up ? g_ticks[iPull].mid-InpH1StopSigmaMargin*g_sigma60*g_point
                 : g_ticks[iPull].mid+InpH1StopSigmaMargin*g_sigma60*g_point);
   double pct=RefPercentile(g_sigma300);
   string dq="OK";
   if(pct<0.0) dq="REF_INSUFFICIENT";
   long window_ms=(long)((double)(g_ticks[iB].t-g_ticks[iA].t));
   double vel=(window_ms>0 ? disp/((double)window_ms/1000.0) : 0.0);
   Diag(D_H1_EMIT,true);
   EmitSignal("SIG","H1_IMP_PB",(up?1:-1),r,disp,window_ms,"IMPULSE",vel,effImp,sigImp,pct,g_quote_rate60,sl,dq);
   g_last_h1_ms=r.t;
}

//====================== H2 ==========================================
// Volatility compression (sigma300 in the low 25% of the reference) then expansion.
void DetectH2(const TickRec &r)
{
   if(!InpEnableH2) return;
   if(g_last_h2_ms>0 && r.t-g_last_h2_ms<1000) return;

   Diag(D_H2_HIST,(g_ref_n>=MathMax(5,InpRefMinSamples)));
   if(g_ref_n<MathMax(5,InpRefMinSamples)) return;

   double pct=RefPercentile(g_sigma300);
   Diag(D_H2_PCTL,(pct>=0.0 && pct<=InpH2VolPctMax));
   if(pct<0.0 || pct>InpH2VolPctMax) return;

   int iBox=IdxGE(r.t-(long)InpH2BoxSeconds*1000);
   int i1  =IdxLE(r.t-1000);
   Diag(D_H2_BOX,(iBox>=0 && i1>iBox+5));
   if(iBox<0 || i1<=iBox+5) return;

   double hi=WndHigh(iBox,i1), lo=WndLow(iBox,i1);
   if(hi<=0.0 || lo<=0.0 || hi<=lo) return;

   double thrUp=hi+InpH2BreakoutSpreadFrac*r.spread*g_point;
   double thrDn=lo-InpH2BreakoutSpreadFrac*r.spread*g_point;
   bool up=(r.mid>thrUp), dn=(r.mid<thrDn);
   Diag(D_H2_BREAK,(up||dn));
   if(!up && !dn) return;

   int i3=IdxGE(r.t-3000);
   if(i3<0) return;
   double rateNow=WndQuoteRate(i3,g_n-1);
   double rateBox=WndQuoteRate(iBox,i1);
   Diag(D_H2_RATE,(rateBox>0.0 && rateNow>=InpH2QuoteRateMult*rateBox));
   if(rateBox<=0.0 || rateNow<InpH2QuoteRateMult*rateBox) return;

   double path=WndPathPts(i3,g_n-1);
   double net=MathAbs(g_ticks[g_n-1].mid-g_ticks[i3].mid);
   double eff=(path>0.0 ? Pts(net)/path : 0.0);
   Diag(D_H2_EFF,(eff>=InpH2MinEfficiency));
   if(eff<InpH2MinEfficiency) return;

   double boxW=Pts(hi-lo);
   double sl=(boxW<2.0*r.spread ? (up?lo:hi) : (hi+lo)*0.5);
   double move=(up ? Pts(r.mid-hi) : Pts(lo-r.mid));
   long window_ms=(long)(r.t-g_ticks[i3].t);
   double vel=(window_ms>0 ? move/((double)window_ms/1000.0) : 0.0);
   Diag(D_H2_EMIT,true);
   EmitSignal("SIG","H2_VOL_EXP",(up?1:-1),r,move,window_ms,"BREAKOUT",vel,eff,g_sigma300,pct,rateNow,sl,"OK");
   g_last_h2_ms=r.t;
}

//====================== H3 ==========================================
// Failed breakout / liquidity sweep with stall, reclaim and micro-BOS.
void DetectH3(const TickRec &r)
{
   if(!InpEnableH3) return;
   if(g_last_h3_ms>0 && r.t-g_last_h3_ms<1000) return;

   long from=r.t-(long)InpH3LookbackSeconds*1000;
   int iLb=IdxGE(from);
   int iEnd=IdxLE(r.t-(long)InpH3ExcludeLastSec*1000);
   Diag(D_H3_HIST,(iLb>=0 && iEnd>iLb+20));
   if(iLb<0 || iEnd<=iLb+20) return;

   double hi=WndHigh(iLb,iEnd), lo=WndLow(iLb,iEnd);
   if(hi<=0.0 || lo<=0.0 || hi<=lo) return;

   int iSw=IdxGE(r.t-(long)(InpH3MaxSweepSeconds*1000.0));
   if(iSw<0) iSw=iEnd;
   int iSweepHi=WndArgHigh(iSw,g_n-1);
   int iSweepLo=WndArgLow(iSw,g_n-1);
   if(iSweepHi<0 || iSweepLo<0) return;

   double penUp=(iSweepHi>iEnd ? Pts(g_ticks[iSweepHi].mid-hi) : 0.0);
   double penDn=(iSweepLo>iEnd ? Pts(lo-g_ticks[iSweepLo].mid) : 0.0);
   bool swept=(penUp>0.0 || penDn>0.0);
   Diag(D_H3_SWEEP,swept);
   if(!swept) return;

   bool upSweep=(penUp>=penDn);
   int iExt=(upSweep ? iSweepHi : iSweepLo);
   double pen=(upSweep ? penUp : penDn);
   double penMin=InpH3MinPenetrationSpreadFrac*r.spread;
   double penMax=InpH3MaxPenetrationSigmaMult*g_sigma60;
   Diag(D_H3_PEN,(pen>=penMin && pen<=penMax));
   if(pen<penMin || pen>penMax) return;

   double effStall=0.0;
   int iAfter=iExt;
   if(g_n-1>iAfter)
   {
      double path=WndPathPts(iAfter,g_n-1);
      double net=MathAbs(g_ticks[g_n-1].mid-g_ticks[iExt].mid);
      effStall=(path>0.0 ? Pts(net)/path : 0.0);
   }
   double secs=MathMax(0.001,(double)(r.t-g_ticks[iExt].t)/1000.0);
   double rateStall=(double)(g_n-1-iExt)/secs;
   double rateRef=MathMax(0.01,g_quote_rate60);
   double stallScore=0.5*(1.0-MathMin(1.0,effStall/MathMax(0.01,InpH3MaxStallEfficiency)))
                   + 0.5*(1.0-MathMin(1.0,rateStall/rateRef));
   Diag(D_H3_STALL,(stallScore>=InpH3MinStallScore));
   if(stallScore<InpH3MinStallScore) return;

   Diag(D_H3_EFF,(effStall<InpH3MaxStallEfficiency));
   if(effStall>=InpH3MaxStallEfficiency) return;

   bool reclaim=(upSweep ? (r.mid<hi-InpH3ReclaimSpreadFrac*r.spread*g_point)
                         : (r.mid>lo+InpH3ReclaimSpreadFrac*r.spread*g_point));
   Diag(D_H3_RECLAIM,reclaim);
   if(!reclaim) return;

   // Micro break of structure: break the 3s extreme formed after the sweep extreme.
   int iBos=IdxGE(r.t-3000);
   if(iBos<0) iBos=iExt;
   bool bos=(upSweep ? (r.mid<WndLow(iBos,g_n-1)) : (r.mid>WndHigh(iBos,g_n-1)));
   Diag(D_H3_BOS,bos);
   if(!bos) return;

   double sl=(upSweep ? g_ticks[iExt].mid+InpH3StopSpreadMult*r.spread*g_point
                      : g_ticks[iExt].mid-InpH3StopSpreadMult*r.spread*g_point);
   double pct=RefPercentile(g_sigma300);
   string dq="OK";
   if(pct<0.0) dq="REF_INSUFFICIENT";
   long window_ms=(long)(r.t-g_ticks[iExt].t);
   double vel=(window_ms>0 ? pen/((double)window_ms/1000.0) : 0.0);
   Diag(D_H3_EMIT,true);
   EmitSignal("SIG","H3_SWEEP",(upSweep?-1:1),r,pen,window_ms,"SWEEP",vel,effStall,g_sigma60,pct,rateStall,sl,dq);
   g_last_h3_ms=r.t;
}

//====================== RANDOM CONTROL ==============================
void DetectRandom(const TickRec &r)
{
   if(!InpEnableRandomBaseline || InpRandomEverySeconds<=0) return;
   if(g_last_rnd_ms>0 && r.t-g_last_rnd_ms<(long)InpRandomEverySeconds*1000) return;
   if(g_ref_n<MathMax(5,InpRefMinSamples)) return;      // match reference conditions

   int dir=(MathRand()%2==0 ? 1 : -1);
   double sl=(dir>0 ? r.ask-50.0*g_point : r.bid+50.0*g_point);
   double pct=RefPercentile(g_sigma300);
   Diag(D_RND_EMIT,true);
   // Velocity is not applicable to a control sample: written as NA, never as zero.
   EmitSignal("RND","RND_BASE",dir,r,0.0,0,"NA",0.0,0.0,g_sigma60,pct,g_quote_rate60,sl,
              "VELOCITY_NA_CONTROL");
   g_last_rnd_ms=r.t;
}

//====================== LIFECYCLE ===================================
void WriteSignalHeader(const int fh)
{
   FileWrite(fh,"signal_id","wave_id","hypothesis_type","direction","signal_time_msc",
      "trigger_tick_seq","server_utc_offset_sec","entry_bid","entry_ask","entry_spread_pts",
      "raw_move_pts","raw_move_window_ms","raw_move_source","raw_velocity_pts_s",
      "raw_efficiency","raw_realized_vol_pts","raw_vol_percentile","raw_vol_ref_samples",
      "raw_quote_rate_s","structural_sl_price","structural_sl_pts","spread_is_static",
      "collector_version","feature_version","data_quality_flag");
}

int OnInit()
{
   g_sym=(InpSymbol=="" ? _Symbol : InpSymbol);
   if(!SymbolSelect(g_sym,true))
   {
      Print("ERROR: cannot select symbol ",g_sym);
      return INIT_FAILED;
   }
   g_point=SymbolInfoDouble(g_sym,SYMBOL_POINT);
   g_tick_size=SymbolInfoDouble(g_sym,SYMBOL_TRADE_TICK_SIZE);
   g_digits=(int)SymbolInfoInteger(g_sym,SYMBOL_DIGITS);
   if(g_point<=0.0 || g_tick_size<=0.0)
   {
      Print("ERROR: invalid point/tick size");
      return INIT_FAILED;
   }
   g_cap=MathMax(50000,InpMaxTicksInMemory);
   ArrayResize(g_ticks,4096);
   ArrayResize(g_ref_vol,MathMax(5,InpRefCapacity));
   MathSrand(InpRandomSeed);

   g_utc_offset=(long)(TimeTradeServer()-TimeGMT());

   string prefix="XTRD_"+g_sym+"_";
   g_fh_ticks=FileOpen(prefix+"Market_Ticks.csv",FILE_WRITE|FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ,',');
   g_fh_sig  =FileOpen(prefix+"Signal_Snapshot.csv",FILE_WRITE|FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ,',');
   g_fh_rnd  =FileOpen(prefix+"RND_Baseline.csv",FILE_WRITE|FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ,',');
   g_fh_diag =FileOpen(prefix+"Signal_Diagnostics.csv",FILE_WRITE|FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ,',');
   if(g_fh_ticks==INVALID_HANDLE || g_fh_sig==INVALID_HANDLE || g_fh_rnd==INVALID_HANDLE || g_fh_diag==INVALID_HANDLE)
   {
      Print("ERROR opening CSV files. code=",GetLastError());
      return INIT_FAILED;
   }

   if(FileSize(g_fh_ticks)==0)
      FileWrite(g_fh_ticks,"tick_seq","tick_time_msc","bid","ask","mid","spread_pts","flags");

   if(FileSize(g_fh_sig)==0) WriteSignalHeader(g_fh_sig);
   if(FileSize(g_fh_rnd)==0) WriteSignalHeader(g_fh_rnd);

   FileSeek(g_fh_ticks,0,SEEK_END);
   FileSeek(g_fh_sig,0,SEEK_END);
   FileSeek(g_fh_rnd,0,SEEK_END);

   D_H1_HIST=DiagSlot("H1_01_history");
   D_H1_WIN =DiagSlot("H1_02_window_ready");
   D_H1_IMP =DiagSlot("H1_03_impulse_shape");
   D_H1_DISP=DiagSlot("H1_04_displacement");
   D_H1_EFF =DiagSlot("H1_05_efficiency");
   D_H1_PB  =DiagSlot("H1_06_pullback_ratio");
   D_H1_PBDUR=DiagSlot("H1_07_pullback_duration");
   D_H1_VOLDEC=DiagSlot("H1_08_vol_decay");
   D_H1_TRIG=DiagSlot("H1_09_trigger");
   D_H1_SPREAD=DiagSlot("H1_10_spread_gate");
   D_H1_EMIT=DiagSlot("H1_11_emitted");
   D_H2_HIST=DiagSlot("H2_01_history");
   D_H2_PCTL=DiagSlot("H2_02_compression_percentile");
   D_H2_BOX =DiagSlot("H2_03_box_valid");
   D_H2_BREAK=DiagSlot("H2_04_breakout");
   D_H2_RATE=DiagSlot("H2_05_quote_rate_expansion");
   D_H2_EFF =DiagSlot("H2_06_efficiency");
   D_H2_EMIT=DiagSlot("H2_07_emitted");
   D_H3_HIST=DiagSlot("H3_01_history");
   D_H3_SWEEP=DiagSlot("H3_02_sweep_present");
   D_H3_PEN =DiagSlot("H3_03_penetration_bounds");
   D_H3_STALL=DiagSlot("H3_04_stall_score");
   D_H3_EFF =DiagSlot("H3_05_stall_efficiency");
   D_H3_RECLAIM=DiagSlot("H3_06_reclaim");
   D_H3_BOS =DiagSlot("H3_07_micro_bos");
   D_H3_EMIT=DiagSlot("H3_08_emitted");
   D_RND_EMIT=DiagSlot("RND_01_emitted");

   DumpDiagnostics();

   Print("XTRD EDGE LAB v",COLLECTOR_VERSION," started on ",g_sym,
         " point=",DoubleToString(g_point,g_digits),
         " tick_size=",DoubleToString(g_tick_size,g_digits),
         " utc_offset=",g_utc_offset,
         " seed=",InpRandomSeed,
         ". RESEARCH ONLY: no trade request is issued by this program.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_fh_ticks!=INVALID_HANDLE) FileFlush(g_fh_ticks);
   if(g_fh_sig!=INVALID_HANDLE)   FileFlush(g_fh_sig);
   if(g_fh_rnd!=INVALID_HANDLE)   FileFlush(g_fh_rnd);
   DumpDiagnostics();
   DumpRunSummary();
   if(g_fh_ticks!=INVALID_HANDLE) FileClose(g_fh_ticks);
   if(g_fh_sig!=INVALID_HANDLE)   FileClose(g_fh_sig);
   if(g_fh_rnd!=INVALID_HANDLE)   FileClose(g_fh_rnd);
   if(g_fh_diag!=INVALID_HANDLE)  FileClose(g_fh_diag);
   g_fh_ticks=INVALID_HANDLE; g_fh_sig=INVALID_HANDLE; g_fh_rnd=INVALID_HANDLE; g_fh_diag=INVALID_HANDLE;
   Print("XTRD EDGE LAB v",COLLECTOR_VERSION," stopped. reason=",reason,
         " received=",g_ticks_received," written=",g_ticks_written,
         " out_of_order=",g_ticks_out_order," trimmed=",g_ticks_trimmed,
         " signals=",g_signals_emitted," dropped=",g_signals_dropped);
}

void OnTick()
{
   MqlTick q;
   if(!SymbolInfoTick(g_sym,q)) return;
   if(q.bid<=0.0 || q.ask<=0.0 || q.ask<q.bid)
   {
      g_ticks_rejected++;
      return;
   }
   long tm=(long)q.time_msc;
   if(tm<=0) { g_ticks_rejected++; return; }

   g_ticks_received++;

   TickRec r;
   r.seq=g_next_seq++;
   r.t=tm;
   r.bid=q.bid;
   r.ask=q.ask;
   r.mid=(q.bid+q.ask)*0.5;
   r.spread=Pts(q.ask-q.bid);

   if(InpWriteRawTicks && g_fh_ticks!=INVALID_HANDLE)
   {
      FileWrite(g_fh_ticks,(long)r.seq,r.t,
                DoubleToString(r.bid,g_digits),DoubleToString(r.ask,g_digits),
                DoubleToString(r.mid,g_digits),F2(r.spread),(uint)q.flags);
      g_ticks_written++;
      g_flush_counter++;
      if(g_flush_counter>=MathMax(100,InpFlushEveryTicks))
      {
         FileFlush(g_fh_ticks);
         g_flush_counter=0;
      }
   }

   if(g_last_t>=0 && tm<g_last_t)
   {
      g_ticks_out_order++;
      return;                       // logged above, excluded from features
   }
   if(g_last_t==tm) g_ticks_dup_ts++;
   g_last_t=tm;

   AppendTick(r);
   UpdateReference(r.t);

   if(r.spread<InpMinSpreadPoints || r.spread>InpMaxSpreadPoints) return;

   DetectH1(r);
   DetectH2(r);
   DetectH3(r);
   DetectRandom(r);

   if(g_diag_last_ms==0 || r.t-g_diag_last_ms>=(long)MathMax(30,InpDiagDumpSeconds)*1000)
   {
      DumpDiagnostics();
      if(g_fh_sig!=INVALID_HANDLE)   FileFlush(g_fh_sig);
      if(g_fh_rnd!=INVALID_HANDLE)   FileFlush(g_fh_rnd);
      g_diag_last_ms=r.t;
   }
}
//+------------------------------------------------------------------+
