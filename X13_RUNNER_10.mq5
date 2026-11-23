//+------------------------------------------------------------------+
//|                                               X13_RUNNER_10.mq5   |
//|   Trend rider for a $10 XAUUSD account. No fixed target:         |
//|   cut losers at 1 ATR, let winners run on a 1.2 ATR trail.       |
//+------------------------------------------------------------------+
#property copyright "X13 RUNNER"
#property version   "6.00"
#property strict

#include <Trade/Trade.mqh>

input group "=== Sizing ==="
input double InpRiskPct       = 12.0;   // equity risked per trade (%)
input int    InpMaxPositions  = 1;      // concurrent positions
input double InpMaxTotalRisk  = 40.0;   // cap on aggregate open risk (%)
input double InpHaltPct       = 40.0;   // halt below this loss (%)

input group "=== Signal ==="
input int    InpFastEMA       = 50;     // H1
input int    InpSlowEMA       = 200;    // H1
input int    InpBreakBars     = 20;     // M5 breakout lookback
input int    InpATRPeriod     = 14;
input double InpSlATR         = 1.00;
input int    InpMinSlPts      = 120;
input int    InpMaxSlPts      = 140;
input double InpTpATR         = 12.0;   // far target, trail does the work

input group "=== Trail ==="
input double InpTrailStartATR = 0.80;   // start trailing after this gain
input double InpTrailATR      = 1.00;   // trail distance
input double InpBeAtATR       = 0.50;
input double InpBeLockPts     = 30;

input group "=== Filters ==="
input int    InpMaxSpreadPts  = 30;
input int    InpStartHour     = 0;
input int    InpEndHour       = 24;
input double InpMinATRPoints  = 40.0;
input double InpMaxATRPoints  = 900.0;

input group "=== Misc ==="
input ulong  InpMagic         = 13600;
input bool   InpVerbose       = true;

CTrade g_trade;
int hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE, hATR = INVALID_HANDLE;
datetime g_lastBar = 0, g_lastEntryBar = 0;
double g_point = 0, g_tickSize = 1, g_tickValue = 1, g_valPerPt = 0, g_stopLevel = 0;
int g_digits = 0;
double g_initial = 0;
bool g_halted = false;

int OnInit()
  {
   g_point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   g_stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(g_point <= 0 || g_tickSize <= 0 || g_tickValue <= 0) return INIT_FAILED;
   g_valPerPt = g_tickValue * (g_point / g_tickSize);

   hFast = iMA(_Symbol, PERIOD_H1, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, PERIOD_H1, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR  = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || hATR == INVALID_HANDLE) return INIT_FAILED;

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(40);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_initial = AccountInfoDouble(ACCOUNT_EQUITY);
   PrintFormat("X13 RUNNER start equity=%.2f valPerPt=%.5f", g_initial, g_valPerPt);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hATR  != INVALID_HANDLE) IndicatorRelease(hATR);
  }

double Buf(int h, int shift)
  {
   double b[];
   if(CopyBuffer(h, 0, shift, 1, b) != 1) return 0.0;
   return b[0];
  }

int CountPositions(int &netDir, double &openRisk)
  {
   int n = 0; netDir = 0; openRisk = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      n++;
      netDir += (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double sl = PositionGetDouble(POSITION_SL);
      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      double vol = PositionGetDouble(POSITION_VOLUME);
      if(sl > 0) openRisk += MathAbs(op - sl) / g_point * g_valPerPt * vol;
     }
   return n;
  }

double LotForRisk(double money, double slPts)
  {
   double lot = (slPts > 0 && g_valPerPt > 0) ? money / (slPts * g_valPerPt) : 0.0;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step > 0) lot = MathFloor(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return NormalizeDouble(lot, 2);
  }

