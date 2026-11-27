//+------------------------------------------------------------------+
//| XTRD_M1_TICK_HUNTER.mq5                                          |
//| Tick-native M1 momentum + wick formation research/scalping engine |
//| Version 0.10                                                     |
//| IMPORTANT: Live trading is disabled by default.                  |
//+------------------------------------------------------------------+
#property strict
#property version   "0.10"
#property description "Real-time tick velocity, acceleration, forming-candle wick analysis, optional DOM and adaptive trailing."

#include <Trade/Trade.mqh>

//--- Entry execution mode
enum ENUM_XTRD_ENTRY_MODE
  {
   XTRD_SIGNAL_ONLY=0,       // Signals + CSV only
   XTRD_MARKET_ENTRY=1,      // Market execution (requires EnableLiveTrading=true)
   XTRD_LIMIT_PULLBACK=2     // Pullback limit execution (requires EnableLiveTrading=true)
  };

//--- Signal family
enum ENUM_XTRD_SIGNAL_FAMILY
  {
   XTRD_WICK_REJECTION=0,    // Wick rejection + immediate reversal momentum
   XTRD_MOMENTUM_PULLBACK=1, // Momentum continuation after a micro pullback
   XTRD_HYBRID=2             // Both families, strongest score wins
  };

//--- Inputs: identity and safety
input string                   InpTradeSymbol="";               // Empty = chart symbol
input long                     InpMagic=27112701;
input bool                     InpEnableLiveTrading=false;       // SAFETY: OFF by default
input ENUM_XTRD_ENTRY_MODE     InpEntryMode=XTRD_SIGNAL_ONLY;
input ENUM_XTRD_SIGNAL_FAMILY  InpSignalFamily=XTRD_HYBRID;
input double                   InpFixedVolume=0.01;
input int                      InpMaxOpenPositions=1;
input int                      InpMaxEntriesPerMinute=12;
input double                   InpMaxRiskPercent=10.0;            // Estimated initial SL risk cap
input double                   InpMaxSpreadPoints=38.0;
input int                      InpMaxDeviationPoints=20;
input int                      InpSignalCooldownMs=650;
input int                      InpMaxSignalLatencyMs=150;
input double                   InpSlippagePerSidePoints=2.0;
input int                      InpLimitOffsetPoints=8;
input int                      InpLimitExpirySeconds=5;

//--- Inputs: tick windows and microstructure
input int                      InpFastWindowMs=250;
input int                      InpMediumWindowMs=750;
input int                      InpSlowWindowMs=2000;
input double                   InpMinFastVelocityPtsSec=7.0;
input double                   InpMinSlowVelocityPtsSec=2.5;
input double                   InpMinAccelerationPtsSec=1.0;
input double                   InpMinWickPoints=10.0;
input double                   InpWickVsSpreadFactor=0.55;
input double                   InpMinWickRangeShare=0.22;
input double                   InpBuyCloseLocation=0.58;
input double                   InpSellCloseLocation=0.42;
input double                   InpMinRecoveryVelocityPtsSec=5.0;
input double                   InpMinExpectedMoveSpreadFactor=0.45;
input double                   InpExpectedMoveHorizonSeconds=3.0;
input int                      InpMinFastWindowTicks=3;
input double                   InpMinTickEfficiency=0.22;
input int                      InpSignalScoreThreshold=7;
input bool                     InpUseMarketBook=true;
input int                      InpDOMLevelsToRead=5;
input double                   InpDOMImbalanceThreshold=0.12;

//--- Inputs: protective execution
input double                   InpStopBufferPoints=5.0;
input double                   InpMaxInitialStopPoints=180.0;
input double                   InpTrailStartPoints=42.0;
input double                   InpTrailStartSpreadFactor=1.45;
input double                   InpMinTrailDistancePoints=16.0;
input double                   InpTrailSpreadFactor=0.70;
input double                   InpTrailATRFactor=0.08;
input double                   InpMaxTrailDistancePoints=70.0;
input double                   InpTrailStepPoints=3.0;
input bool                     InpExitOnMomentumFlip=false;
input double                   InpMomentumFlipExitPoints=12.0;

//--- Inputs: logging and UI
input bool                     InpWriteCSV=true;
input bool                     InpShowDashboard=true;
input bool                     InpPrintEverySignal=true;
input int                      InpTimerMilliseconds=100;

#define XTRD_RING_SIZE 4096
#define XTRD_BATCH_SIZE 4096
#define XTRD_DUP_SIZE  1024
#define XTRD_CSV_NAME  "XTRD_M1_TICK_HUNTER_signals.csv"

struct XTRDTickSample
  {
   long   time_msc;
   double bid;
   double ask;
   double last;
   double volume_real;
   double mid;
   double spread_pts;
   uint   flags;
  };

struct XTRDMetrics
  {
   double net_pts;
   double velocity_pts_sec;
   double efficiency;
   double buy_ratio;
   int    up_ticks;
   int    down_ticks;
   int    buy_aggressor_ticks;
   int    sell_aggressor_ticks;
   double aggressor_buy_ratio;
   int    samples;
   double abs_path_pts;
  };

CTrade g_trade;
string g_symbol="";
double g_point=0.0;
int    g_digits=0;
int    g_atr_handle=INVALID_HANDLE;

XTRDTickSample g_ring[XTRD_RING_SIZE];
int    g_ring_head=0;
int    g_ring_count=0;
long   g_last_processed_msc=0;

// Recent tick fingerprints avoid processing the same CopyTicks overlap twice.
XTRDTickSample g_seen[XTRD_DUP_SIZE];
MqlTick g_tick_batch[XTRD_BATCH_SIZE];
int g_seen_head=0;
int g_seen_count=0;

// Forming M1 candle (Bid chart convention).
datetime g_bar_time=0;
double g_candle_open=0.0;
double g_candle_high=0.0;
double g_candle_low=0.0;
long   g_candle_low_time_msc=0;
long   g_candle_high_time_msc=0;

// Optional DOM snapshot.
bool   g_dom_subscribed=false;
bool   g_dom_valid=false;
bool   g_dom_for_signal=false;
ulong  g_dom_update_local_ms=0;
double g_dom_imbalance=0.0;
int    g_dom_levels=0;

