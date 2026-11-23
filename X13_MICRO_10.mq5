//+------------------------------------------------------------------+
//|                                                X13_MICRO_10.mq5  |
//|   Purpose-built for a $10 XAUUSD account, fixed spread 26 pts    |
//|   One position, fixed 0.01 lot, wide ATR stops, session filtered |
//+------------------------------------------------------------------+
#property copyright "X13 MICRO"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//--- risk
input group "=== Risk ==="
input double InpLot              = 0.01;   // fixed lot (min volume)
input double InpDailyLossPct     = 20.0;   // stop for the day after this loss (%)
input double InpMaxTotalLossPct  = 55.0;   // stop trading permanently below this (%)
input int    InpCooldownMin      = 20;     // pause after a losing trade (minutes)

//--- signal
input group "=== Signal ==="
input int    InpFastEMA          = 50;     // H1 fast EMA
input int    InpSlowEMA          = 200;    // H1 slow EMA
input int    InpPullEMA          = 20;     // M5 pullback EMA
input int    InpBreakBars        = 12;     // breakout lookback (M5 bars)
input int    InpATRPeriod        = 14;     // ATR period (M5)
input double InpSlATR            = 1.20;   // stop = ATR x this
input double InpTpATR            = 2.60;   // target = ATR x this
input int    InpMinSlPts         = 180;    // minimum stop (points)
input int    InpMaxSlPts         = 600;    // maximum stop (points)
input int    InpMinTpPts         = 380;    // minimum target (points)

//--- filters
input group "=== Filters ==="
input int    InpMaxSpreadPts     = 32;     // no entry above this spread
input int    InpStartHour        = 8;      // server hour, inclusive
input int    InpEndHour          = 21;     // server hour, exclusive
input bool   InpUseH1Bias        = true;   // require H1 trend agreement
input double InpMinATRPoints     = 40.0;   // skip dead market (ATR in points)
input double InpMaxATRPoints     = 900.0;  // skip chaos (ATR in points)

//--- management
input group "=== Management ==="
input bool   InpUseBreakeven     = true;   // move stop to break-even
input double InpBeAtATR          = 1.00;   // trigger distance (ATR)
input double InpBeLockPts        = 40;     // locked profit (points)

//--- misc
input group "=== Misc ==="
input ulong  InpMagic            = 13100;
input bool   InpVerbose          = true;

//--- globals
CTrade   g_trade;
int      hFast = INVALID_HANDLE;
int      hSlow = INVALID_HANDLE;
int      hPull = INVALID_HANDLE;
int      hATR  = INVALID_HANDLE;
datetime g_lastBar = 0;
double   g_point = 0.0;
int      g_digits = 0;
double   g_stopLevelPts = 0.0;
double   g_dayStartEquity = 0.0;
int      g_dayOfYear = -1;
bool     g_halted = false;
datetime g_cooldownUntil = 0;
double   g_initialEquity = 0.0;
bool     g_beDone = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(g_point <= 0.0)
     { Print("X13: invalid point"); return INIT_FAILED; }

   g_stopLevelPts = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   hFast = iMA(_Symbol, PERIOD_H1, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, PERIOD_H1, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hPull = iMA(_Symbol, PERIOD_M5, InpPullEMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR  = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE ||
      hPull == INVALID_HANDLE || hATR == INVALID_HANDLE)
     { Print("X13: indicator handle failed"); return INIT_FAILED; }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(30);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);

   g_initialEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayStartEquity = g_initialEquity;

   PrintFormat("X13 MICRO start: equity=%.2f point=%.5f stopLevel=%.0f minLot=%.2f",
               g_initialEquity, g_point, g_stopLevelPts,
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hPull != INVALID_HANDLE) IndicatorRelease(hPull);
   if(hATR  != INVALID_HANDLE) IndicatorRelease(hATR);
  }

//+------------------------------------------------------------------+
double Buf(int handle, int shift)
  {
   double b[];
   if(CopyBuffer(handle, 0, shift, 1, b) != 1) return 0.0;
   return b[0];
  }

//+------------------------------------------------------------------+
bool HasPosition(int &dir)
  {
   dir = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
void UpdateDayState()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_dayOfYear)
     {
      g_dayOfYear = dt.day_of_year;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(InpVerbose)
         PrintFormat("X13: new day, equity=%.2f", g_dayStartEquity);
     }

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_initialEquity > 0.0 && eq <= g_initialEquity * (1.0 - InpMaxTotalLossPct / 100.0))
     {
      if(!g_halted)
        {
         g_halted = true;
         Print("X13: HALTED, equity floor reached");
        }
     }
  }

//+------------------------------------------------------------------+
bool DailyLossHit()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_dayStartEquity <= 0.0) return false;
   return (eq <= g_dayStartEquity * (1.0 - InpDailyLossPct / 100.0));
  }