void ManagePositions()
  {
   double atr = Buf(hATR, 0);
   if(atr <= 0) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      long   type = PositionGetInteger(POSITION_TYPE);

      if(type == POSITION_TYPE_BUY)
        {
         double gain = bid - open;
         double want = sl;
         if(gain >= atr * InpBeAtATR)
            want = MathMax(want, NormalizeDouble(open + InpBeLockPts * g_point, g_digits));
         if(gain >= atr * InpTrailStartATR)
            want = MathMax(want, NormalizeDouble(bid - atr * InpTrailATR, g_digits));
         if(want > sl + g_point * 0.5 && want < bid - g_stopLevel * g_point)
            g_trade.PositionModify(t, want, tp);
        }
      else
        {
         double gain = open - ask;
         double want = (sl == 0) ? 0.0 : sl;
         double be = NormalizeDouble(open - InpBeLockPts * g_point, g_digits);
         if(gain >= atr * InpBeAtATR && (want == 0 || be < want)) want = be;
         double tr = NormalizeDouble(ask + atr * InpTrailATR, g_digits);
         if(gain >= atr * InpTrailStartATR && (want == 0 || tr < want)) want = tr;
         if((sl == 0 || want < sl - g_point * 0.5) && want > ask + g_stopLevel * g_point)
            g_trade.PositionModify(t, want, tp);
        }
     }
  }

void TryEntry()
  {
   if(g_halted) return;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_initial > 0 && eq <= g_initial * (1.0 - InpHaltPct / 100.0))
     { g_halted = true; Print("X13: HALT"); return; }

   double spreadPts = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / g_point;
   if(spreadPts > InpMaxSpreadPts) return;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return;

   double atr = Buf(hATR, 0);
   if(atr <= 0) return;
   double atrPts = atr / g_point;
   if(atrPts < InpMinATRPoints || atrPts > InpMaxATRPoints) return;

   int netDir = 0; double openRisk = 0.0;
   int nPos = CountPositions(netDir, openRisk);
   if(nPos >= InpMaxPositions) return;

   double c1 = iClose(_Symbol, PERIOD_M5, 1);
   if(c1 <= 0) return;
   int hiIdx = iHighest(_Symbol, PERIOD_M5, MODE_HIGH, InpBreakBars, 2);
   int loIdx = iLowest(_Symbol, PERIOD_M5, MODE_LOW, InpBreakBars, 2);
   if(hiIdx < 0 || loIdx < 0) return;
   double hi = iHigh(_Symbol, PERIOD_M5, hiIdx);
   double lo = iLow(_Symbol, PERIOD_M5, loIdx);

   double f = Buf(hFast, 0), s = Buf(hSlow, 0);
   if(f <= 0 || s <= 0) return;

   int dir = 0;
   if(f > s && c1 > hi) dir = 1;
   if(f < s && c1 < lo) dir = -1;
   if(dir == 0) return;
   if(nPos > 0 && netDir != 0 && ((netDir > 0) != (dir > 0))) return;

   if(g_lastEntryBar > 0)
     {
      int bars = iBarShift(_Symbol, PERIOD_M5, g_lastEntryBar, false);
      if(bars >= 0 && bars < 3) return;
     }

   double slDist = MathMax(atr * InpSlATR, InpMinSlPts * g_point);
   slDist = MathMin(slDist, InpMaxSlPts * g_point);
   slDist = MathMax(slDist, (spreadPts + g_stopLevel + 30.0) * g_point);
   double tpDist = atr * InpTpATR;

   double slPts = slDist / g_point;
   double lot = LotForRisk(eq * InpRiskPct / 100.0, slPts);
   if(openRisk + slPts * g_valPerPt * lot > eq * InpMaxTotalRisk / 100.0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool ok = (dir > 0)
      ? g_trade.Buy(lot, _Symbol, 0.0, NormalizeDouble(ask - slDist, g_digits),
                    NormalizeDouble(ask + tpDist, g_digits), "X13R")
      : g_trade.Sell(lot, _Symbol, 0.0, NormalizeDouble(bid + slDist, g_digits),
                     NormalizeDouble(bid - tpDist, g_digits), "X13R");
   if(ok)
     {
      g_lastEntryBar = iTime(_Symbol, PERIOD_M5, 0);
      if(InpVerbose)
         PrintFormat("X13: %s lot=%.2f sl=%.0f atr=%.0f spread=%.0f eq=%.2f",
                     dir > 0 ? "BUY" : "SELL", lot, slPts, atrPts, spreadPts, eq);
     }
  }

void OnTick()
  {
   ManagePositions();
   datetime bar = iTime(_Symbol, PERIOD_M5, 0);
   if(bar == 0 || bar == g_lastBar) return;
   g_lastBar = bar;
   TryEntry();
  }
//+------------------------------------------------------------------+
