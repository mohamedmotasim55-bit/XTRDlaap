//+------------------------------------------------------------------+
//|                                                   X13_GLOBAL.mq5 |
//|                 Unified XAUUSD engine, revision 2.0 (MQL5)       |
//|                 Replacement for XTRD OMIGA v2.23                 |
//+------------------------------------------------------------------+
#property copyright "X13 GLOBAL"
#property version   "2.00"
#property strict

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Module map (numbering follows the X13 specification, 01 to 34)   |
//|  01 Runtime and state           OnTick order, day state, restore |
//|  02 Market data                 ticks validated before storage   |
//|  03 Tick memory                 ring buffer, millisecond stamps  |
//|  04 Broker and symbol profile   hedging/netting, filling, limits |
//|  05 Data quality                zero, crossed, stale, jump rejects|
//|  06 Tick intelligence           windowed moves in ATR, stall     |
//|  07 Candle intelligence         closed, forming, star, soldiers  |
//|  08 Price action and structure  fractal swings, BOS, CHoCH, sweep|
//|  09 Volatility                  ATR, ATR ratio, realised vol     |
//|  10 Regime                      trend, range, compression, etc.  |
//|  11 Multi-timeframe             M1, M5, M15, H1 bias score       |
//|  12 Session and time            server-hour sessions             |
//|  13 Liquidity behaviour         sweep proxy, spread widening     |
//|  14 Opportunity generator       8 families, evidence counting    |
//|  15 Opportunity lifecycle       DETECTED, EXPIRED, REJECTED, EXEC|
//|  16 Clustering and dedup        same-side merge, all families kept|
//|  17 Probability engine          Beta posterior per family x regime|
//|  18 Net-edge decision           money EV, breakeven incl. costs  |
//|  19 Priority queue              best first, several per tick     |
//|  20 Correlation, independence   netting/hedging rules, spacing   |
//|  21 Execution intelligence      market orders, drift, retcodes   |
//|  22 Dynamic position sizing     OrderCalcProfit loss, step, margin|
//|  23 Dynamic risk management     open-risk cap, daily stop, DD scale|
//|  24 Concurrent trade management per-identifier state, persisted  |
//|  25 Smart stop loss             break-even, profit lock, ATR trail|
//|  26 Smart take profit           two-stage partial targets        |
//|  27 Smart exit                  CHoCH exit, decay exit, time stop|
//|  28 Basket exit                 per-side floating, emergency     |
//|  29 Opportunity memory          every candidate journaled        |
//|  30 Performance attribution     family, regime, session totals   |
//|  31 Strategy health             family streak cooldown           |
//|  32 Adaptive control            bounded risk scaling only        |
//|  33 Offline research            outside the EA (WFA, parameter sets)|
//|  34 Validation                  calibration table, Monte Carlo   |
//|                                                                  |
//| Parameters are frozen while trading. Only the per-cell win       |
//| statistics learn online, persisted, and they gate entries        |
//| through their lower confidence bound, not their mean.            |
//+------------------------------------------------------------------+

//--- Inputs -----------------------------------------------------------
input group "=== General ==="
input ulong  InpMagic             = 13013;   // magic number
input int    InpDeviationPts      = 20;      // max slippage (points)
input int    InpMaxSpreadPts      = 60;      // no new entries above this spread
input int    InpStaleTickMs       = 3000;    // tick older than this is stale
input bool   InpLogging           = true;    // CSV journal in MQL5/Files
input bool   InpDashboard         = true;    // on-chart dashboard

input group "=== Session (broker server time) ==="
input int    InpTradeStartH       = 8;       // trading window start hour (inclusive)
input int    InpTradeEndH         = 22;      // trading window end hour (exclusive)
input int    InpAsiaEndH          = 7;       // Asia session ends at this hour
input int    InpLondonEndH        = 13;      // London session ends at this hour
input int    InpNYEndH            = 21;      // New York session ends at this hour

input group "=== Risk ==="
input double InpRiskPerTradePct   = 0.50;    // equity risked per trade (%)
input double InpMaxOpenRiskPct    = 2.00;    // equity risked across open trades (%)
input int    InpMaxPositions      = 12;      // max simultaneous positions
input int    InpMaxNewPerTick     = 3;       // max executions in one tick
input double InpDailyLossPct      = 3.00;    // no new entries after this daily loss (%)
input double InpBasketEmergPct    = 6.00;    // close all if floating loss exceeds (%)
input int    InpLossStreakLimit   = 5;       // consecutive losses that trigger a pause
input int    InpRecoveryMinutes   = 15;      // pause length (minutes)
input double InpMinMarginMult     = 1.5;     // free margin must cover required margin x this
input bool   InpAllowHedgePairs   = true;    // BUY and SELL together (hedging accounts)
input double InpDDScalePct        = 10.0;    // drawdown (%) at which risk reaches its floor
input double InpMinRiskScale      = 0.25;    // risk floor during drawdown

input group "=== Probability and net edge ==="
input int    InpMinEvidence       = 2;       // independent signals required
input double InpPriorWinRate      = 0.50;    // prior win rate per cell (neutral)
input double InpPriorStrength     = 20.0;    // prior weight (equivalent trades)
input double InpZLower            = 1.28;    // one-sided confidence for the lower bound
input int    InpMinCellN          = 30;      // trades before a cell trades at full size
input double InpProbationMult     = 0.50;    // risk multiplier for immature cells
input double InpMinEVPerRisk      = 0.05;    // minimum net EV as fraction of risk money
input double InpCommPerLot        = 0.0;     // round-turn commission per lot (account currency)
input int    InpSlipBufferPts     = 3;       // slippage budget in costs (points)
input int    InpCandidateTTLms    = 4000;    // candidate validity (ms)
input double InpMaxEntryDevATR    = 0.25;    // max price drift from detection (ATR)
input int    InpMinSpacingMs      = 3000;    // min time between same-side entries
input double InpMinSpacingATR     = 0.30;    // min price distance between same-side entries
input int    InpFamilyLossTrigger = 3;       // consecutive family losses that start cooldown
input int    InpFamilyCooldownMin = 15;      // family cooldown length (minutes)

input group "=== Signal thresholds (ATR units) ==="
input double InpMMMove250         = 0.12;    // micro-momentum: move over 250 ms
input double InpMMMove1000        = 0.20;    // micro-momentum: move over 1000 ms
input int    InpMMMinTicks1s      = 8;       // minimum tick activity in the last second
input double InpBreakoutFresh     = 0.30;    // max distance beyond a fresh break
input double InpPullbackNear      = 0.25;    // max distance from EMA for a pullback
input double InpStretch           = 1.00;    // stretch from EMA for mean reversion
input double InpReleaseBarRange   = 1.40;    // bar range (ATR) for compression release
input double InpExhaustImpulse    = 1.00;    // impulse (ATR per second window) for exhaustion
input double InpExhaustStall      = 0.02;    // recent move that counts as a stall
input double InpDecayExit         = 0.10;    // adverse 250 ms move that exits a winner

input group "=== Stops and targets ==="
input double InpSL_ATR            = 1.20;    // stop distance (ATR)
input double InpTP_ATR            = 1.80;    // target distance (ATR)
input double InpBE_TriggerR       = 0.80;    // break-even trigger (R)
input double InpLockR             = 1.50;    // profit-lock trigger (R)
input double InpLockFracR         = 0.50;    // profit locked at this many R
input double InpTrail_ATR         = 1.00;    // trailing distance after lock (ATR)
input bool   InpUsePartial        = true;    // partial closes enabled
input double InpPartialR          = 1.00;    // first partial trigger (R)
input double InpPartialPct        = 40.0;    // share of volume closed at first partial
input double InpPartial2R         = 2.00;    // second partial trigger (R)
input double InpPartial2Pct       = 30.0;    // share of volume closed at second partial
input int    InpMaxHoldMin        = 30;      // time stop for non-winning trades (minutes)

//--- Constants, enums and types ---------------------------------------
#define TICK_BUF   512
#define MAX_CAND    32
#define MAX_POS     64
#define FAM_N        8
#define REG_N        7
#define CELL_N      56
#define SES_N        4
#define PNL_MAX   5000
#define CAL_BINS    10

enum ENUM_FAMILY
{
   FAM_MICRO = 0,
   FAM_BREAKOUT,
   FAM_PULLBACK,
   FAM_CANDLE,
   FAM_MEANREV,
   FAM_RELEASE,
   FAM_SWEEP,
   FAM_EXHAUST
};

enum ENUM_REGIME
{
   REG_UNKNOWN = 0,
   REG_TREND,
   REG_RANGE,
   REG_COMPRESSION,
   REG_EXPANSION,
   REG_LOWVOL,
   REG_CHAOS
};

enum ENUM_SESSION
{
   SES_ASIA = 0,
   SES_LONDON,
   SES_NY,
   SES_OFF
};

enum ENUM_OPP_STATE
{
   OPP_DETECTED = 0,
   OPP_EXPIRED,
   OPP_REJECTED,
   OPP_EXECUTED
};

enum ENUM_ENGINE_STATE
{
   ENG_RUN = 0,
   ENG_PROTECT
};

const int DIR_BUY  =  1;
const int DIR_SELL = -1;

