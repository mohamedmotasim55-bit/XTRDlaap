//+------------------------------------------------------------------+
//|                                             X13_GROWTH_10.mq5    |
//|   Growth engine for a $10 XAUUSD account, 1:3000 leverage        |
//|   Compounding risk, concurrent positions, pyramiding, trailing   |
//+------------------------------------------------------------------+
#property copyright "X13 GROWTH"
#property version   "2.00"
#property strict

#include <Trade/Trade.mqh>

input group "=== Growth ==="
input double InpRiskPct        = 12.0;   // equity risked per trade (%)
input int    InpMaxPositions   = 4;      // concurrent positions
input bool   InpPyramid        = true;   // add on continuation
input double InpMaxTotalRisk   = 45.0;   // cap on open risk (%)
input double InpHaltEquityPct  = 85.0;   // stop everything below this loss (%)

input group "=== Signal ==="
input int    InpFastEMA        = 50;     // H1
input int    InpSlowEMA        = 200;    // H1
input int    InpBreakBars      = 8;      // M5 breakout lookback
input int    InpATRPeriod      = 14;     // M5 ATR
input double InpSlATR          = 0.90;   // stop = ATR x this
input double InpTpATR          = 2.20;   // target = ATR x this
input int    InpMinSlPts       = 110;    // floor on stop (points)
input int    InpMaxSlPts       = 320;    // ceiling on stop (points)
input int    InpMinTpPts       = 220;    // floor on target (points)

input group "=== Filters ==="
input int    InpMaxSpreadPts   = 30;     // entry spread ceiling
input int    InpStartHour      = 8;
input int    InpEndHour        = 21;
input double InpMinATRPoints   = 35.0;
input double InpMaxATRPoints   = 700.0;
input int    InpMinBarsBetween = 2;      // M5 bars between entries

input group "=== Management ==="
input bool   InpUseTrail       = true;
input double InpTrailATR       = 1.00;
input double InpBeAtATR        = 0.80;
input double InpBeLockPts      = 25;

input group "=== Misc ==="
input ulong  InpMagic          = 13200;
input bool   InpVerbose        = true;

CTrade   g_trade;
int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE, hATR = INVALID_HANDLE;
datetime g_lastBar = 0;
datetime g_lastEntryBar = 0;
double   g_point = 0.0, g_tickSize = 1.0, g_tickValue = 1.0, g_valPerPt = 0.0;
int      g_digits = 0;
double   g_stopLevel = 0.0;
double   g_initial = 0.0;
bool     g_halted = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   g_stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(g_point <= 0.0 || g_tickSize <= 0.0 || g_tickValue <= 0.0)
     { Print("X13: bad symbol metrics"); return INIT_FAILED; }

   g_valPerPt = g_tickValue * (g_point / g_tickSize);

   hFast = iMA(_Symbol, PERIOD_H1, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, PERIOD_H1, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR  = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || hATR == INVALID_HANDLE)
     { Print("X13: handle failed"); return INIT_FAILED; }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(40);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);

   g_initial = AccountInfoDouble(ACCOUNT_EQUITY);
   PrintFormat("X13 GROWTH start equity=%.2f valPerPointPerLot=%.5f minLot=%.2f",
               g_initial, g_valPerPt, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hATR  != INVALID_HANDLE) IndicatorRelease(hATR);
  }

//+------------------------------------------------------------------+
double Buf(int h, int shift)
  {
   double b[];
   if(CopyBuffer(h, 0, shift, 1, b) != 1) return 0.0;
   return b[0];
  }

//+------------------------------------------------------------------+
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
      if(sl > 0.0) openRisk += MathAbs(op - sl) / g_point * g_valPerPt * vol;
     }
   return n;
  }

//+------------------------------------------------------------------+
double LotForRisk(double riskMoney, double slPts)
  {
   double lot = 0.0;
   if(slPts > 0.0 && g_valPerPt > 0.0)
      lot = riskMoney / (slPts * g_valPerPt);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step > 0.0) lot = MathFloor(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return NormalizeDouble(lot, 2);
  }