// Last calculated state.
double g_last_spread=0.0;
double g_last_fast_velocity=0.0;
double g_last_medium_velocity=0.0;
double g_last_slow_velocity=0.0;
double g_last_acceleration=0.0;
int    g_last_buy_score=0;
int    g_last_sell_score=0;
string g_last_signal="NONE";
string g_last_block_reason="";
long   g_last_signal_msc=0;
long   g_last_order_msc=0;
datetime g_entries_bar=0;
int    g_entries_this_minute=0;
long   g_last_trail_update_msc=0;
ulong  g_last_cancel_attempt_local_ms=0;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double MaxD(const double a,const double b) { return (a>b ? a : b); }
double MinD(const double a,const double b) { return (a<b ? a : b); }

double NormalizePrice(const double price)
  {
   double tick_size=SymbolInfoDouble(g_symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tick_size<=0.0) tick_size=g_point;
   double p=MathRound(price/tick_size)*tick_size;
   return NormalizeDouble(p,g_digits);
  }

bool IsSameFingerprint(const XTRDTickSample &a,const XTRDTickSample &b)
  {
   if(a.time_msc!=b.time_msc) return false;
   if(a.bid!=b.bid || a.ask!=b.ask || a.last!=b.last || a.volume_real!=b.volume_real || a.flags!=b.flags) return false;
   return true;
  }

bool AlreadySeen(const MqlTick &t)
  {
   XTRDTickSample probe;
   probe.time_msc=t.time_msc;
   probe.bid=t.bid;
   probe.ask=t.ask;
   probe.last=t.last;
   probe.volume_real=t.volume_real;
   probe.flags=t.flags;
   for(int i=0;i<g_seen_count;i++)
     {
      int idx=(g_seen_head-1-i+XTRD_DUP_SIZE)%XTRD_DUP_SIZE;
      if(IsSameFingerprint(g_seen[idx],probe)) return true;
     }
   return false;
  }

void RememberSeen(const XTRDTickSample &s)
  {
   g_seen[g_seen_head]=s;
   g_seen_head=(g_seen_head+1)%XTRD_DUP_SIZE;
   if(g_seen_count<XTRD_DUP_SIZE) g_seen_count++;
  }

void PushTick(const MqlTick &t)
  {
   XTRDTickSample s;
   s.time_msc=t.time_msc;
   s.bid=t.bid;
   s.ask=t.ask;
   s.last=t.last;
   s.volume_real=t.volume_real;
   s.mid=(t.bid+t.ask)*0.5;
   s.spread_pts=(t.ask-t.bid)/g_point;
   s.flags=t.flags;

   g_ring[g_ring_head]=s;
   g_ring_head=(g_ring_head+1)%XTRD_RING_SIZE;
   if(g_ring_count<XTRD_RING_SIZE) g_ring_count++;
   RememberSeen(s);

   UpdateFormingCandle(t);
   g_last_spread=s.spread_pts;
   if(t.time_msc>g_last_processed_msc) g_last_processed_msc=t.time_msc;
  }

void UpdateFormingCandle(const MqlTick &t)
  {
   datetime bar=(datetime)(t.time_msc/1000);
   bar=(datetime)((long)bar-((long)bar%60));

   if(g_bar_time==0 || bar!=g_bar_time)
     {
      g_bar_time=bar;
      // For any newly encountered bar, the first tick in chronological order
      // becomes its open/high/low seed. Do not read shift-0 OHLC here: during
      // CopyTicks catch-up it may already contain later ticks from that bar.
      g_candle_open=t.bid;
      g_candle_high=t.bid;
      g_candle_low=t.bid;
      g_candle_low_time_msc=t.time_msc;
      g_candle_high_time_msc=t.time_msc;
      g_entries_this_minute=0;
      g_entries_bar=bar;
     }

   if(t.bid>g_candle_high)
     {
      g_candle_high=t.bid;
      g_candle_high_time_msc=t.time_msc;
     }
   if(t.bid<g_candle_low)
     {
      g_candle_low=t.bid;
      g_candle_low_time_msc=t.time_msc;
     }
  }

//+------------------------------------------------------------------+
//| Pull all available ticks since the last processed millisecond.   |
//| CopyTicks returns oldest-to-newest; overlap is deduplicated.      |
//+------------------------------------------------------------------+
void CaptureTicks()
  {
   ulong from_msc=(g_last_processed_msc>0 ? (ulong)g_last_processed_msc : 0);
   uint wanted=(g_last_processed_msc>0 ? XTRD_BATCH_SIZE : 1);
   int copied=CopyTicks(g_symbol,g_tick_batch,COPY_TICKS_ALL,from_msc,wanted);
   if(copied<0)
     {
      int err=GetLastError();
      if(err!=0) g_last_block_reason="CopyTicks error "+IntegerToString(err);
      return;
     }
   if(copied<=0) return;

   for(int i=0;i<copied;i++)
     {
      if(g_tick_batch[i].bid<=0.0 || g_tick_batch[i].ask<=0.0 || g_tick_batch[i].ask<g_tick_batch[i].bid) continue;
      if(g_last_processed_msc>0 && g_tick_batch[i].time_msc<g_last_processed_msc) continue;
      if(AlreadySeen(g_tick_batch[i])) continue;
      PushTick(g_tick_batch[i]);
      EvaluateOnNewTick(g_tick_batch[i]);
     }
  }

//+------------------------------------------------------------------+
//| Window metrics from the rolling tick ring.                        |
//+------------------------------------------------------------------+
void CalcWindow(const long now_msc,const int window_ms,XTRDMetrics &m)
  {
   m.net_pts=0.0;
   m.velocity_pts_sec=0.0;
   m.efficiency=0.0;
   m.buy_ratio=0.5;
   m.up_ticks=0;
   m.down_ticks=0;
   m.buy_aggressor_ticks=0;
   m.sell_aggressor_ticks=0;
   m.aggressor_buy_ratio=0.5;
   m.samples=0;
   m.abs_path_pts=0.0;
   if(g_ring_count<2 || window_ms<=0) return;

   bool have_newest=false;
   double newest_mid=0.0;
   double older_mid=0.0;
   double newer_mid=0.0;
   long newest_time=0;
   long oldest_time=0;

   // Walk backward from the newest tick and stop immediately outside the window.
   // This keeps the hot path proportional to recent tick activity, not full ring size.
   for(int n=0;n<g_ring_count;n++)
     {
      int idx=(g_ring_head-1-n+XTRD_RING_SIZE)%XTRD_RING_SIZE;
      XTRDTickSample s=g_ring[idx];
      if(now_msc-s.time_msc>window_ms) break;
      if((s.flags&TICK_FLAG_BUY)!=0) m.buy_aggressor_ticks++;
      if((s.flags&TICK_FLAG_SELL)!=0) m.sell_aggressor_ticks++;
      if(!have_newest)
        {
         newest_mid=s.mid;
         newer_mid=s.mid;
         newest_time=s.time_msc;
         oldest_time=s.time_msc;
         older_mid=s.mid;
         m.samples=1;
         have_newest=true;
         continue;
        }

      // s is older than newer_mid. Positive delta means the market ticked upward.
      double delta=(newer_mid-s.mid)/g_point;
      if(delta>0.0) m.up_ticks++;
      else if(delta<0.0) m.down_ticks++;
      m.abs_path_pts+=MathAbs(delta);
      older_mid=s.mid;
      oldest_time=s.time_msc;
      newer_mid=s.mid;
      m.samples++;
     }

   if(!have_newest || m.samples<2) return;
   m.net_pts=(newest_mid-older_mid)/g_point;
   long dt=newest_time-oldest_time;
   if(dt>0) m.velocity_pts_sec=m.net_pts*1000.0/(double)dt;
   if(m.abs_path_pts>0.0) m.efficiency=MathAbs(m.net_pts)/m.abs_path_pts;
   int directional=m.up_ticks+m.down_ticks;
   if(directional>0) m.buy_ratio=(double)m.up_ticks/(double)directional;
   int aggressor_total=m.buy_aggressor_ticks+m.sell_aggressor_ticks;
   if(aggressor_total>0) m.aggressor_buy_ratio=(double)m.buy_aggressor_ticks/(double)aggressor_total;
  }