struct MarketCtx
{
   bool        ready;
   double      atr;
   double      atrRatio;
   double      realVol;
   double      emaF;
   double      emaS;
   double      slope;
   double      trendStr;
   double      swHi0;
   double      swHi1;
   double      swLo0;
   double      swLo1;
   int         structBias;
   bool        bosUp;
   bool        bosDn;
   bool        chochUp;
   bool        chochDn;
   bool        sweepUp;
   bool        sweepDown;
   double      barRange;
   double      prevO;
   double      prevC;
   int         candleClosed;
   int         candleLive;
   double      liveProgress;
   int         h1Bias;
   int         mtfScore;
   int         session;
   bool        inSession;
   double      spreadRatio;
   ENUM_REGIME regime;
};

struct Candidate
{
   bool   active;
   int    state;
   int    famMask;
   int    fam;
   int    dir;
   int    regime;
   int    session;
   int    evidence;
   double entry;
   double slDist;
   double tpDist;
   double prelim;
   long   id;
   long   expireMsc;
};

struct EvalRes
{
   double lot;
   double risk;
   double gain;
   double costs;
   double ev;
   double evr;
   double pmean;
   double plow;
   double pbe;
};

struct PosMeta
{
   long   ident;
   ulong  ticket;
   int    dir;
   int    famMask;
   int    fam;
   int    regime;
   int    session;
   double entry;
   double initR;
   double mfeR;
   double maeR;
   double pred;
   int    partialStage;
   bool   beDone;
   bool   lockDone;
   long   openSec;
};

struct TickFeat
{
   double m50;
   double m100;
   double m250;
   double m1000;
   double accel;
   int    tps1;
   bool   stall;
};

//--- Global state -----------------------------------------------------
CTrade                  g_trade;
bool                    g_hedging   = false;
ENUM_ORDER_TYPE_FILLING g_filling   = ORDER_FILLING_RETURN;
double                  g_point     = 0.0;
double                  g_tickSize  = 0.0;
double                  g_tickValue = 0.0;
double                  g_volMin    = 0.0;
double                  g_volMax    = 0.0;
double                  g_volStep   = 0.0;
int                     g_digits    = 0;
int                     g_stopsPts  = 0;

int g_hATR    = INVALID_HANDLE;
int g_hEMAf   = INVALID_HANDLE;
int g_hEMAs   = INVALID_HANDLE;
int g_hEMAh1  = INVALID_HANDLE;
int g_hEMAm5  = INVALID_HANDLE;
int g_hEMAm15 = INVALID_HANDLE;

long   g_tMsc[TICK_BUF];
double g_tMid[TICK_BUF];
int    g_tHead  = 0;
int    g_tCount = 0;
int    g_jumpCount = 0;
long   g_nowMsc = 0;

MarketCtx   g_ctx;
ENUM_REGIME g_prevRegime = REG_UNKNOWN;
datetime    g_lastM1     = 0;
bool        g_qualityOK  = false;
string      g_qualityWhy = "";
TickFeat    g_tf;
string      g_lastReject = "";
long        g_lastDashMs = 0;

Candidate g_cand[MAX_CAND];
long      g_candSeq = 0;

double g_cellW[CELL_N];
double g_cellL[CELL_N];
int    g_famStreak[FAM_N];
long   g_famCooldownMsc[FAM_N];
double g_famPnl[FAM_N];
int    g_famN[FAM_N];
double g_regPnl[REG_N];
int    g_regN[REG_N];
double g_sesPnl[SES_N];
int    g_sesN[SES_N];
double g_calN[CAL_BINS];
double g_calW[CAL_BINS];
double g_calP[CAL_BINS];

int  g_lossStreak       = 0;
long g_recoveryUntilMsc = 0;

PosMeta g_pos[MAX_POS];
int     g_posN = 0;

double g_pnl[PNL_MAX];
int    g_pnlN = 0;

ENUM_ENGINE_STATE g_engine     = ENG_RUN;
double            g_dayStartEq = 0.0;
double            g_peakEq     = 0.0;
int               g_dayKey     = -1;
bool              g_dayBlocked = false;

int g_hLog = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
string GVBase()
{
   return "X13_" + (string)InpMagic + "_" + _Symbol + "_";
}

string CellGV(const int cell, const string k)
{
   return GVBase() + k + (string)cell;
}

string PosGV(const long ident, const string k)
{
   return GVBase() + "P" + (string)ident + "_" + k;
}

int CellIdx(const int fam, const int reg)
{
   return fam * REG_N + reg;
}

int VolDigits()
{
   return (int)MathRound(-MathLog10(g_volStep));
}

double NormVolDown(const double v)
{
   double x = MathFloor(v / g_volStep + 1e-9) * g_volStep;
   if(x > g_volMax) x = g_volMax;
   return NormalizeDouble(x, VolDigits());
}

string FamName(const int f)
{
   switch(f)
   {
      case FAM_MICRO:    return "MM";
      case FAM_BREAKOUT: return "BO";
      case FAM_PULLBACK: return "PB";
      case FAM_CANDLE:   return "CR";
      case FAM_MEANREV:  return "MR";
      case FAM_RELEASE:  return "RL";
      case FAM_SWEEP:    return "LS";
      case FAM_EXHAUST:  return "EX";
   }
   return "NA";
}

string RegName(const int r)
{
   switch(r)
   {
      case REG_TREND:       return "TREND";
      case REG_RANGE:       return "RANGE";
      case REG_COMPRESSION: return "COMP";
      case REG_EXPANSION:   return "EXPAN";
      case REG_LOWVOL:      return "LOWVOL";
      case REG_CHAOS:       return "CHAOS";
   }
   return "UNK";
}

string SesName(const int s)
{
   switch(s)
   {
      case SES_ASIA:   return "ASIA";
      case SES_LONDON: return "LONDON";
      case SES_NY:     return "NY";
   }
   return "OFF";
}

// Comment format: X13|<family>|<candidate id>
int FamFromComment(const string cmt)
{
   const int p1 = StringFind(cmt, "|");
   if(p1 < 0) return -1;
   const int p2 = StringFind(cmt, "|", p1 + 1);
   if(p2 < 0) return -1;
   const string code = StringSubstr(cmt, p1 + 1, p2 - p1 - 1);
   for(int f = 0; f < FAM_N; f++)
      if(code == FamName(f)) return f;
   return -1;
}

bool IsOurPosition()
{
   return (PositionGetInteger(POSITION_MAGIC) == (long)InpMagic) &&
          (PositionGetString(POSITION_SYMBOL) == _Symbol);
}

string Stamp()
{
   return TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
}

void Journal(const string line)
{
   if(g_hLog != INVALID_HANDLE) FileWriteString(g_hLog, line + "\r\n");
}

//+------------------------------------------------------------------+
//| 03 Tick memory                                                   |
//+------------------------------------------------------------------+
void PushTick(const double mid, const long msc)
{
   g_tMsc[g_tHead] = msc;
   g_tMid[g_tHead] = mid;
   g_tHead = (g_tHead + 1) % TICK_BUF;
   if(g_tCount < TICK_BUF) g_tCount++;
}

// k = 1 is the newest stored sample
int TickIdx(const int k)
{
   return (g_tHead - k + TICK_BUF) % TICK_BUF;
}

bool MidAtOrBefore(const long targetMsc, double &mid)
{
   for(int k = 1; k <= g_tCount; k++)
   {
      const int i = TickIdx(k);
      if(g_tMsc[i] <= targetMsc)
      {
         mid = g_tMid[i];
         return true;
      }
   }
   return false;
}

int TicksWithin(const long nowMsc, const long winMs)
{
   int n = 0;
   for(int k = 1; k <= g_tCount; k++)
   {
      if(g_tMsc[TickIdx(k)] < nowMsc - winMs) break;
      n++;
   }
   return n;
}

// Move over a time window, in ATR units
double MoveATR(const double mid, const long nowMsc, const long winMs)
{
   double then = 0.0;
   if(g_ctx.atr <= 0.0) return 0.0;
   if(!MidAtOrBefore(nowMsc - winMs, then)) return 0.0;
   return (mid - then) / g_ctx.atr;
}

//+------------------------------------------------------------------+
//| 02, 05 Validation before storage                                 |
//+------------------------------------------------------------------+
bool ValidateTick(const MqlTick &t, const double mid)
{
   g_qualityWhy = "";
   if(t.bid <= 0.0 || t.ask <= 0.0) { g_qualityWhy = "zero price"; return false; }
   if(t.ask < t.bid)                { g_qualityWhy = "crossed quote"; return false; }

   if(t.time_msc > 0 && ((long)TimeCurrent() * 1000 - t.time_msc) > InpStaleTickMs)
   {
      g_qualityWhy = "stale tick";
      return false;
   }

   if(g_tCount > 0 && g_ctx.atr > 0.0 && MathAbs(mid - g_tMid[TickIdx(1)]) > 20.0 * g_ctx.atr)
   {
      // A real gap would otherwise block the buffer forever: accept after 5 consecutive jumps
      g_jumpCount++;
      if(g_jumpCount < 5)
      {
         g_qualityWhy = "price jump";
         return false;
      }
      g_tCount = 0;
   }
   g_jumpCount = 0;
   return true;
}