//+------------------------------------------------------------------+
void ManagePosition()
  {
   if(!InpUseBreakeven) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      long   type  = PositionGetInteger(POSITION_TYPE);
      double atr   = Buf(hATR, 0);
      if(atr <= 0.0) return;

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double beDist = atr * InpBeAtATR;

      if(type == POSITION_TYPE_BUY)
        {
         if(bid - open < beDist) continue;
         double newSl = NormalizeDouble(open + InpBeLockPts * g_point, g_digits);
         if(sl > 0.0 && newSl <= sl + g_point) continue;
         if(g_trade.PositionModify(ticket, newSl, tp))
            PrintFormat("X13: BE buy %I64u -> %.2f", ticket, newSl);
        }
      else
        {
         if(open - ask < beDist) continue;
         double newSl = NormalizeDouble(open - InpBeLockPts * g_point, g_digits);
         if(sl > 0.0 && newSl >= sl - g_point) continue;
         if(g_trade.PositionModify(ticket, newSl, tp))
            PrintFormat("X13: BE sell %I64u -> %.2f", ticket, newSl);
        }
     }
  }

//+------------------------------------------------------------------+
void TryEntry()
  {
   if(g_halted) return;
   if(DailyLossHit()) return;
   if(TimeCurrent() < g_cooldownUntil) return;

   int dir = 0;
   if(HasPosition(dir)) return;

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

   double c1  = iClose(_Symbol, PERIOD_M5, 1);
   double ema = Buf(hPull, 0);
   if(c1 <= 0.0 || ema <= 0.0) return;

   int hiIdx = iHighest(_Symbol, PERIOD_M5, MODE_HIGH, InpBreakBars, 2);
   int loIdx = iLowest(_Symbol, PERIOD_M5, MODE_LOW, InpBreakBars, 2);
   if(hiIdx < 0 || loIdx < 0) return;
   double hi = iHigh(_Symbol, PERIOD_M5, hiIdx);
   double lo = iLow(_Symbol, PERIOD_M5, loIdx);

   bool biasUp = true, biasDown = true;
   if(InpUseH1Bias)
     {
      double f = Buf(hFast, 0);
      double s = Buf(hSlow, 0);
      if(f <= 0.0 || s <= 0.0) return;
      biasUp   = (f > s);
      biasDown = (f < s);
     }

   bool buy  = biasUp   && c1 > hi && c1 > ema;
   bool sell = biasDown && c1 < lo && c1 < ema;
   if(!buy && !sell) return;

   double slDist = MathMax(atr * InpSlATR, InpMinSlPts * g_point);
   slDist = MathMin(slDist, InpMaxSlPts * g_point);
   slDist = MathMax(slDist, (spreadPts + g_stopLevelPts + 40.0) * g_point);

   double tpDist = MathMax(atr * InpTpATR, InpMinTpPts * g_point);
   if(tpDist < slDist * 1.6) tpDist = slDist * 1.6;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double lot = InpLot;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   bool ok = false;
   if(buy)
     {
      double sl = NormalizeDouble(ask - slDist, g_digits);
      double tp = NormalizeDouble(ask + tpDist, g_digits);
      ok = g_trade.Buy(lot, _Symbol, 0.0, sl, tp, "X13M");
     }
   else
     {
      double sl = NormalizeDouble(bid + slDist, g_digits);
      double tp = NormalizeDouble(bid - tpDist, g_digits);
      ok = g_trade.Sell(lot, _Symbol, 0.0, sl, tp, "X13M");
     }

   if(ok)
      PrintFormat("X13: %s lot=%.2f slPts=%.0f tpPts=%.0f atrPts=%.0f spread=%.0f",
                  buy ? "BUY" : "SELL", lot, slDist / g_point, tpDist / g_point,
                  atrPts, spreadPts);
   else
      PrintFormat("X13: order failed ret=%d (%s)", g_trade.ResultRetcode(),
                  g_trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.symbol != _Symbol) return;
   if((ulong)trans.magic != InpMagic) return;

   if(HistoryDealSelect(trans.deal))
     {
      long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
        {
         double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) +
                         HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                         HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
         if(profit < 0.0 && InpCooldownMin > 0)
            g_cooldownUntil = TimeCurrent() + InpCooldownMin * 60;
         if(InpVerbose)
            PrintFormat("X13: closed profit=%.2f equity=%.2f", profit,
                        AccountInfoDouble(ACCOUNT_EQUITY));
        }
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateDayState();
   ManagePosition();

   datetime barTime = iTime(_Symbol, PERIOD_M5, 0);
   if(barTime == 0 || barTime == g_lastBar) return;
   g_lastBar = barTime;

   TryEntry();
  }
//+------------------------------------------------------------------+