void GetAllMetrics(const long now_msc,XTRDMetrics &fast,XTRDMetrics &medium,XTRDMetrics &slow,double &accel)
  {
   CalcWindow(now_msc,InpFastWindowMs,fast);
   CalcWindow(now_msc,InpMediumWindowMs,medium);
   CalcWindow(now_msc,InpSlowWindowMs,slow);
   accel=fast.velocity_pts_sec-medium.velocity_pts_sec;
  }

//+------------------------------------------------------------------+
//| Optional market depth snapshot.                                   |
//+------------------------------------------------------------------+
void RefreshDOM()
  {
   g_dom_valid=false;
   g_dom_update_local_ms=0;
   g_dom_imbalance=0.0;
   g_dom_levels=0;
   if(!InpUseMarketBook || !g_dom_subscribed) return;

   MqlBookInfo book[];
   if(!MarketBookGet(g_symbol,book)) return;
   double bid_vol=0.0,ask_vol=0.0;
   int bid_levels=0,ask_levels=0;
   for(int i=0;i<ArraySize(book);i++)
     {
      double v=book[i].volume_real;
      if(v<=0.0) v=(double)book[i].volume;
      if(v<=0.0) continue;
      if(book[i].type==BOOK_TYPE_BUY && bid_levels<InpDOMLevelsToRead)
        {
         bid_vol+=v;
         bid_levels++;
        }
      else if(book[i].type==BOOK_TYPE_SELL && ask_levels<InpDOMLevelsToRead)
        {
         ask_vol+=v;
         ask_levels++;
        }
     }
   g_dom_levels=(int)MinD((double)bid_levels,(double)ask_levels);
   double total=bid_vol+ask_vol;
   if(total>0.0 && g_dom_levels>0)
     {
      g_dom_imbalance=(bid_vol-ask_vol)/total;
      g_dom_valid=true;
      g_dom_update_local_ms=GetTickCount64();
     }
  }

//+------------------------------------------------------------------+
//| Signal score                                                      |
//+------------------------------------------------------------------+
int ScoreWickBuy(const double range_pts,const double lower_pts,const double upper_pts,
                 const double close_location,const double recovery_velocity,
                 const XTRDMetrics &fast,const XTRDMetrics &medium,const double accel)
  {
   int score=0;
   double min_wick=MaxD(InpMinWickPoints,g_last_spread*InpWickVsSpreadFactor);
   if(lower_pts>=min_wick && range_pts>0.0 && lower_pts/range_pts>=InpMinWickRangeShare) score+=2;
   if(close_location>=InpBuyCloseLocation) score+=2;
   if(fast.velocity_pts_sec>=InpMinFastVelocityPtsSec) score+=2;
   if(medium.velocity_pts_sec>0.0) score++;
   if(accel>=InpMinAccelerationPtsSec) score++;
   if(fast.buy_ratio>=0.56 && fast.samples>=InpMinFastWindowTicks) score++;
   if(fast.efficiency>=InpMinTickEfficiency) score++;
   if(fast.samples>=InpMinFastWindowTicks*2) score++;
   if(fast.buy_aggressor_ticks>=2 && fast.aggressor_buy_ratio>=0.60) score++;
   if(recovery_velocity>=InpMinRecoveryVelocityPtsSec) score++;
   if(g_dom_for_signal && g_dom_imbalance>=InpDOMImbalanceThreshold) score++;
   return score;
  }

int ScoreWickSell(const double range_pts,const double lower_pts,const double upper_pts,
                  const double close_location,const double recovery_velocity,
                  const XTRDMetrics &fast,const XTRDMetrics &medium,const double accel)
  {
   int score=0;
   double min_wick=MaxD(InpMinWickPoints,g_last_spread*InpWickVsSpreadFactor);
   if(upper_pts>=min_wick && range_pts>0.0 && upper_pts/range_pts>=InpMinWickRangeShare) score+=2;
   if(close_location<=InpSellCloseLocation) score+=2;
   if(fast.velocity_pts_sec<=-InpMinFastVelocityPtsSec) score+=2;
   if(medium.velocity_pts_sec<0.0) score++;
   if(accel<=-InpMinAccelerationPtsSec) score++;
   if(fast.buy_ratio<=0.44 && fast.samples>=InpMinFastWindowTicks) score++;
   if(fast.efficiency>=InpMinTickEfficiency) score++;
   if(fast.samples>=InpMinFastWindowTicks*2) score++;
   if(fast.sell_aggressor_ticks>=2 && fast.aggressor_buy_ratio<=0.40) score++;
   if(recovery_velocity<=-InpMinRecoveryVelocityPtsSec) score++;
   if(g_dom_for_signal && g_dom_imbalance<=-InpDOMImbalanceThreshold) score++;
   return score;
  }