//+------------------------------------------------------------------+
//| 06 Tick intelligence                                             |
//+------------------------------------------------------------------+
void UpdateTickFeatures(const double mid)
{
   g_tf.m50   = MoveATR(mid, g_nowMsc, 50);
   g_tf.m100  = MoveATR(mid, g_nowMsc, 100);
   g_tf.m250  = MoveATR(mid, g_nowMsc, 250);
   g_tf.m1000 = MoveATR(mid, g_nowMsc, 1000);
   g_tf.tps1  = TicksWithin(g_nowMsc, 1000);
   g_tf.accel = g_tf.m100 - g_tf.m250 / 2.5;   // recent speed against the 250 ms average speed
   const double s = (g_tf.m1000 >= 0.0) ? 1.0 : -1.0;
   g_tf.stall = (MathAbs(g_tf.m1000) >= InpExhaustImpulse) && (g_tf.m250 * s <= InpExhaustStall);
}

//+------------------------------------------------------------------+
//| 07 Candle intelligence                                           |
//+------------------------------------------------------------------+
int CandleScoreOHLC(const double o, const double h, const double l, const double c,
                    const double po, const double pc)
{
   const double range = h - l;
   if(range <= 0.0) return 0;

   const double body  = MathAbs(c - o);
   const double upper = h - MathMax(o, c);
   const double lower = MathMin(o, c) - l;
   const double pBody = MathAbs(pc - po);

   const bool bull  = (c > o);
   const bool bear  = (c < o);
   const bool pBull = (pc > po);
   const bool pBear = (pc < po);

   int s = 0;
   if(lower >= 0.6 * range && body <= 0.35 * range) s++;                         // hammer
   if(upper >= 0.6 * range && body <= 0.35 * range) s--;                         // shooting star
   if(bull && pBear && body > pBody && c >= po && o <= pc) s++;                  // bullish engulfing
   if(bear && pBull && body > pBody && c <= po && o >= pc) s--;                  // bearish engulfing
   if(body >= 0.8 * range) s += bull ? 1 : (bear ? -1 : 0);                      // marubozu
   return s;
}

// Closed-bar score: single-bar and engulfing patterns, morning/evening star, three soldiers and crows
int ClosedCandleScore(const MqlRates &r[])
{
   int s = CandleScoreOHLC(r[1].open, r[1].high, r[1].low, r[1].close, r[2].open, r[2].close);

   const double rng2 = r[2].high - r[2].low;
   const double rng3 = r[3].high - r[3].low;
   if(rng2 > 0.0 && rng3 > 0.0)
   {
      const bool   bear3  = (r[3].open - r[3].close) >= 0.6 * rng3;
      const bool   bull3  = (r[3].close - r[3].open) >= 0.6 * rng3;
      const bool   small2 = MathAbs(r[2].close - r[2].open) <= 0.3 * rng2;
      const double mid3   = 0.5 * (r[3].open + r[3].close);
      if(bear3 && small2 && r[1].close > r[1].open && r[1].close > mid3) s++;   // morning star
      if(bull3 && small2 && r[1].close < r[1].open && r[1].close < mid3) s--;   // evening star
   }

   const bool soldiers = (r[1].close > r[1].open) && (r[2].close > r[2].open) && (r[3].close > r[3].open) &&
                         (r[1].close > r[2].close) && (r[2].close > r[3].close);
   const bool crows    = (r[1].close < r[1].open) && (r[2].close < r[2].open) && (r[3].close < r[3].open) &&
                         (r[1].close < r[2].close) && (r[2].close < r[3].close);
   if(soldiers) s++;
   if(crows)    s--;
   return s;
}

// Forming candle: its own features, weighted later by how far it has progressed
void UpdateLiveCandle()
{
   const datetime t0 = iTime(_Symbol, PERIOD_M1, 0);
   const double o = iOpen(_Symbol, PERIOD_M1, 0);
   const double h = iHigh(_Symbol, PERIOD_M1, 0);
   const double l = iLow(_Symbol, PERIOD_M1, 0);
   const double c = iClose(_Symbol, PERIOD_M1, 0);
   g_ctx.liveProgress = MathMin(1.0, (double)(TimeCurrent() - t0) / 60.0);
   g_ctx.candleLive   = CandleScoreOHLC(o, h, l, c, g_ctx.prevO, g_ctx.prevC);
}

//+------------------------------------------------------------------+
//| 08, 12 Structure helpers and session                             |
//+------------------------------------------------------------------+
bool IsSwingHigh(const MqlRates &r[], const int i)
{
   return r[i].high > r[i - 1].high && r[i].high > r[i - 2].high &&
          r[i].high > r[i + 1].high && r[i].high > r[i + 2].high;
}

bool IsSwingLow(const MqlRates &r[], const int i)
{
   return r[i].low < r[i - 1].low && r[i].low < r[i - 2].low &&
          r[i].low < r[i + 1].low && r[i].low < r[i + 2].low;
}

int SessionOf(const int hour)
{
   if(hour < InpAsiaEndH)   return SES_ASIA;
   if(hour < InpLondonEndH) return SES_LONDON;
   if(hour < InpNYEndH)     return SES_NY;
   return SES_OFF;
}

bool TradeHourOK()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.hour >= InpTradeStartH && dt.hour < InpTradeEndH);
}

//+------------------------------------------------------------------+
//| 08, 09, 10, 11, 12, 13 Context refresh on each closed M1 bar     |
//+------------------------------------------------------------------+
void RefreshContext()
{
   g_ctx.ready = false;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_M1, 0, 160, r) < 110) return;

   MqlRates h1[];
   ArraySetAsSeries(h1, true);
   if(CopyRates(_Symbol, PERIOD_H1, 0, 2, h1) < 2) return;

   double atr[], emaF[], emaS[], emaH1[], emaM5[], emaM15[];
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(emaF, true);
   ArraySetAsSeries(emaS, true);
   ArraySetAsSeries(emaH1, true);
   ArraySetAsSeries(emaM5, true);
   ArraySetAsSeries(emaM15, true);
   if(CopyBuffer(g_hATR,    0, 0, 60, atr)    < 60) return;
   if(CopyBuffer(g_hEMAf,   0, 0, 8,  emaF)   < 8)  return;
   if(CopyBuffer(g_hEMAs,   0, 0, 2,  emaS)   < 2)  return;
   if(CopyBuffer(g_hEMAh1,  0, 0, 2,  emaH1)  < 2)  return;
   if(CopyBuffer(g_hEMAm5,  0, 0, 2,  emaM5)  < 2)  return;
   if(CopyBuffer(g_hEMAm15, 0, 0, 2,  emaM15) < 2)  return;

   const double a = atr[1];
   if(a <= 0.0) return;

   double avg = 0.0;
   for(int i = 1; i <= 50; i++) avg += atr[i];
   avg /= 50.0;

   // Realised volatility over 20 closed bars, in ATR units
   double sumR = 0.0, sumSq = 0.0;
   for(int i = 1; i <= 20; i++)
   {
      const double ret = r[i].close - r[i + 1].close;
      sumR  += ret;
      sumSq += ret * ret;
   }
   const double meanR = sumR / 20.0;
   double var = sumSq / 20.0 - meanR * meanR;
   if(var < 0.0) var = 0.0;

   g_prevRegime = g_ctx.regime;
   g_ctx.atr       = a;
   g_ctx.atrRatio  = (avg > 0.0) ? a / avg : 1.0;
   g_ctx.realVol   = MathSqrt(var) / a;
   g_ctx.emaF      = emaF[1];
   g_ctx.emaS      = emaS[1];
   g_ctx.slope     = (emaF[1] - emaF[6]) / a;
   g_ctx.trendStr  = MathAbs(emaF[1] - emaS[1]) / a;
   g_ctx.barRange  = (r[1].high - r[1].low) / a;

   // Regime, unknown when evidence conflicts
   if(g_ctx.atrRatio >= 2.5 || g_ctx.realVol >= 2.0)                     g_ctx.regime = REG_CHAOS;
   else if(g_ctx.atrRatio >= 1.4 && g_ctx.barRange >= 1.0)               g_ctx.regime = REG_EXPANSION;
   else if(g_ctx.atrRatio <= 0.40)                                       g_ctx.regime = REG_LOWVOL;
   else if(g_ctx.atrRatio <= 0.65)                                       g_ctx.regime = REG_COMPRESSION;
   else if(g_ctx.trendStr >= 0.60 && MathAbs(g_ctx.slope) >= 0.02)       g_ctx.regime = REG_TREND;
   else if(g_ctx.trendStr <= 0.20)                                       g_ctx.regime = REG_RANGE;
   else                                                                  g_ctx.regime = REG_UNKNOWN;

   // Multi-timeframe bias: one vote per timeframe, sum in [-4, +4]
   g_ctx.h1Bias = (h1[1].close > emaH1[1]) ? 1 : -1;
   int mtf = 0;
   mtf += (iClose(_Symbol, PERIOD_M1,  1) > emaF[1])   ? 1 : -1;
   mtf += (iClose(_Symbol, PERIOD_M5,  1) > emaM5[1])  ? 1 : -1;
   mtf += (iClose(_Symbol, PERIOD_M15, 1) > emaM15[1]) ? 1 : -1;
   mtf += g_ctx.h1Bias;
   g_ctx.mtfScore = mtf;

   // Structure: two most recent confirmed fractal swings on each side
   int nh = 0, nl = 0;
   double hi[2], lo[2];
   for(int i = 3; i <= 100 && (nh < 2 || nl < 2); i++)
   {
      if(nh < 2 && IsSwingHigh(r, i)) { hi[nh] = r[i].high; nh++; }
      if(nl < 2 && IsSwingLow(r, i))  { lo[nl] = r[i].low;  nl++; }
   }
   if(nh < 2 || nl < 2) return;

   g_ctx.swHi0 = hi[0];
   g_ctx.swHi1 = hi[1];
   g_ctx.swLo0 = lo[0];
   g_ctx.swLo1 = lo[1];

   if(hi[0] > hi[1] && lo[0] > lo[1])       g_ctx.structBias = 1;
   else if(hi[0] < hi[1] && lo[0] < lo[1])  g_ctx.structBias = -1;
   else                                     g_ctx.structBias = 0;

   g_ctx.bosUp     = (r[1].close > hi[0]) && (r[2].close <= hi[0]);
   g_ctx.bosDn     = (r[1].close < lo[0]) && (r[2].close >= lo[0]);
   g_ctx.chochUp   = g_ctx.bosUp && (g_ctx.structBias < 0);
   g_ctx.chochDn   = g_ctx.bosDn && (g_ctx.structBias > 0);
   g_ctx.sweepUp   = (r[1].high > hi[0]) && (r[1].close < hi[0]);
   g_ctx.sweepDown = (r[1].low < lo[0])  && (r[1].close > lo[0]);

   g_ctx.candleClosed = ClosedCandleScore(r);
   g_ctx.prevO = r[1].open;
   g_ctx.prevC = r[1].close;

   // Spread widening against its own 50-bar history
   double sp = 0.0;
   for(int i = 1; i <= 50; i++) sp += (double)r[i].spread;
   sp /= 50.0;
   const double curSp = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / g_point;
   g_ctx.spreadRatio = (sp > 0.0) ? curSp / sp : 1.0;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_ctx.session   = SessionOf(dt.hour);
   g_ctx.inSession = TradeHourOK();
   g_ctx.ready     = true;
}