//+------------------------------------------------------------------+
void ManagePositions()
  {
   double atr = Buf(hATR, 0);
   if(atr <= 0.0) return;
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

      double newSl = sl;
      if(type == POSITION_TYPE_BUY)
        {
         double gain = bid - open;
         if(InpUseTrail && gain >= atr * InpTrailATR)
           {
            double trail = NormalizeDouble(bid - atr * InpTrailATR, g_digits);
            if(trail > newSl) newSl = trail;
           }
         if(gain >= atr * InpBeAtATR)
           {
            double be = NormalizeDouble(open + InpBeLockPts * g_point, g_digits);
            if(be > newSl) newSl = be;
           }
         if(newSl > sl + g_point * 0.5 && newSl < bid - g_stopLevel * g_point)
            g_trade.PositionModify(t, newSl, tp);
        }
      else
        {
         double gain = open - ask;
         if(InpUseTrail && gain >= atr * InpTrailATR)
           {
            double trail = NormalizeDouble(ask + atr * InpTrailATR, g_digits);
            if(newSl == 0.0 || trail < newSl) newSl = trail;
           }
         if(gain >= atr * InpBeAtATR)
           {
            double be = NormalizeDouble(open - InpBeLockPts * g_point, g_digits);
            if(newSl == 0.0 || be < newSl) newSl = be;
           }
         if((sl == 0.0 || newSl < sl - g_point * 0.5) && newSl > ask + g_stopLevel * g_point)
            g_trade.PositionModify(t, newSl, tp);
        }
     }
  }

//+------------------------------------------------------------------+
void TryEntry()
  {
   if(g_halted) return;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_initial > 0.0 && eq <= g_initial * (1.0 - InpHaltEquityPct / 100.0))
     { g_halted = true; Print("X13: HALT equity floor"); return; }

   double spreadPts = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                       SymbolInfoDouble(_Symbol, SYMBOL_BID)) / g_point;
   if(spreadPts > InpMaxSpreadPts) return;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return;

   double atr = Buf(hATR, 0);
   if(atr <= 0.0) return;
   double atrPts = atr / g_point;
   if(atrPts < InpMinATRPoints || atrPts > InpMaxATRPoints) return;

   int netDir = 0; double openRisk = 0.0;
   int nPos = CountPositions(netDir, openRisk);
   if(nPos >= InpMaxPositions) return;

   double c1 = iClose(_Symbol, PERIOD_M5, 1);
   if(c1 <= 0.0) return;
   int hiIdx = iHighest(_Symbol, PERIOD_M5, MODE_HIGH, InpBreakBars, 2);
   int loIdx = iLowest(_Symbol, PERIOD_M5, MODE_LOW, InpBreakBars, 2);
   if(hiIdx < 0 || loIdx < 0) return;
   double hi = iHigh(_Symbol, PERIOD_M5, hiIdx);
   double lo = iLow(_Symbol, PERIOD_M5, loIdx);

   double f = Buf(hFast, 0), s = Buf(hSlow, 0);
   if(f <= 0.0 || s <= 0.0) return;
   bool biasUp = (f > s), biasDown = (f < s);

   int dir = 0;
   if(biasUp && c1 > hi)   dir = 1;
   if(biasDown && c1 < lo) dir = -1;
   if(dir == 0) return;

   if(nPos > 0)
     {
      if(!InpPyramid) return;
      if(netDir != 0 && ((netDir > 0) != (dir > 0))) return;
     }

   if(g_lastEntryBar > 0)
     {
      int barsSince = iBarShift(_Symbol, PERIOD_M5, g_lastEntryBar, false);
      if(barsSince >= 0 && barsSince < InpMinBarsBetween) return;
     }

   double slDist = MathMax(atr * InpSlATR, InpMinSlPts * g_point);
   slDist = MathMin(slDist, InpMaxSlPts * g_point);
   slDist = MathMax(slDist, (spreadPts + g_stopLevel + 30.0) * g_point);

   double tpDist = MathMax(atr * InpTpATR, InpMinTpPts * g_point);
   if(tpDist < slDist * 1.5) tpDist = slDist * 1.5;

   double slPts = slDist / g_point;
   double riskMoney = eq * InpRiskPct / 100.0;
   double lot = LotForRisk(riskMoney, slPts);

   double minLoss = slPts * g_valPerPt * lot;
   if(openRisk + minLoss > eq * InpMaxTotalRisk / 100.0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool ok = false;
   if(dir > 0)
      ok = g_trade.Buy(lot, _Symbol, 0.0,
                       NormalizeDouble(ask - slDist, g_digits),
                       NormalizeDouble(ask + tpDist, g_digits), "X13G");
   else
      ok = g_trade.Sell(lot, _Symbol, 0.0,
                        NormalizeDouble(bid + slDist, g_digits),
                        NormalizeDouble(bid - tpDist, g_digits), "X13G");

   if(ok)
     {
      g_lastEntryBar = iTime(_Symbol, PERIOD_M5, 0);
      if(InpVerbose)
         PrintFormat("X13: %s lot=%.2f sl=%.0f tp=%.0f atr=%.0f spread=%.0f eq=%.2f",
                     dir > 0 ? "BUY" : "SELL", lot, slPts, tpDist / g_point,
                     atrPts, spreadPts, eq);
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ManagePositions();

   datetime bar = iTime(_Symbol, PERIOD_M5, 0);
   if(bar == 0 || bar == g_lastBar) return;
   g_lastBar = bar;
   TryEntry();
  }
//+------------------------------------------------------------------+