int ScoreContinuationBuy(const double range_pts,const double lower_pts,const double upper_pts,
                         const double close_location,const XTRDMetrics &fast,
                         const XTRDMetrics &medium,const XTRDMetrics &slow,const double accel)
  {
   int score=0;
   if(slow.velocity_pts_sec>=InpMinSlowVelocityPtsSec) score+=2;
   if(medium.velocity_pts_sec>0.0) score++;
   if(fast.velocity_pts_sec>=InpMinFastVelocityPtsSec) score+=2;
   if(close_location>=0.72) score++;
   if(lower_pts>=MaxD(2.0,InpMinWickPoints*0.25) && range_pts>0.0 && lower_pts/range_pts<=0.42) score++;
   if(upper_pts<lower_pts*0.75) score++;
   if(accel>0.0) score++;
   if(fast.efficiency>=InpMinTickEfficiency) score++;
   if(fast.samples>=InpMinFastWindowTicks*2) score++;
   if(fast.buy_aggressor_ticks>=2 && fast.aggressor_buy_ratio>=0.60) score++;
   if(g_dom_for_signal && g_dom_imbalance>=InpDOMImbalanceThreshold) score++;
   return score;
  }

int ScoreContinuationSell(const double range_pts,const double lower_pts,const double upper_pts,
                          const double close_location,const XTRDMetrics &fast,
                          const XTRDMetrics &medium,const XTRDMetrics &slow,const double accel)
  {
   int score=0;
   if(slow.velocity_pts_sec<=-InpMinSlowVelocityPtsSec) score+=2;
   if(medium.velocity_pts_sec<0.0) score++;
   if(fast.velocity_pts_sec<=-InpMinFastVelocityPtsSec) score+=2;
   if(close_location<=0.28) score++;
   if(upper_pts>=MaxD(2.0,InpMinWickPoints*0.25) && range_pts>0.0 && upper_pts/range_pts<=0.42) score++;
   if(lower_pts<upper_pts*0.75) score++;
   if(accel<0.0) score++;
   if(fast.efficiency>=InpMinTickEfficiency) score++;
   if(fast.samples>=InpMinFastWindowTicks*2) score++;
   if(fast.sell_aggressor_ticks>=2 && fast.aggressor_buy_ratio<=0.40) score++;
   if(g_dom_for_signal && g_dom_imbalance<=-InpDOMImbalanceThreshold) score++;
   return score;
  }

bool BuildSignal(const MqlTick &current,const long now_msc,int &direction,int &score,string &pattern,
                 XTRDMetrics &fast,XTRDMetrics &medium,XTRDMetrics &slow,double &accel)
  {
   direction=0;
   score=0;
   pattern="NONE";
   GetAllMetrics(now_msc,fast,medium,slow,accel);
   if(fast.samples<InpMinFastWindowTicks || medium.samples<3) return false;

   double range=g_candle_high-g_candle_low;
   if(range<=0.0) return false;
   double close_price=current.bid;
   double lower=MathMax(0.0,MinD(g_candle_open,close_price)-g_candle_low);
   double upper=MathMax(0.0,g_candle_high-MaxD(g_candle_open,close_price));
   double range_pts=range/g_point;
   double lower_pts=lower/g_point;
   double upper_pts=upper/g_point;
   double close_location=(close_price-g_candle_low)/range;
   close_location=MathMax(0.0,MathMin(1.0,close_location));

   double recovery_buy=0.0,recovery_sell=0.0;
   long elapsed_low=now_msc-g_candle_low_time_msc;
   long elapsed_high=now_msc-g_candle_high_time_msc;
   if(elapsed_low>0) recovery_buy=((close_price-g_candle_low)/g_point)*1000.0/(double)elapsed_low;
   if(elapsed_high>0) recovery_sell=((close_price-g_candle_high)/g_point)*1000.0/(double)elapsed_high;

   int buy_rej=ScoreWickBuy(range_pts,lower_pts,upper_pts,close_location,recovery_buy,fast,medium,accel);
   int sell_rej=ScoreWickSell(range_pts,lower_pts,upper_pts,close_location,recovery_sell,fast,medium,accel);
   if(InpSignalFamily==XTRD_MOMENTUM_PULLBACK)
     {
      buy_rej=0;
      sell_rej=0;
     }
   int buy_cont=0,sell_cont=0;
   if(InpSignalFamily==XTRD_MOMENTUM_PULLBACK || InpSignalFamily==XTRD_HYBRID)
     {
      buy_cont=ScoreContinuationBuy(range_pts,lower_pts,upper_pts,close_location,fast,medium,slow,accel);
      sell_cont=ScoreContinuationSell(range_pts,lower_pts,upper_pts,close_location,fast,medium,slow,accel);
     }
   if(InpSignalFamily==XTRD_WICK_REJECTION)
     {
      buy_cont=0;
      sell_cont=0;
     }

   int buy_score=(int)MathMax(buy_rej,buy_cont);
   int sell_score=(int)MathMax(sell_rej,sell_cont);
   string buy_pattern=(buy_rej>=buy_cont ? "WICK_REJECTION" : "MOMENTUM_PULLBACK");
   string sell_pattern=(sell_rej>=sell_cont ? "WICK_REJECTION" : "MOMENTUM_PULLBACK");

   // If both sides score similarly, stand aside; do not force a direction.
   if(buy_score>=InpSignalScoreThreshold && buy_score>sell_score)
     {
      direction=1;
      score=buy_score;
      pattern=buy_pattern;
     }
   else if(sell_score>=InpSignalScoreThreshold && sell_score>buy_score)
     {
      direction=-1;
      score=sell_score;
      pattern=sell_pattern;
     }
   else return false;

   // Economic viability check: require estimated short-horizon movement to clear a fraction of spread.
   double projected=MathAbs((direction>0 ? MaxD(fast.velocity_pts_sec,0.0) : MinD(fast.velocity_pts_sec,0.0))*InpExpectedMoveHorizonSeconds);
   double estimated_cost=g_last_spread+2.0*InpSlippagePerSidePoints;
   if(projected<estimated_cost*InpMinExpectedMoveSpreadFactor)
     {
      g_last_block_reason="Projected move too small versus spread";
      return false;
     }
   if(g_last_spread>InpMaxSpreadPoints)
     {
      g_last_block_reason="Spread above maximum";
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| CSV logging                                                       |
//+------------------------------------------------------------------+
void LogSignalCSV(const MqlTick &t,const int direction,const int score,const string pattern,
                  const XTRDMetrics &fast,const XTRDMetrics &medium,const XTRDMetrics &slow,
                  const double accel)
  {
   if(!InpWriteCSV) return;
   int h=FileOpen(XTRD_CSV_NAME,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE,';');
   if(h==INVALID_HANDLE)
     {
      Print("XTRD: cannot open CSV, error=",GetLastError());
      return;
     }
   if(FileSize(h)==0)
     {
      FileWrite(h,"time_msc","symbol","direction","score","pattern","bid","ask","spread_pts",
                "candle_open","candle_high","candle_low","candle_range_pts","lower_wick_pts","upper_wick_pts",
                "fast_net_pts","fast_vel_pts_sec","fast_buy_ratio","fast_samples",
                "fast_efficiency","fast_ticks_per_second","aggressor_buy_ticks","aggressor_sell_ticks","aggressor_buy_ratio","medium_vel_pts_sec","slow_vel_pts_sec","acceleration_pts_sec","dom_valid","dom_imbalance");
     }
   FileSeek(h,0,SEEK_END);
   double range_pts=(g_candle_high-g_candle_low)/g_point;
   double lower_pts=(MinD(g_candle_open,t.bid)-g_candle_low)/g_point;
   double upper_pts=(g_candle_high-MaxD(g_candle_open,t.bid))/g_point;
   FileWrite(h,(string)t.time_msc,g_symbol,(direction>0?"BUY":"SELL"),score,pattern,
             DoubleToString(t.bid,g_digits),DoubleToString(t.ask,g_digits),DoubleToString((t.ask-t.bid)/g_point,1),
             DoubleToString(g_candle_open,g_digits),DoubleToString(g_candle_high,g_digits),DoubleToString(g_candle_low,g_digits),
             DoubleToString(range_pts,1),DoubleToString(lower_pts,1),DoubleToString(upper_pts,1),
             DoubleToString(fast.net_pts,2),DoubleToString(fast.velocity_pts_sec,2),DoubleToString(fast.buy_ratio,3),fast.samples,
             DoubleToString(fast.efficiency,3),DoubleToString((double)fast.samples*1000.0/(double)InpFastWindowMs,1),
             fast.buy_aggressor_ticks,fast.sell_aggressor_ticks,DoubleToString(fast.aggressor_buy_ratio,3),
             DoubleToString(medium.velocity_pts_sec,2),DoubleToString(slow.velocity_pts_sec,2),DoubleToString(accel,2),
             (g_dom_valid?1:0),DoubleToString(g_dom_imbalance,3));
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| Position/order helpers                                            |
//+------------------------------------------------------------------+
int CountManagedPositions()
  {
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      count++;
     }
   return count;
  }

int CountManagedPendingOrders()
  {
   int count=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=g_symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
      count++;
     }
   return count;
  }

int CountAnySymbolPositions()
  {
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==g_symbol) count++;
     }
   return count;
  }