//+------------------------------------------------------------------+
//| 17 Probability engine: Beta posterior per cell                   |
//+------------------------------------------------------------------+
void CellPosterior(const int cell, double &mean, double &lower, double &n)
{
   const double pa = InpPriorWinRate * InpPriorStrength;
   const double pb = (1.0 - InpPriorWinRate) * InpPriorStrength;
   const double a  = g_cellW[cell] + pa;
   const double b  = g_cellL[cell] + pb;
   const double s  = a + b;
   mean  = a / s;
   const double sd = MathSqrt(a * b / (s * s * (s + 1.0)));
   lower = mean - InpZLower * sd;
   n     = g_cellW[cell] + g_cellL[cell];
}

// Dedup keeps every contributing family: take the best mean and the best lower bound
void MaskPosterior(const int mask, const int reg, double &mean, double &lower, double &n)
{
   mean  = 0.0;
   lower = -1.0;
   n     = 0.0;
   for(int f = 0; f < FAM_N; f++)
   {
      if((mask & (1 << f)) == 0) continue;
      double m = 0.0, lo = 0.0, k = 0.0;
      CellPosterior(CellIdx(f, reg), m, lo, k);
      if(m > mean) mean = m;
      if(lo > lower) { lower = lo; n = k; }
   }
}

double PrelimScore(const int mask, const int reg, const double slD, const double tpD)
{
   double m = 0.0, lo = 0.0, n = 0.0;
   MaskPosterior(mask, reg, m, lo, n);
   return m * tpD - (1.0 - m) * slD;
}

//+------------------------------------------------------------------+
//| 14, 15, 16 Opportunity generation, lifecycle and dedup           |
//+------------------------------------------------------------------+
void ExpireCandidates()
{
   for(int c = 0; c < MAX_CAND; c++)
   {
      if(!g_cand[c].active) continue;
      if(g_cand[c].expireMsc < g_nowMsc)
      {
         g_cand[c].active = false;
         g_cand[c].state  = OPP_EXPIRED;
         Journal(Stamp() + ",EXP," + (string)g_cand[c].id + "," + FamName(g_cand[c].fam) + ",-,ttl");
      }
   }
}

void Propose(const int fam, const int dir, const int evidence)
{
   if(evidence < InpMinEvidence) return;
   if(g_nowMsc < g_famCooldownMsc[fam]) return;

   const double entry = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const int    reg   = (int)g_ctx.regime;

   for(int c = 0; c < MAX_CAND; c++)
   {
      if(!g_cand[c].active || g_cand[c].dir != dir) continue;
      if(MathAbs(g_cand[c].entry - entry) > 0.5 * g_ctx.atr) continue;

      g_cand[c].famMask   |= (1 << fam);
      if(evidence > g_cand[c].evidence) g_cand[c].evidence = evidence;
      g_cand[c].prelim     = PrelimScore(g_cand[c].famMask, g_cand[c].regime, g_cand[c].slDist, g_cand[c].tpDist);
      g_cand[c].expireMsc  = g_nowMsc + InpCandidateTTLms;
      Journal(Stamp() + ",MRG," + (string)g_cand[c].id + "," + FamName(fam) + "," + (dir > 0 ? "BUY" : "SELL") +
              ",mask=" + (string)g_cand[c].famMask);
      return;
   }

   for(int c = 0; c < MAX_CAND; c++)
   {
      if(g_cand[c].active) continue;

      g_cand[c].active    = true;
      g_cand[c].state     = OPP_DETECTED;
      g_cand[c].famMask   = (1 << fam);
      g_cand[c].fam       = fam;
      g_cand[c].dir       = dir;
      g_cand[c].regime    = reg;
      g_cand[c].session   = g_ctx.session;
      g_cand[c].evidence  = evidence;
      g_cand[c].entry     = entry;
      g_cand[c].slDist    = InpSL_ATR * g_ctx.atr;
      g_cand[c].tpDist    = InpTP_ATR * g_ctx.atr;
      g_cand[c].prelim    = PrelimScore(g_cand[c].famMask, reg, g_cand[c].slDist, g_cand[c].tpDist);
      g_cand[c].expireMsc = g_nowMsc + InpCandidateTTLms;
      g_cand[c].id        = ++g_candSeq;

      Journal(Stamp() + ",NEW," + (string)g_cand[c].id + "," + FamName(fam) + "," + (dir > 0 ? "BUY" : "SELL") +
              ",ev=" + (string)evidence + ";reg=" + RegName(reg) + ";e=" + DoubleToString(entry, g_digits));
      return;
   }
}

// Families fire on triggers; each firing family adds its evidence to the shared context evidence
void GenerateCandidates(const double mid)
{
   if(!g_ctx.ready || g_ctx.atr <= 0.0) return;

   const double a         = g_ctx.atr;
   const bool   liveOK    = (g_ctx.liveProgress >= 0.3);
   const int    barDir    = (g_ctx.prevC > g_ctx.prevO) ? 1 : ((g_ctx.prevC < g_ctx.prevO) ? -1 : 0);
   const int    impulseDir = (g_tf.m1000 >= 0.0) ? 1 : -1;

   for(int k = 0; k < 2; k++)
   {
      const int dir = (k == 0) ? DIR_BUY : DIR_SELL;

      int ctxEv = 0;
      if(g_ctx.inSession)                ctxEv++;
      if(g_ctx.h1Bias * dir > 0)         ctxEv++;
      if(g_ctx.mtfScore * dir > 0)       ctxEv++;
      if(g_ctx.candleClosed * dir > 0)   ctxEv++;
      if(g_tf.m250 * dir > 0.0)          ctxEv++;

      // Closed candle, or forming candle once it has progressed
      const bool candleAgree = (g_ctx.candleClosed * dir > 0) ||
                               (liveOK && g_ctx.candleLive * dir > 0);

      bool trig[FAM_N];
      for(int f = 0; f < FAM_N; f++) trig[f] = false;

      trig[FAM_MICRO] = (g_ctx.regime != REG_CHAOS) && (g_tf.tps1 >= InpMMMinTicks1s) &&
                        (g_tf.m250 * dir >= InpMMMove250) && (g_tf.m1000 * dir >= InpMMMove1000) &&
                        (g_tf.accel * dir > 0.0);

      if(dir > 0)
      {
         const double dist = mid - g_ctx.swHi0;
         trig[FAM_BREAKOUT] = g_ctx.bosUp && (g_ctx.structBias >= 0) && (dist >= 0.0) &&
                              (dist <= InpBreakoutFresh * a) && (g_ctx.regime != REG_CHAOS);
         trig[FAM_CANDLE]   = candleAgree && (MathAbs(mid - g_ctx.swLo0) <= 0.5 * a);
         trig[FAM_SWEEP]    = g_ctx.sweepDown && candleAgree;
      }
      else
      {
         const double dist = g_ctx.swLo0 - mid;
         trig[FAM_BREAKOUT] = g_ctx.bosDn && (g_ctx.structBias <= 0) && (dist >= 0.0) &&
                              (dist <= InpBreakoutFresh * a) && (g_ctx.regime != REG_CHAOS);
         trig[FAM_CANDLE]   = candleAgree && (MathAbs(mid - g_ctx.swHi0) <= 0.5 * a);
         trig[FAM_SWEEP]    = g_ctx.sweepUp && candleAgree;
      }

      trig[FAM_PULLBACK] = (g_ctx.regime == REG_TREND) && (g_ctx.h1Bias * dir > 0) &&
                           (g_ctx.slope * dir > 0.0) && (MathAbs(mid - g_ctx.emaF) <= InpPullbackNear * a) &&
                           candleAgree;

      const double stretch = (mid - g_ctx.emaF) * dir;
      trig[FAM_MEANREV] = (g_ctx.regime == REG_RANGE) && (stretch <= -InpStretch * a) && candleAgree;

      trig[FAM_RELEASE] = (g_ctx.regime == REG_EXPANSION) && (g_prevRegime == REG_COMPRESSION) &&
                          (g_ctx.barRange >= InpReleaseBarRange) && (barDir == dir);

      // Exhaustion fades an impulse that has stalled
      trig[FAM_EXHAUST] = g_tf.stall && (impulseDir * dir < 0) && (g_ctx.regime != REG_CHAOS);

      for(int f = 0; f < FAM_N; f++)
         if(trig[f]) Propose(f, dir, ctxEv + 1);
   }
}

