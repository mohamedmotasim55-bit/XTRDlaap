//+------------------------------------------------------------------+
//|                                                X13_HFT_10.mq5    |
//|   24/7 dense scalper. M1 momentum bursts, symmetric 200 pt       |
//|   stops, dynamic risk, three concurrent slots, no session gate.  |
//+------------------------------------------------------------------+
#property copyright "X13 HFT"
#property version   "5.00"
#property strict

#include <Trade/Trade.mqh>

input group "=== Dynamic risk ==="
input double InpRiskBase     = 8.0;    // base equity risk (%)
input double InpRiskWinStep  = 1.0;    // +risk after a win (%)
input double InpRiskLossStep = 2.0;    // -risk after a loss (%)
input double InpRiskMin      = 4.0;
input double InpRiskMax      = 18.0;

input group "=== Trade geometry (points) ==="
input int    InpSlPts        = 200;    // stop
input int    InpTpPts        = 200;    // target
input int    InpMaxPositions = 3;
input int    InpMinBarsGap   = 1;      // M1 bars between entries

input group "=== Signal ==="
input int    InpATRPeriod    = 14;     // M1 ATR
input int    InpTrendEMA     = 50;     // M5 EMA
input double InpBurstATR     = 0.70;   // burst threshold (ATR)
input double InpMinATRPoints = 18.0;
input double InpMaxATRPoints = 260.0;

input group "=== Filters ==="
input int    InpMaxSpreadPts = 30;     // 26 typical
input double InpHaltPct      = 80.0;

input group "=== Misc ==="
input ulong  InpMagic        = 13500;
input bool   InpVerbose      = false;

CTrade g_trade;
int hATR = INVALID_HANDLE, hEMA = INVALID_HANDLE;
datetime g_lastBar = 0, g_lastEntry = 0;
double g_point = 0, g_tickSize = 1, g_tickValue = 1, g_valPerPt = 0, g_stopLevel = 0;
int g_digits = 0;
double g_initial = 0;
double g_risk = 8.0;
bool g_halted = false;
int g_trades = 0, g_wins = 0;

int OnInit()
  {
   g_point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   g_stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(g_point <= 0 || g_tickSize <= 0 || g_tickValue <= 0) return INIT_FAILED;
   g_valPerPt = g_tickValue * (g_point / g_tickSize);

   hATR = iATR(_Symbol, PERIOD_M1, InpATRPeriod);
   hEMA = iMA(_Symbol, PERIOD_M5, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(hATR == INVALID_HANDLE || hEMA == INVALID_HANDLE) return INIT_FAILED;

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(40);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_initial = AccountInfoDouble(ACCOUNT_EQUITY);
   g_risk = InpRiskBase;
   PrintFormat("X13 HFT start equity=%.2f fixedRisk=$%.2f per trade",
               g_initial, InpSlPts * g_valPerPt * 0.01);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hEMA != INVALID_HANDLE) IndicatorRelease(hEMA);
   PrintFormat("X13 HFT end equity=%.2f trades=%d wins=%d risk=%.1f%%",
               AccountInfoDouble(ACCOUNT_EQUITY), g_trades, g_wins, g_risk);
  }

double Buf(int h, int shift)
  {
   double b[];
   if(CopyBuffer(h, 0, shift, 1, b) != 1) return 0.0;
   return b[0];
  }

int CountPositions(int &netDir)
  {
   int n = 0; netDir = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      n++;
      netDir += (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
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

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.symbol != _Symbol) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic) return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) return;

   g_trades++;
   double p = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) +
              HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
              HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   if(p >= 0.0) { g_wins++; g_risk = MathMin(InpRiskMax, g_risk + InpRiskWinStep); }
   else          { g_risk = MathMax(InpRiskMin, g_risk - InpRiskLossStep); }
  }

void TryEntry()
  {
   if(g_halted) return;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_initial > 0 && eq <= g_initial * (1.0 - InpHaltPct / 100.0))
     { g_halted = true; Print("X13: HALT"); return; }

   double spreadPts = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / g_point;
   if(spreadPts > InpMaxSpreadPts) return;

   double atr = Buf(hATR, 0);
   if(atr <= 0) return;
   double atrPts = atr / g_point;
   if(atrPts < InpMinATRPoints || atrPts > InpMaxATRPoints) return;

   int netDir = 0;
   int nPos = CountPositions(netDir);
   if(nPos >= InpMaxPositions) return;

   double c1 = iClose(_Symbol, PERIOD_M1, 1);
   double o1 = iOpen(_Symbol, PERIOD_M1, 1);
   if(c1 <= 0 || o1 <= 0) return;
   double body = c1 - o1;
   if(MathAbs(body) < atr * InpBurstATR) return;

   double ema = Buf(hEMA, 0);
   if(ema <= 0) return;

   int dir = 0;
   if(body > 0 && c1 > ema) dir = 1;
   if(body < 0 && c1 < ema) dir = -1;
   if(dir == 0) return;
   if(nPos > 0 && netDir != 0 && ((netDir > 0) != (dir > 0))) return;

   if(g_lastEntry > 0)
     {
      int bars = iBarShift(_Symbol, PERIOD_M1, g_lastEntry, false);
      if(bars >= 0 && bars < InpMinBarsGap) return;
     }

   double slDist = MathMax(InpSlPts * g_point, (spreadPts + g_stopLevel + 25.0) * g_point);
   double tpDist = MathMax(InpTpPts * g_point, slDist * 1.2);
   double slPts  = slDist / g_point;
   double lot = LotForRisk(eq * g_risk / 100.0, slPts);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool ok = (dir > 0)
      ? g_trade.Buy(lot, _Symbol, 0.0, NormalizeDouble(ask - slDist, g_digits),
                    NormalizeDouble(ask + tpDist, g_digits), "X13H")
      : g_trade.Sell(lot, _Symbol, 0.0, NormalizeDouble(bid + slDist, g_digits),
                     NormalizeDouble(bid - tpDist, g_digits), "X13H");
   if(ok)
     {
      g_lastEntry = iTime(_Symbol, PERIOD_M1, 0);
      if(InpVerbose)
         PrintFormat("X13: %s lot=%.2f sl=%.0f atr=%.0f spread=%.0f eq=%.2f risk=%.1f%%",
                     dir > 0 ? "BUY" : "SELL", lot, slPts, atrPts, spreadPts, eq, g_risk);
     }
  }

void OnTick()
  {
   datetime bar = iTime(_Symbol, PERIOD_M1, 0);
   if(bar == 0 || bar == g_lastBar) return;
   g_lastBar = bar;
   TryEntry();
  }
//+------------------------------------------------------------------+