int CountAnySymbolOrders()
  {
   int count=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0) continue;
      if(OrderGetString(ORDER_SYMBOL)==g_symbol) count++;
     }
   return count;
  }

bool GetValidatedVolume(double &volume,string &reason)
  {
   double vmin=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_STEP);
   if(vmin<=0.0 || vmax<=0.0 || step<=0.0)
     {
      reason="Invalid broker volume specification";
      return false;
     }
   if(InpFixedVolume<vmin-1e-8)
     {
      reason="Configured volume is below broker minimum";
      return false;
     }
   volume=MathMin(InpFixedVolume,vmax);
   volume=MathFloor(volume/step+1e-8)*step;
   int vol_digits=2;
   if(step>=1.0) vol_digits=0;
   else if(step>=0.1) vol_digits=1;
   else if(step>=0.01) vol_digits=2;
   else if(step>=0.001) vol_digits=3;
   volume=NormalizeDouble(volume,vol_digits);
   if(volume<vmin-1e-8)
     {
      reason="Normalized volume is below broker minimum";
      return false;
     }
   return true;
  }

bool CalculateInitialStops(const int direction,const MqlTick &t,double &sl,double &stop_points,string &reason)
  {
   long stops_level=SymbolInfoInteger(g_symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double min_dist=(double)stops_level*g_point;
   min_dist=MathMax(min_dist,g_point*2.0);
   if(direction>0)
     {
      sl=g_candle_low-InpStopBufferPoints*g_point;
      double max_allowed=t.bid-min_dist;
      if(sl>max_allowed) sl=max_allowed;
      sl=NormalizePrice(sl);
      stop_points=(t.ask-sl)/g_point;
     }
   else
     {
      sl=g_candle_high+InpStopBufferPoints*g_point;
      double min_allowed=t.ask+min_dist;
      if(sl<min_allowed) sl=min_allowed;
      sl=NormalizePrice(sl);
      stop_points=(sl-t.bid)/g_point;
     }
   if(stop_points<=0.0 || stop_points>InpMaxInitialStopPoints)
     {
      reason="Initial stop outside allowed distance";
      return false;
     }
   return true;
  }

bool CheckRiskAndMargin(const int direction,const double volume,const double entry,const double sl,string &reason)
  {
   double tick_size=SymbolInfoDouble(g_symbol,SYMBOL_TRADE_TICK_SIZE);
   double tick_value=SymbolInfoDouble(g_symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tick_value<=0.0) tick_value=SymbolInfoDouble(g_symbol,SYMBOL_TRADE_TICK_VALUE);
   if(tick_size<=0.0 || tick_value<=0.0)
     {
      reason="Tick value/size unavailable; risk cannot be verified";
      return false;
     }
   double risk=(MathAbs(entry-sl)/tick_size)*tick_value*volume;
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance<=0.0 || risk>balance*InpMaxRiskPercent/100.0)
     {
      reason="Estimated loss at initial SL exceeds risk cap";
      return false;
     }

   double margin=0.0;
   ENUM_ORDER_TYPE type=(direction>0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcMargin(type,g_symbol,volume,entry,margin))
     {
      reason="OrderCalcMargin failed";
      return false;
     }
   double free_margin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin>free_margin*0.80)
     {
      reason="Insufficient free margin safety buffer";
      return false;
     }
   return true;
  }

void CancelExpiredPendingOrders()
  {
   if(InpLimitExpirySeconds<=0) return;
   ulong local_now=GetTickCount64();
   if(g_last_cancel_attempt_local_ms>0 && local_now-g_last_cancel_attempt_local_ms<500) return;
   g_last_cancel_attempt_local_ms=local_now;
   datetime now=TimeCurrent();
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=g_symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
      datetime setup=(datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(setup>0 && (now-setup)>=InpLimitExpirySeconds)
        {
         bool deleted=g_trade.OrderDelete(ticket);
         uint rc=g_trade.ResultRetcode();
         if(!deleted || (rc!=TRADE_RETCODE_DONE && rc!=TRADE_RETCODE_PLACED))
            Print("XTRD: pending cancel failed #",ticket," retcode=",rc," ",g_trade.ResultRetcodeDescription());
        }
     }
  }