//+------------------------------------------------------------------+
//| 24 Position state, persisted per position identifier             |
//+------------------------------------------------------------------+
int PosFind(const long ident)
{
   for(int i = 0; i < g_posN; i++)
      if(g_pos[i].ident == ident) return i;
   return -1;
}

void PosSave(const int i)
{
   const PosMeta p = g_pos[i];
   GlobalVariableSet(PosGV(p.ident, "R"),    p.initR);
   GlobalVariableSet(PosGV(p.ident, "DIR"),  (double)p.dir);
   GlobalVariableSet(PosGV(p.ident, "MASK"), (double)p.famMask);
   GlobalVariableSet(PosGV(p.ident, "FAM"),  (double)p.fam);
   GlobalVariableSet(PosGV(p.ident, "REG"),  (double)p.regime);
   GlobalVariableSet(PosGV(p.ident, "SES"),  (double)p.session);
   GlobalVariableSet(PosGV(p.ident, "ENT"),  p.entry);
   GlobalVariableSet(PosGV(p.ident, "MFE"),  p.mfeR);
   GlobalVariableSet(PosGV(p.ident, "MAE"),  p.maeR);
   GlobalVariableSet(PosGV(p.ident, "PRED"), p.pred);
   GlobalVariableSet(PosGV(p.ident, "PS"),   (double)p.partialStage);
   GlobalVariableSet(PosGV(p.ident, "BE"),   p.beDone ? 1.0 : 0.0);
   GlobalVariableSet(PosGV(p.ident, "LK"),   p.lockDone ? 1.0 : 0.0);
   GlobalVariableSet(PosGV(p.ident, "OPS"),  (double)p.openSec);
}

bool PosLoad(const long ident, PosMeta &pm)
{
   if(!GlobalVariableCheck(PosGV(ident, "R"))) return false;
   pm.ident        = ident;
   pm.ticket       = 0;
   pm.initR        = GlobalVariableGet(PosGV(ident, "R"));
   pm.dir          = (int)GlobalVariableGet(PosGV(ident, "DIR"));
   pm.famMask      = (int)GlobalVariableGet(PosGV(ident, "MASK"));
   pm.fam          = (int)GlobalVariableGet(PosGV(ident, "FAM"));
   pm.regime       = (int)GlobalVariableGet(PosGV(ident, "REG"));
   pm.session      = (int)GlobalVariableGet(PosGV(ident, "SES"));
   pm.entry        = GlobalVariableGet(PosGV(ident, "ENT"));
   pm.mfeR         = GlobalVariableGet(PosGV(ident, "MFE"));
   pm.maeR         = GlobalVariableGet(PosGV(ident, "MAE"));
   pm.pred         = GlobalVariableGet(PosGV(ident, "PRED"));
   pm.partialStage = (int)GlobalVariableGet(PosGV(ident, "PS"));
   pm.beDone       = (GlobalVariableGet(PosGV(ident, "BE")) > 0.5);
   pm.lockDone     = (GlobalVariableGet(PosGV(ident, "LK")) > 0.5);
   pm.openSec      = (long)GlobalVariableGet(PosGV(ident, "OPS"));
   return true;
}

void PosGVDelAll(const long ident)
{
   string keys[] = {"R", "DIR", "MASK", "FAM", "REG", "SES", "ENT", "MFE", "MAE", "PRED", "PS", "BE", "LK", "OPS"};
   for(int k = 0; k < ArraySize(keys); k++)
   {
      const string nm = PosGV(ident, keys[k]);
      if(GlobalVariableCheck(nm)) GlobalVariableDel(nm);
   }
}

void PosRemoveAt(const int i)
{
   PosGVDelAll(g_pos[i].ident);
   g_pos[i] = g_pos[g_posN - 1];
   g_posN--;
}

// Restores tracked state after a restart, or registers an unknown X13 position with defaults
void AdoptPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk) || !IsOurPosition()) continue;

      const long ident = PositionGetInteger(POSITION_IDENTIFIER);
      if(PosFind(ident) >= 0) continue;
      if(g_posN >= MAX_POS) return;

      PosMeta pm;
      if(PosLoad(ident, pm))
      {
         pm.ticket = tk;
      }
      else
      {
         const int fam = FamFromComment(PositionGetString(POSITION_COMMENT));
         if(fam < 0) continue;

         const double open = PositionGetDouble(POSITION_PRICE_OPEN);
         const double sl   = PositionGetDouble(POSITION_SL);
         pm.ident        = ident;
         pm.ticket       = tk;
         pm.dir          = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? DIR_BUY : DIR_SELL;
         pm.famMask      = (1 << fam);
         pm.fam          = fam;
         pm.regime       = (int)g_ctx.regime;
         pm.session      = g_ctx.session;
         pm.entry        = open;
         double r0       = (sl > 0.0) ? MathAbs(open - sl) : 0.0;
         if(r0 < 0.25 * InpSL_ATR * g_ctx.atr) r0 = InpSL_ATR * g_ctx.atr;
         pm.initR        = r0;
         pm.mfeR         = 0.0;
         pm.maeR         = 0.0;
         pm.pred         = 0.5;
         pm.partialStage = 0;
         pm.beDone       = false;
         pm.lockDone     = false;
         pm.openSec      = (long)PositionGetInteger(POSITION_TIME);
      }

      g_pos[g_posN] = pm;
      g_posN++;
      PosSave(g_posN - 1);
   }
}

void RegisterNewPosition(const Candidate &c, const string cmt, const EvalRes &e)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk) || !IsOurPosition()) continue;
      if(PositionGetString(POSITION_COMMENT) != cmt) continue;

      const long ident = PositionGetInteger(POSITION_IDENTIFIER);
      if(PosFind(ident) >= 0) return;
      if(g_posN >= MAX_POS) return;

      PosMeta pm;
      pm.ident        = ident;
      pm.ticket       = tk;
      pm.dir          = c.dir;
      pm.famMask      = c.famMask;
      pm.fam          = c.fam;
      pm.regime       = c.regime;
      pm.session      = c.session;
      pm.entry        = PositionGetDouble(POSITION_PRICE_OPEN);
      pm.initR        = c.slDist;
      pm.mfeR         = 0.0;
      pm.maeR         = 0.0;
      pm.pred         = e.pmean;
      pm.partialStage = 0;
      pm.beDone       = false;
      pm.lockDone     = false;
      pm.openSec      = (long)PositionGetInteger(POSITION_TIME);

      g_pos[g_posN] = pm;
      g_posN++;
      PosSave(g_posN - 1);
      return;
   }
}

//+------------------------------------------------------------------+
//| 20, 23 Exposure, correlation and risk                            |
//+------------------------------------------------------------------+
// Risk money if every live stop were hit (positions without a stop count the full per-trade risk)
double PositionRiskMoney()
{
   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double sum = 0.0;
   for(int i = 0; i < g_posN; i++)
   {
      if(!PositionSelectByTicket(g_pos[i].ticket)) continue;
      const double sl = PositionGetDouble(POSITION_SL);
      if(sl <= 0.0)
      {
         sum += eq * InpRiskPerTradePct / 100.0;
         continue;
      }
      const double open = PositionGetDouble(POSITION_PRICE_OPEN);
      const double vol  = PositionGetDouble(POSITION_VOLUME);
      const ENUM_ORDER_TYPE ot = (g_pos[i].dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double pl = 0.0;
      if(OrderCalcProfit(ot, _Symbol, vol, open, sl, pl) && pl < 0.0) sum += -pl;
   }
   return sum;
}

// Drawdown from peak equity scales risk down, never up
double RiskScale()
{
   if(g_peakEq <= 0.0) return 1.0;
   const double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   const double ddPct = (g_peakEq - eq) / g_peakEq * 100.0;
   const double s     = 1.0 - ddPct / MathMax(0.01, InpDDScalePct);
   return MathMax(InpMinRiskScale, MathMin(1.0, s));
}

// Netting: one position at a time. Hedging: same-side spacing and clustering, opposite side by switch
bool ExposureAllowed(const int dir, const double entry, bool &hedgePair, string &why)
{
   int same = 0, opp = 0, live = 0;
   const long nowS = (long)TimeCurrent();

   for(int i = 0; i < g_posN; i++)
   {
      if(!PositionSelectByTicket(g_pos[i].ticket)) continue;
      live++;
      if(g_pos[i].dir != dir) { opp++; continue; }

      same++;
      if((nowS - g_pos[i].openSec) * 1000 < InpMinSpacingMs)
      {
         why = "spacing";
         return false;
      }
      if(MathAbs(g_pos[i].entry - entry) < InpMinSpacingATR * g_ctx.atr)
      {
         why = "same-side cluster";
         return false;
      }
   }

   if(live >= InpMaxPositions)           { why = "max positions"; return false; }
   if(!g_hedging && live > 0)            { why = "netting: single position"; return false; }
   if(opp > 0 && !InpAllowHedgePairs)    { why = "hedge pairs disabled"; return false; }

   hedgePair = (opp > 0);
   return true;
}

//+------------------------------------------------------------------+
//| 18, 22 Net-edge decision and sizing                              |
//+------------------------------------------------------------------+
bool EvalCandidate(const Candidate &c, const MqlTick &t, EvalRes &e, string &why)
{
   const double entry = (c.dir > 0) ? t.ask : t.bid;
   const double drift = (c.dir > 0) ? (t.ask - c.entry) : (c.entry - t.bid);
   if(drift > InpMaxEntryDevATR * g_ctx.atr)
   {
      why = "entry drift";
      return false;
   }

   const double minD = g_stopsPts * g_point;
   if(c.slDist < minD || c.tpDist < minD)
   {
      why = "stops level";
      return false;
   }

   const double sl = NormalizeDouble(entry - c.dir * c.slDist, g_digits);
   const double tp = NormalizeDouble(entry + c.dir * c.tpDist, g_digits);

   // Account-currency loss and gain per lot, from the broker's own calculator
   const ENUM_ORDER_TYPE ot = (c.dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double pl = 0.0, pg = 0.0;
   if(!OrderCalcProfit(ot, _Symbol, 1.0, entry, sl, pl) || pl >= 0.0) { why = "loss calc"; return false; }
   if(!OrderCalcProfit(ot, _Symbol, 1.0, entry, tp, pg) || pg <= 0.0) { why = "gain calc"; return false; }
   const double lossLot = -pl;
   const double gainLot = pg;
   const double costLot = ((t.ask - t.bid) + InpSlipBufferPts * g_point) / g_tickSize * g_tickValue + InpCommPerLot;

   double pmean = 0.0, plow = 0.0, n = 0.0;
   MaskPosterior(c.famMask, c.regime, pmean, plow, n);

   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double scale = RiskScale();
   if(n < InpMinCellN) scale *= InpProbationMult;

   const double riskMoney = equity * InpRiskPerTradePct / 100.0 * scale;
   const double lot = NormVolDown(riskMoney / lossLot);
   if(lot < g_volMin)
   {
      why = "lot below minimum";
      return false;
   }

   e.lot   = lot;
   e.risk  = lot * lossLot;
   e.gain  = lot * gainLot;
   e.costs = lot * costLot;
   e.pmean = pmean;
   e.plow  = plow;
   e.pbe   = (e.risk + e.costs) / (e.gain + e.risk);

   // Gate on the lower confidence bound, not on the mean
   if(e.plow < e.pbe)
   {
      why = "lower bound below breakeven";
      return false;
   }

   e.ev  = pmean * e.gain - (1.0 - pmean) * e.risk - e.costs;
   e.evr = e.ev / e.risk;
   if(e.evr < InpMinEVPerRisk)
   {
      why = "net EV " + DoubleToString(e.evr, 3);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| 21 Execution                                                     |
//+------------------------------------------------------------------+
bool TryExecute(const Candidate &c, const MqlTick &t, string &why)
{
   bool hedgePair = false;
   if(!ExposureAllowed(c.dir, (c.dir > 0) ? t.ask : t.bid, hedgePair, why)) return false;

   EvalRes e;
   if(!EvalCandidate(c, t, e, why)) return false;

   if(hedgePair && e.evr < 2.0 * InpMinEVPerRisk)
   {
      why = "hedge needs stronger edge";
      return false;
   }

   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(PositionRiskMoney() + e.risk > equity * InpMaxOpenRiskPct / 100.0)
   {
      why = "open risk cap";
      return false;
   }

   const double entry0 = (c.dir > 0) ? t.ask : t.bid;
   double margin = 0.0;
   const ENUM_ORDER_TYPE ot = (c.dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcMargin(ot, _Symbol, e.lot, entry0, margin))
   {
      why = "margin calc";
      return false;
   }
   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < margin * InpMinMarginMult)
   {
      why = "free margin";
      return false;
   }

   const double sl = NormalizeDouble(entry0 - c.dir * c.slDist, g_digits);
   const double tp = NormalizeDouble(entry0 + c.dir * c.tpDist, g_digits);
   const string cmt = "X13|" + FamName(c.fam) + "|" + (string)c.id;

   const ulong t0 = GetTickCount64();
   const bool ok = (c.dir > 0) ? g_trade.Buy(e.lot, _Symbol, 0.0, sl, tp, cmt)
                               : g_trade.Sell(e.lot, _Symbol, 0.0, sl, tp, cmt);
   const uint  rc      = g_trade.ResultRetcode();
   const ulong latency = GetTickCount64() - t0;

   if(!ok || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED))
   {
      why = "retcode " + (string)rc;
      return false;
   }

   RegisterNewPosition(c, cmt, e);
   Journal(Stamp() + ",OPEN," + (string)c.id + "," + FamName(c.fam) + "," + (c.dir > 0 ? "BUY" : "SELL") +
           ",lot=" + DoubleToString(e.lot, VolDigits()) +
           ";e=" + DoubleToString(entry0, g_digits) +
           ";sl=" + DoubleToString(sl, g_digits) +
           ";tp=" + DoubleToString(tp, g_digits) +
           ";pm=" + DoubleToString(e.pmean, 3) +
           ";plow=" + DoubleToString(e.plow, 3) +
           ";evr=" + DoubleToString(e.evr, 3) +
           ";lat=" + (string)latency + "ms");
   return true;
}

//+------------------------------------------------------------------+
//| 25, 26, 27 Position management                                   |
//+------------------------------------------------------------------+
bool Improves(const int dir, const double curSL, const double newSL, const double minStep)
{
   if(curSL <= 0.0) return true;
   return (dir > 0) ? (newSL > curSL + minStep) : (newSL < curSL - minStep);
}

bool StopsOK(const int dir, const double sl, const double price)
{
   const double minD = g_stopsPts * g_point;
   return (dir > 0) ? (price - sl >= minD) : (sl - price >= minD);
}

bool ModifySL(const ulong tk, const double sl, const double tp)
{
   return g_trade.PositionModify(tk, NormalizeDouble(sl, g_digits), tp);
}

bool CloseByTicket(const ulong tk, const string why)
{
   const bool ok = g_trade.PositionClose(tk);
   Journal(Stamp() + ",EXIT," + (string)tk + ",-,-," + why + ";rc=" + (string)g_trade.ResultRetcode());
   return ok;
}

void ManagePositions(const double mid)
{
   const double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double m250 = MoveATR(mid, g_nowMsc, 250);
   const long   nowS = (long)TimeCurrent();

   for(int i = g_posN - 1; i >= 0; i--)
   {
      PosMeta p = g_pos[i];
      if(!PositionSelectByTicket(p.ticket) || !IsOurPosition()) continue;
      if(p.initR <= 0.0 || g_ctx.atr <= 0.0) continue;

      const double sl     = PositionGetDouble(POSITION_SL);
      const double tp     = PositionGetDouble(POSITION_TP);
      const double vol    = PositionGetDouble(POSITION_VOLUME);
      const double pnl    = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      const double cur    = (p.dir > 0) ? bid : ask;
      const double rMult  = (cur - p.entry) * p.dir / p.initR;

      if(rMult > p.mfeR) p.mfeR = rMult;
      if(rMult < p.maeR) p.maeR = rMult;

      bool changed = false;
      bool acted   = false;

      // Two-stage partial targets; the stage advances only after the broker confirms the close
      if(!acted && InpUsePartial && p.partialStage < 1 && rMult >= InpPartialR)
      {
         const double cv = NormVolDown(vol * InpPartialPct / 100.0);
         if(cv >= g_volMin && (vol - cv) >= g_volMin)
         {
            const bool ok = g_trade.PositionClosePartial(p.ticket, cv);
            if(ok && g_trade.ResultRetcode() == TRADE_RETCODE_DONE) { p.partialStage = 1; changed = true; }
         }
         else { p.partialStage = 1; changed = true; }
         acted = true;
      }
      if(!acted && InpUsePartial && p.partialStage < 2 && rMult >= InpPartial2R)
      {
         const double cv = NormVolDown(vol * InpPartial2Pct / 100.0);
         if(cv >= g_volMin && (vol - cv) >= g_volMin)
         {
            const bool ok = g_trade.PositionClosePartial(p.ticket, cv);
            if(ok && g_trade.ResultRetcode() == TRADE_RETCODE_DONE) { p.partialStage = 2; changed = true; }
         }
         else { p.partialStage = 2; changed = true; }
         acted = true;
      }

      // Break-even
      if(!acted && !p.beDone && rMult >= InpBE_TriggerR)
      {
         const double be = NormalizeDouble(p.entry + p.dir * (ask - bid), g_digits);
         if(!Improves(p.dir, sl, be, g_point)) { p.beDone = true; changed = true; }
         else if(StopsOK(p.dir, be, cur) && ModifySL(p.ticket, be, tp)) { p.beDone = true; changed = true; }
         acted = true;
      }

      // Profit lock: a fixed share of R is banked once the trade reaches the lock trigger
      if(!acted && !p.lockDone && rMult >= InpLockR)
      {
         const double lk = NormalizeDouble(p.entry + p.dir * InpLockFracR * p.initR, g_digits);
         if(!Improves(p.dir, sl, lk, g_point)) { p.lockDone = true; changed = true; }
         else if(StopsOK(p.dir, lk, cur) && ModifySL(p.ticket, lk, tp)) { p.lockDone = true; changed = true; }
         acted = true;
      }

      // ATR trailing, only after the lock, with a minimum step to limit modifications
      if(!acted && p.lockDone)
      {
         const double tsl = NormalizeDouble(cur - p.dir * InpTrail_ATR * g_ctx.atr, g_digits);
         if(Improves(p.dir, sl, tsl, 0.05 * g_ctx.atr) && StopsOK(p.dir, tsl, cur))
            ModifySL(p.ticket, tsl, tp);
      }

      // Structure exit: a confirmed change of character against a trade that is already in profit
      if(!acted && rMult > 0.2 && ((p.dir > 0 && g_ctx.chochDn) || (p.dir < 0 && g_ctx.chochUp)))
      {
         CloseByTicket(p.ticket, "choch exit");
         acted = true;
      }

      // Time stop for trades that are not winning
      if(!acted && pnl <= 0.0 && (nowS - p.openSec) >= (long)InpMaxHoldMin * 60)
      {
         CloseByTicket(p.ticket, "time stop");
         acted = true;
      }

      // Decay exit: a winner whose short-term momentum has reversed sharply
      if(!acted && rMult > 0.3 && m250 * p.dir <= -InpDecayExit)
      {
         CloseByTicket(p.ticket, "decay exit");
         acted = true;
      }

      g_pos[i] = p;
      if(changed) PosSave(i);
   }
}

//+------------------------------------------------------------------+
//| 28 Basket protection                                             |
//+------------------------------------------------------------------+
void CheckBasket()
{
   double buyF = 0.0, sellF = 0.0;
   int n = 0;
   for(int i = 0; i < g_posN; i++)
   {
      if(!PositionSelectByTicket(g_pos[i].ticket)) continue;
      const double f = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(g_pos[i].dir > 0) buyF += f; else sellF += f;
      n++;
   }
   if(n == 0) return;

   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(buyF + sellF <= -eq * InpBasketEmergPct / 100.0)
   {
      for(int i = 0; i < g_posN; i++)
         if(PositionSelectByTicket(g_pos[i].ticket)) CloseByTicket(g_pos[i].ticket, "basket emergency");
      g_engine = ENG_PROTECT;
      Print("X13: basket emergency. Buy floating ", DoubleToString(buyF, 2),
            " Sell floating ", DoubleToString(sellF, 2));
   }
}

//+------------------------------------------------------------------+
//| 29, 30, 31 Outcomes, attribution and health                      |
//+------------------------------------------------------------------+
double DealsTotalForPosition(const long ident)
{
   double sum = 0.0;
   if(!HistorySelectByPosition(ident)) return 0.0;
   const int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
   {
      const ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      sum += HistoryDealGetDouble(d, DEAL_PROFIT)
           + HistoryDealGetDouble(d, DEAL_SWAP)
           + HistoryDealGetDouble(d, DEAL_COMMISSION);
   }
   return sum;
}

void RecordOutcome(const PosMeta &p, const double pnl)
{
   const bool win = (pnl > 0.0);

   // Every family in the merged mask records the outcome for its own cell
   for(int f = 0; f < FAM_N; f++)
   {
      if((p.famMask & (1 << f)) == 0) continue;

      const int cell = CellIdx(f, p.regime);
      if(win) g_cellW[cell] += 1.0; else g_cellL[cell] += 1.0;
      GlobalVariableSet(CellGV(cell, "CW"), g_cellW[cell]);
      GlobalVariableSet(CellGV(cell, "CL"), g_cellL[cell]);

      g_famPnl[f] += pnl;
      g_famN[f]++;

      if(win)
      {
         g_famStreak[f] = 0;
      }
      else if(++g_famStreak[f] >= InpFamilyLossTrigger)
      {
         g_famCooldownMsc[f] = g_nowMsc + (long)InpFamilyCooldownMin * 60000;
         g_famStreak[f]      = 0;
      }
   }

   if(p.regime >= 0 && p.regime < REG_N) { g_regPnl[p.regime] += pnl; g_regN[p.regime]++; }
   if(p.session >= 0 && p.session < SES_N) { g_sesPnl[p.session] += pnl; g_sesN[p.session]++; }

   int b = (int)MathFloor(p.pred * CAL_BINS);
   if(b < 0) b = 0;
   if(b >= CAL_BINS) b = CAL_BINS - 1;
   g_calN[b] += 1.0;
   if(win) g_calW[b] += 1.0;
   g_calP[b] += p.pred;

   if(win)
   {
      g_lossStreak = 0;
   }
   else if(++g_lossStreak >= InpLossStreakLimit)
   {
      g_recoveryUntilMsc = g_nowMsc + (long)InpRecoveryMinutes * 60000;
      g_lossStreak       = 0;
   }

   if(g_pnlN < PNL_MAX) g_pnl[g_pnlN++] = pnl;

   Journal(Stamp() + ",CLOSE," + (string)p.ident + "," + FamName(p.fam) + "," + (p.dir > 0 ? "BUY" : "SELL") +
           ",pnl=" + DoubleToString(pnl, 2) +
           ";mfe=" + DoubleToString(p.mfeR, 2) +
           ";mae=" + DoubleToString(p.maeR, 2) +
           ";reg=" + RegName(p.regime) +
           ";ses=" + SesName(p.session));
}

void SyncClosedPositions()
{
   for(int i = g_posN - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(g_pos[i].ticket)) continue;

      const PosMeta p = g_pos[i];
      const double pnl = DealsTotalForPosition(p.ident);
      RecordOutcome(p, pnl);
      PosRemoveAt(i);
   }
}

//+------------------------------------------------------------------+
//| 01 Day state and entry gates                                     |
//+------------------------------------------------------------------+
void CheckDayReset()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   const int key = dt.year * 1000 + dt.day_of_year;
   if(key == g_dayKey) return;

   g_dayKey     = key;
   g_dayStartEq = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayBlocked = false;
   g_engine     = ENG_RUN;
}