void ExecuteSignal(const int direction,const int score,const string pattern,const MqlTick &t)
  {
   if(!InpEnableLiveTrading || InpEntryMode==XTRD_SIGNAL_ONLY) return;
   long live_msc=SymbolInfoInteger(g_symbol,SYMBOL_TIME_MSC);
   if(live_msc<t.time_msc || (live_msc-t.time_msc)>InpMaxSignalLatencyMs)
     {
      g_last_block_reason="Signal too old for a market/limit order";
      return;
     }
   // Avoid mixing with manual trades or another EA on the same symbol (especially netting accounts).
   if(CountAnySymbolPositions()>=InpMaxOpenPositions || CountAnySymbolOrders()>0) return;
   if(g_entries_this_minute>=InpMaxEntriesPerMinute) return;
   if(g_last_order_msc>0 && t.time_msc-g_last_order_msc<InpSignalCooldownMs) return;
   if((t.ask-t.bid)/g_point>InpMaxSpreadPoints) return;

   double volume=0.0;
   string reason="";
   if(!GetValidatedVolume(volume,reason))
     {
      g_last_block_reason=reason;
      Print("XTRD BLOCK: ",reason);
      return;
     }

   double sl=0.0,stop_points=0.0;
   if(!CalculateInitialStops(direction,t,sl,stop_points,reason))
     {
      g_last_block_reason=reason;
      Print("XTRD BLOCK: ",reason);
      return;
     }

   double entry=(direction>0 ? t.ask : t.bid);
   if(InpEntryMode==XTRD_LIMIT_PULLBACK)
     {
      double offset=MathMax((double)InpLimitOffsetPoints,(t.ask-t.bid)/g_point*0.25);
      entry=(direction>0 ? t.ask-offset*g_point : t.bid+offset*g_point);
      entry=NormalizePrice(entry);
      // Ensure limit order is still on the valid side of the market.
      if(direction>0 && entry>=t.ask) { g_last_block_reason="Invalid buy-limit price"; return; }
      if(direction<0 && entry<=t.bid) { g_last_block_reason="Invalid sell-limit price"; return; }
      // Rebuild stop risk around the planned limit entry; the stop remains beyond the observed wick.
      if(direction>0) stop_points=(entry-sl)/g_point;
      else stop_points=(sl-entry)/g_point;
     }

   if(!CheckRiskAndMargin(direction,volume,entry,sl,reason))
     {
      g_last_block_reason=reason;
      Print("XTRD BLOCK: ",reason);
      return;
     }

   bool sent=false;
   ENUM_ORDER_TYPE_TIME limit_time=ORDER_TIME_GTC;
   datetime limit_expiration=0;
   long expiration_modes=SymbolInfoInteger(g_symbol,SYMBOL_EXPIRATION_MODE);
   if(InpLimitExpirySeconds>0 && (expiration_modes & SYMBOL_EXPIRATION_SPECIFIED)!=0)
     {
      limit_time=ORDER_TIME_SPECIFIED;
      limit_expiration=TimeCurrent()+InpLimitExpirySeconds;
     }
   string comment="XTRD_TICK_HUNTER_"+pattern+"_S"+IntegerToString(score);
   if(InpEntryMode==XTRD_MARKET_ENTRY)
     {
      if(direction>0) sent=g_trade.Buy(volume,g_symbol,0.0,sl,0.0,comment);
      else sent=g_trade.Sell(volume,g_symbol,0.0,sl,0.0,comment);
     }
   else if(InpEntryMode==XTRD_LIMIT_PULLBACK)
     {
      if(direction>0)
         sent=g_trade.BuyLimit(volume,entry,g_symbol,sl,0.0,limit_time,limit_expiration,comment);
      else
         sent=g_trade.SellLimit(volume,entry,g_symbol,sl,0.0,limit_time,limit_expiration,comment);
     }

   uint rc=g_trade.ResultRetcode();
   bool accepted=(sent && (rc==TRADE_RETCODE_DONE || rc==TRADE_RETCODE_PLACED || rc==TRADE_RETCODE_DONE_PARTIAL));
   if(accepted)
     {
      g_entries_this_minute++;
      g_last_order_msc=t.time_msc;
      Print("XTRD ORDER ACCEPTED: ",(direction>0?"BUY":"SELL")," mode=",(InpEntryMode==XTRD_MARKET_ENTRY?"MARKET":"LIMIT"),
            " score=",score," volume=",DoubleToString(volume,2)," SL=",DoubleToString(sl,g_digits),
            " retcode=",rc," ",g_trade.ResultRetcodeDescription());
     }
   else
     {
      g_last_block_reason="Trade request rejected: "+g_trade.ResultRetcodeDescription();
      Print("XTRD ORDER FAILED: ",rc," ",g_trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Adaptive trailing stop                                            |
//+------------------------------------------------------------------+
double g_cached_atr_points=0.0;
long g_last_atr_refresh_msc=0;

double ReadATRPoints(const long now_msc)
  {
   if(g_atr_handle==INVALID_HANDLE) return 0.0;
   if(g_last_atr_refresh_msc>0 && now_msc-g_last_atr_refresh_msc<750) return g_cached_atr_points;
   double v[];
   ArraySetAsSeries(v,true);
   if(CopyBuffer(g_atr_handle,0,0,1,v)==1) g_cached_atr_points=v[0]/g_point;
   g_last_atr_refresh_msc=now_msc;
   return g_cached_atr_points;
  }

void ManagePositions(const MqlTick &t)
  {
   long now_msc=t.time_msc;
   double spread=(t.ask-t.bid)/g_point;
   double atr_pts=ReadATRPoints(now_msc);
   double trail_dist=MathMax(InpMinTrailDistancePoints,spread*InpTrailSpreadFactor);
   if(atr_pts>0.0) trail_dist=MathMax(trail_dist,atr_pts*InpTrailATRFactor);
   trail_dist=MathMin(trail_dist,InpMaxTrailDistancePoints);
   double trail_start=MathMax(InpTrailStartPoints,spread*InpTrailStartSpreadFactor);

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      long type=PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double old_sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      double profit_pts=(type==POSITION_TYPE_BUY ? (t.bid-open)/g_point : (open-t.ask)/g_point);

      if(InpExitOnMomentumFlip && profit_pts>=InpMomentumFlipExitPoints)
        {
         XTRDMetrics f,m,s; double a=0.0;
         GetAllMetrics(now_msc,f,m,s,a);
         bool flipped=(type==POSITION_TYPE_BUY ? (f.velocity_pts_sec<-InpMinFastVelocityPtsSec && m.velocity_pts_sec<0.0)
                                               : (f.velocity_pts_sec>InpMinFastVelocityPtsSec && m.velocity_pts_sec>0.0));
         if(flipped)
           {
            bool closed=g_trade.PositionClose(ticket);
            uint close_rc=g_trade.ResultRetcode();
            if(closed && (close_rc==TRADE_RETCODE_DONE || close_rc==TRADE_RETCODE_DONE_PARTIAL))
               Print("XTRD EXIT: momentum flip #",ticket," profit_pts=",DoubleToString(profit_pts,1));
            else
               Print("XTRD EXIT failed #",ticket," retcode=",close_rc," ",g_trade.ResultRetcodeDescription());
            continue;
           }
        }

      if(profit_pts<trail_start) continue;
      if(now_msc-g_last_trail_update_msc<150) continue;

      long stops_level=SymbolInfoInteger(g_symbol,SYMBOL_TRADE_STOPS_LEVEL);
      long freeze_level=SymbolInfoInteger(g_symbol,SYMBOL_TRADE_FREEZE_LEVEL);
      double min_dist=(double)MathMax(stops_level,freeze_level)*g_point;
      min_dist=MathMax(min_dist,g_point*2.0);
      double lock_pts=profit_pts-trail_dist;
      if(lock_pts<=0.0) continue;

      double new_sl=0.0;
      if(type==POSITION_TYPE_BUY)
        {
         new_sl=NormalizePrice(open+lock_pts*g_point);
         double max_sl=t.bid-min_dist;
         if(new_sl>max_sl) new_sl=NormalizePrice(max_sl);
         if(old_sl>0.0 && new_sl<=old_sl+InpTrailStepPoints*g_point) continue;
         if(new_sl<=open) continue;
        }
      else
        {
         new_sl=NormalizePrice(open-lock_pts*g_point);
         double min_sl=t.ask+min_dist;
         if(new_sl<min_sl) new_sl=NormalizePrice(min_sl);
         if(old_sl>0.0 && new_sl>=old_sl-InpTrailStepPoints*g_point) continue;
         if(new_sl>=open) continue;
        }

      // Throttle even failed modifications so a broker rejection cannot spam requests.
      g_last_trail_update_msc=now_msc;
      bool modified=g_trade.PositionModify(ticket,new_sl,tp);
      uint modify_rc=g_trade.ResultRetcode();
      if(modified && (modify_rc==TRADE_RETCODE_DONE || modify_rc==TRADE_RETCODE_NO_CHANGES))
        {
         g_last_trail_update_msc=now_msc;
         Print("XTRD TRAIL: #",ticket," profit_pts=",DoubleToString(profit_pts,1),
               " newSL=",DoubleToString(new_sl,g_digits)," trailDist=",DoubleToString(trail_dist,1));
        }
      else
        {
         // Do not flood the journal; the server retcode remains visible on a failed modification.
         if(modify_rc!=TRADE_RETCODE_NO_CHANGES)
            Print("XTRD trail modify failed #",ticket," retcode=",modify_rc," ",g_trade.ResultRetcodeDescription());
        }
     }
  }

//+------------------------------------------------------------------+
//| Tick-level signal evaluation                                      |
//+------------------------------------------------------------------+
void EvaluateOnNewTick(const MqlTick &t)
  {
   long live_quote_msc=SymbolInfoInteger(g_symbol,SYMBOL_TIME_MSC);
   ulong local_now=GetTickCount64();
   g_dom_for_signal=(g_dom_valid && g_dom_update_local_ms>0 && (local_now-g_dom_update_local_ms)<=300 &&
                     live_quote_msc>=t.time_msc && (live_quote_msc-t.time_msc)<=100);
   XTRDMetrics fast,medium,slow;
   double accel=0.0;
   int direction=0,score=0;
   string pattern="NONE";
   bool signal=BuildSignal(t,t.time_msc,direction,score,pattern,fast,medium,slow,accel);

   g_last_fast_velocity=fast.velocity_pts_sec;
   g_last_medium_velocity=medium.velocity_pts_sec;
   g_last_slow_velocity=slow.velocity_pts_sec;
   g_last_acceleration=accel;
   g_last_buy_score=0;
   g_last_sell_score=0;

   // Expose approximate score information for the dashboard even when no signal fires.
   double rng=(g_candle_high-g_candle_low);
   if(rng>0.0)
     {
      double lo=(MinD(g_candle_open,t.bid)-g_candle_low)/g_point;
      double hi=(g_candle_high-MaxD(g_candle_open,t.bid))/g_point;
      double cp=(t.bid-g_candle_low)/rng;
      double rvb=0.0,rvs=0.0;
      if(t.time_msc>g_candle_low_time_msc) rvb=((t.bid-g_candle_low)/g_point)*1000.0/(double)(t.time_msc-g_candle_low_time_msc);
      if(t.time_msc>g_candle_high_time_msc) rvs=((t.bid-g_candle_high)/g_point)*1000.0/(double)(t.time_msc-g_candle_high_time_msc);
      int br=ScoreWickBuy(rng/g_point,lo,hi,cp,rvb,fast,medium,accel);
      int sr=ScoreWickSell(rng/g_point,lo,hi,cp,rvs,fast,medium,accel);
      if(InpSignalFamily!=XTRD_WICK_REJECTION)
        {
         br=(int)MathMax(br,ScoreContinuationBuy(rng/g_point,lo,hi,cp,fast,medium,slow,accel));
         sr=(int)MathMax(sr,ScoreContinuationSell(rng/g_point,lo,hi,cp,fast,medium,slow,accel));
        }
      g_last_buy_score=br;
      g_last_sell_score=sr;
     }

   if(!signal) return;
   if(g_last_signal_msc>0 && t.time_msc-g_last_signal_msc<InpSignalCooldownMs) return;
   g_last_signal_msc=t.time_msc;
   g_last_signal=(direction>0 ? "BUY" : "SELL")+" "+pattern;
   g_last_block_reason="";
   LogSignalCSV(t,direction,score,pattern,fast,medium,slow,accel);

   if(InpPrintEverySignal)
      Print("XTRD SIGNAL ",(direction>0?"BUY":"SELL")," ",pattern," score=",score,
            " spread=",DoubleToString((t.ask-t.bid)/g_point,1),
            " fastV=",DoubleToString(fast.velocity_pts_sec,1),
            " midV=",DoubleToString(medium.velocity_pts_sec,1),
            " slowV=",DoubleToString(slow.velocity_pts_sec,1),
            " accel=",DoubleToString(accel,1),
            " DOM=",(g_dom_valid?DoubleToString(g_dom_imbalance,2):"NA"));

   ExecuteSignal(direction,score,pattern,t);
  }

//+------------------------------------------------------------------+
//| Dashboard                                                         |
//+------------------------------------------------------------------+
void UpdateDashboard()
  {
   if(!InpShowDashboard) return;
   string mode=(InpEntryMode==XTRD_SIGNAL_ONLY ? "SIGNAL ONLY" : (InpEntryMode==XTRD_MARKET_ENTRY ? "MARKET" : "LIMIT PULLBACK"));
   string live=(InpEnableLiveTrading ? "LIVE EXECUTION ENABLED" : "LIVE EXECUTION OFF");
   string dom=(g_dom_valid ? DoubleToString(g_dom_imbalance,2) : "unavailable");
   Comment("XTRD M1 TICK HUNTER v0.10\n",
           g_symbol," | ",mode," | ",live,"\n",
           "Spread: ",DoubleToString(g_last_spread,1)," pts / Max ",DoubleToString(InpMaxSpreadPoints,1),"\n",
           "Tick velocity pts/s  250ms: ",DoubleToString(g_last_fast_velocity,1),
           " | 750ms: ",DoubleToString(g_last_medium_velocity,1),
           " | 2s: ",DoubleToString(g_last_slow_velocity,1),"\n",
           "Acceleration: ",DoubleToString(g_last_acceleration,1),
           " | BUY score: ",g_last_buy_score," | SELL score: ",g_last_sell_score,"\n",
           "DOM imbalance: ",dom," | Positions: ",CountManagedPositions(),
           " | Pending: ",CountManagedPendingOrders(),"\n",
           "Last signal: ",g_last_signal,"\n",
           "Last block/info: ",g_last_block_reason);
  }

//+------------------------------------------------------------------+
//| MT5 event handlers                                                |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_symbol=(InpTradeSymbol=="" ? _Symbol : InpTradeSymbol);
   if(!SymbolSelect(g_symbol,true))
     {
      Print("XTRD INIT FAILED: cannot select symbol ",g_symbol);
      return INIT_FAILED;
     }
   g_point=SymbolInfoDouble(g_symbol,SYMBOL_POINT);
   g_digits=(int)SymbolInfoInteger(g_symbol,SYMBOL_DIGITS);
   if(g_point<=0.0)
     {
      Print("XTRD INIT FAILED: invalid SYMBOL_POINT");
      return INIT_FAILED;
     }

   // Seed the currently forming candle from data available at attachment time.
   // Its extreme timestamps remain unknown until this EA observes new extremes.
   MqlTick seed_tick;
   datetime seed_bar=iTime(g_symbol,PERIOD_M1,0);
   if(seed_bar>0 && SymbolInfoTick(g_symbol,seed_tick))
     {
      g_bar_time=seed_bar;
      double seed_open=iOpen(g_symbol,PERIOD_M1,0);
      double seed_high=iHigh(g_symbol,PERIOD_M1,0);
      double seed_low=iLow(g_symbol,PERIOD_M1,0);
      g_candle_open=(seed_open>0.0 ? seed_open : seed_tick.bid);
      g_candle_high=(seed_high>0.0 ? seed_high : seed_tick.bid);
      g_candle_low=(seed_low>0.0 ? seed_low : seed_tick.bid);
      g_candle_low_time_msc=0;
      g_candle_high_time_msc=0;
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpMaxDeviationPoints);
   g_trade.SetTypeFillingBySymbol(g_symbol);
   g_trade.SetAsyncMode(false);

   g_atr_handle=iATR(g_symbol,PERIOD_M1,14);
   if(g_atr_handle==INVALID_HANDLE)
      Print("XTRD: ATR handle unavailable; trail will use spread floor only.");

   if(InpUseMarketBook)
     {
      long depth=SymbolInfoInteger(g_symbol,SYMBOL_TICKS_BOOKDEPTH);
      if(depth>0 && MarketBookAdd(g_symbol))
        {
         g_dom_subscribed=true;
         Print("XTRD: MarketBook subscription active; advertised depth=",depth);
        }
      else
        {
         g_dom_subscribed=false;
         Print("XTRD: DOM unavailable for this symbol/broker. Tick/candle engine remains fully active.");
        }
     }

   int timer_ms=(int)MathMax(50,InpTimerMilliseconds);
   if(!EventSetMillisecondTimer(timer_ms))
      Print("XTRD: millisecond timer unavailable, error=",GetLastError());

   Print("XTRD M1 TICK HUNTER initialized. symbol=",g_symbol,
         " point=",DoubleToString(g_point,g_digits),
         " digits=",g_digits,
         " tick_size=",DoubleToString(SymbolInfoDouble(g_symbol,SYMBOL_TRADE_TICK_SIZE),g_digits),
         " volume_min=",DoubleToString(SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_MIN),2),
         " volume_step=",DoubleToString(SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_STEP),2),
         " stops_level=",SymbolInfoInteger(g_symbol,SYMBOL_TRADE_STOPS_LEVEL),
         " freeze_level=",SymbolInfoInteger(g_symbol,SYMBOL_TRADE_FREEZE_LEVEL));
   if(_Symbol!=g_symbol)
      Print("XTRD WARNING: attach this EA to the target symbol chart (",g_symbol,") for the lowest tick latency. Current chart=",_Symbol);
   Print("SAFETY: live trading is ",(InpEnableLiveTrading?"ENABLED":"DISABLED"),"; entry mode=",(int)InpEntryMode);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_dom_subscribed) MarketBookRelease(g_symbol);
   if(g_atr_handle!=INVALID_HANDLE) IndicatorRelease(g_atr_handle);
   Comment("");
   Print("XTRD M1 TICK HUNTER deinitialized. reason=",reason);
  }

void OnTick()
  {
   CaptureTicks();
   MqlTick t;
   if(SymbolInfoTick(g_symbol,t))
     {
      ManagePositions(t);
      UpdateDashboard();
     }
  }

void OnTimer()
  {
   CaptureTicks();
   MqlTick t;
   if(SymbolInfoTick(g_symbol,t))
     {
      CancelExpiredPendingOrders();
      ManagePositions(t);
      UpdateDashboard();
     }
  }

void OnBookEvent(const string &symbol)
  {
   if(symbol!=g_symbol) return;
   RefreshDOM();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.symbol!=g_symbol) return;
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD)
      Print("XTRD DEAL: deal=",trans.deal," order=",trans.order," price=",DoubleToString(trans.price,g_digits),
            " volume=",DoubleToString(trans.volume,2)," retcode=",result.retcode);
  }
//+------------------------------------------------------------------+