bool DailyLossHit()
{
   if(g_dayStartEq <= 0.0) return false;
   return (AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartEq) <= -g_dayStartEq * InpDailyLossPct / 100.0;
}

bool EntriesAllowed(const MqlTick &t, string &why)
{
   if(!g_qualityOK) { why = g_qualityWhy; return false; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      why = "trading disabled";
      return false;
   }
   if(!TradeHourOK())                       { why = "outside trade hours"; return false; }
   if(g_engine == ENG_PROTECT)              { why = "protect"; return false; }
   if(g_dayBlocked || DailyLossHit())       { g_dayBlocked = true; why = "daily stop"; return false; }
   if(g_nowMsc < g_recoveryUntilMsc)        { why = "recovery pause"; return false; }
   if(g_ctx.spreadRatio > 3.0)              { why = "spread widening"; return false; }
   if((t.ask - t.bid) / g_point > InpMaxSpreadPts) { why = "spread"; return false; }
   return true;
}

//+------------------------------------------------------------------+
//| 19 Priority queue: best first, several executions per tick       |
//+------------------------------------------------------------------+
void ExecuteQueue(const MqlTick &t)
{
   int executed = 0;
   for(int attempt = 0; attempt < MAX_CAND && executed < InpMaxNewPerTick; attempt++)
   {
      int    best      = -1;
      double bestScore = -DBL_MAX;
      for(int c = 0; c < MAX_CAND; c++)
      {
         if(!g_cand[c].active) continue;
         if(g_cand[c].prelim > bestScore)
         {
            bestScore = g_cand[c].prelim;
            best      = c;
         }
      }
      if(best < 0) return;

      string why = "";
      const bool done = TryExecute(g_cand[best], t, why);
      if(done)
      {
         g_cand[best].state = OPP_EXECUTED;
         executed++;
      }
      else
      {
         g_cand[best].state = OPP_REJECTED;
         g_lastReject = why;
         Journal(Stamp() + ",REJ," + (string)g_cand[best].id + "," + FamName(g_cand[best].fam) + "," +
                 (g_cand[best].dir > 0 ? "BUY" : "SELL") + "," + why);
      }
      g_cand[best].active = false;
   }
}

//+------------------------------------------------------------------+
//| Diagnostics: dashboard, attribution, calibration, Monte Carlo    |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   if(!InpDashboard) return;
   if(g_nowMsc - g_lastDashMs < 500) return;
   g_lastDashMs = g_nowMsc;

   const double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   const double risk = (eq > 0.0) ? PositionRiskMoney() / eq * 100.0 : 0.0;
   const double dd   = (g_peakEq > 0.0) ? (g_peakEq - eq) / g_peakEq * 100.0 : 0.0;

   string s = "X13 GLOBAL 2.0  |  " + _Symbol + "\n";
   s += "Regime " + RegName((int)g_ctx.regime) + "   Session " + SesName(g_ctx.session) + "\n";
   s += "Structure " + IntegerToString(g_ctx.structBias) + "   MTF " + IntegerToString(g_ctx.mtfScore) +
        "   H1 " + IntegerToString(g_ctx.h1Bias) + "\n";
   s += "Ticks/s " + IntegerToString(g_tf.tps1) + "   m250 " + DoubleToString(g_tf.m250, 2) +
        "   m1000 " + DoubleToString(g_tf.m1000, 2) + "\n";
   s += "Positions " + IntegerToString(g_posN) + "   Open risk " + DoubleToString(risk, 2) + "%\n";
   s += "Drawdown " + DoubleToString(dd, 2) + "%   Risk scale " + DoubleToString(RiskScale(), 2) + "\n";
   s += "Quality " + (g_qualityOK ? "OK" : g_qualityWhy) + "\n";
   s += "Last reject: " + g_lastReject;
   Comment(s);
}

void PrintDiagnostics()
{
   Print("X13 attribution by family:");
   for(int f = 0; f < FAM_N; f++)
      if(g_famN[f] > 0)
         Print("  ", FamName(f), " trades=", g_famN[f], " pnl=", DoubleToString(g_famPnl[f], 2));

   Print("X13 attribution by regime:");
   for(int r = 0; r < REG_N; r++)
      if(g_regN[r] > 0)
         Print("  ", RegName(r), " trades=", g_regN[r], " pnl=", DoubleToString(g_regPnl[r], 2));

   Print("X13 attribution by session:");
   for(int s = 0; s < SES_N; s++)
      if(g_sesN[s] > 0)
         Print("  ", SesName(s), " trades=", g_sesN[s], " pnl=", DoubleToString(g_sesPnl[s], 2));

   Print("X13 calibration (predicted vs realised win rate):");
   for(int b = 0; b < CAL_BINS; b++)
   {
      if(g_calN[b] <= 0.0) continue;
      Print("  bin ", b, " n=", (int)g_calN[b],
            " predicted=", DoubleToString(g_calP[b] / g_calN[b], 3),
            " realised=", DoubleToString(g_calW[b] / g_calN[b], 3));
   }
}

// Bootstrap of realised trades: distribution of the maximum drawdown
void MonteCarloReport()
{
   if(g_pnlN < 20)
   {
      Print("X13 Monte Carlo skipped: fewer than 20 closed trades");
      return;
   }
   const int paths = 1000;
   double dd[1000];
   MathSrand((uint)GetTickCount());
   for(int p = 0; p < paths; p++)
   {
      double eq = 0.0, peak = 0.0, mdd = 0.0;
      for(int k = 0; k < g_pnlN; k++)
      {
         const long r   = (long)MathRand() * 32768 + MathRand();
         const int  idx = (int)(r % g_pnlN);
         eq += g_pnl[idx];
         if(eq > peak) peak = eq;
         if(peak - eq > mdd) mdd = peak - eq;
      }
      dd[p] = mdd;
   }
   ArraySort(dd);
   Print("X13 Monte Carlo max drawdown (money) p50=", DoubleToString(dd[paths / 2], 2),
         " p95=", DoubleToString(dd[(paths * 95) / 100], 2),
         " from ", g_pnlN, " trades");
}

//+------------------------------------------------------------------+
//| Expert lifecycle                                                 |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpRiskPerTradePct <= 0.0 || InpRiskPerTradePct > 5.0)            return INIT_PARAMETERS_INCORRECT;
   if(InpMaxOpenRiskPct < InpRiskPerTradePct)                           return INIT_PARAMETERS_INCORRECT;
   if(InpTradeStartH < 0 || InpTradeEndH > 24 || InpTradeStartH >= InpTradeEndH) return INIT_PARAMETERS_INCORRECT;
   if(!(InpAsiaEndH <= InpLondonEndH && InpLondonEndH <= InpNYEndH))  return INIT_PARAMETERS_INCORRECT;
   if(InpSL_ATR <= 0.0 || InpTP_ATR <= 0.0)                             return INIT_PARAMETERS_INCORRECT;
   if(InpMaxPositions < 1 || InpMaxNewPerTick < 1)                      return INIT_PARAMETERS_INCORRECT;
   if(InpPriorWinRate <= 0.0 || InpPriorWinRate >= 1.0 || InpPriorStrength <= 0.0) return INIT_PARAMETERS_INCORRECT;

   g_point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   g_volMin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_volMax    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_volStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   g_stopsPts  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(g_point <= 0.0 || g_tickSize <= 0.0 || g_tickValue <= 0.0 || g_volStep <= 0.0 || g_volMin <= 0.0)
   {
      Print("X13: symbol specification unavailable for ", _Symbol);
      return INIT_FAILED;
   }

   const ENUM_ACCOUNT_MARGIN_MODE mm = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   g_hedging = (mm == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);

   const long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK) != 0)      g_filling = ORDER_FILLING_FOK;
   else if((fm & SYMBOL_FILLING_IOC) != 0) g_filling = ORDER_FILLING_IOC;
   else                                    g_filling = ORDER_FILLING_RETURN;

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpDeviationPts);
   g_trade.SetTypeFilling(g_filling);
   g_trade.SetAsyncMode(false);

   g_hATR    = iATR(_Symbol, PERIOD_M1, 14);
   g_hEMAf   = iMA(_Symbol, PERIOD_M1, 20, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMAs   = iMA(_Symbol, PERIOD_M1, 50, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMAh1  = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMAm5  = iMA(_Symbol, PERIOD_M5, 20, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMAm15 = iMA(_Symbol, PERIOD_M15, 20, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hATR == INVALID_HANDLE || g_hEMAf == INVALID_HANDLE || g_hEMAs == INVALID_HANDLE ||
      g_hEMAh1 == INVALID_HANDLE || g_hEMAm5 == INVALID_HANDLE || g_hEMAm15 == INVALID_HANDLE)
   {
      Print("X13: indicator handle creation failed");
      return INIT_FAILED;
   }

   // Restore the persisted win statistics for every family x regime cell
   for(int c = 0; c < CELL_N; c++)
   {
      if(GlobalVariableCheck(CellGV(c, "CW"))) g_cellW[c] = GlobalVariableGet(CellGV(c, "CW"));
      if(GlobalVariableCheck(CellGV(c, "CL"))) g_cellL[c] = GlobalVariableGet(CellGV(c, "CL"));
   }

   if(InpLogging)
   {
      g_hLog = FileOpen("X13_journal_" + _Symbol + ".csv", FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(g_hLog != INVALID_HANDLE)
      {
         FileSeek(g_hLog, 0, SEEK_END);
         if(FileSize(g_hLog) == 0) Journal("time,event,id_or_ticket,family,dir,detail");
      }
   }

   g_peakEq = AccountInfoDouble(ACCOUNT_EQUITY);
   CheckDayReset();
   g_lastM1 = 0;

   Print("X13 2.0 initialised. Hedging=", (string)g_hedging, " Filling=", EnumToString(g_filling),
         " TickSize=", DoubleToString(g_tickSize, g_digits), " VolStep=", DoubleToString(g_volStep, 3));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   PrintDiagnostics();
   MonteCarloReport();

   if(g_hATR    != INVALID_HANDLE) IndicatorRelease(g_hATR);
   if(g_hEMAf   != INVALID_HANDLE) IndicatorRelease(g_hEMAf);
   if(g_hEMAs   != INVALID_HANDLE) IndicatorRelease(g_hEMAs);
   if(g_hEMAh1  != INVALID_HANDLE) IndicatorRelease(g_hEMAh1);
   if(g_hEMAm5  != INVALID_HANDLE) IndicatorRelease(g_hEMAm5);
   if(g_hEMAm15 != INVALID_HANDLE) IndicatorRelease(g_hEMAm15);
   if(g_hLog    != INVALID_HANDLE) FileClose(g_hLog);
   Comment("");
}

void OnTick()
{
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t)) return;

   g_nowMsc = (t.time_msc > 0) ? (long)t.time_msc : (long)TimeCurrent() * 1000;
   const double mid = 0.5 * (t.bid + t.ask);

   CheckDayReset();
   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_peakEq) g_peakEq = eq;

   const datetime m1 = iTime(_Symbol, PERIOD_M1, 0);
   if(m1 != g_lastM1)
   {
      g_lastM1 = m1;
      RefreshContext();
   }
   if(!g_ctx.ready) return;

   // Validate before storage: an invalid tick never reaches the tick memory
   const bool valid = ValidateTick(t, mid);
   if(valid) PushTick(mid, g_nowMsc);
   g_qualityOK = valid;

   UpdateTickFeatures(mid);
   UpdateLiveCandle();
   ExpireCandidates();

   // Position housekeeping runs regardless of the entry gates
   AdoptPositions();
   ManagePositions(mid);
   SyncClosedPositions();
   CheckBasket();
   UpdateDashboard();

   if(!g_qualityOK) return;

   string why = "";
   if(!EntriesAllowed(t, why))
   {
      g_lastReject = why;
      return;
   }

   GenerateCandidates(mid);
   ExecuteQueue(t);
}
//+------------------------------------------------------------------+
