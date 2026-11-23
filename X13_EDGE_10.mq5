//+------------------------------------------------------------------+
//|                                              X13_EDGE_10.mq5     |
//|   Fixed-risk engine for a $10 XAUUSD account.                    |
//|   SL 110 pts (11% of equity), TP 220 pts (RR 2), pullback entry  |
//|   inside the London/NY overlap, compounding lot.                 |
//+------------------------------------------------------------------+
#property copyright "X13 EDGE"
#property version   "4.00"
#property strict

#include <Trade/Trade.mqh>

input group "=== Fixed risk ==="
input double InpRiskPct      = 11.0;   // equity risked per trade (%)
input int    InpSlPts        = 110;    // stop (points)
input int    InpTpPts        = 220;    // target (points)
input int    InpMaxPositions = 3;
input double InpHaltPct      = 80.0;

input group "=== Entry ==="
input int    InpFastEMA      = 50;     // H1
input int    InpSlowEMA      = 200;    // H1
input int    InpPullEMA      = 21;     // M5
input int    InpATRPeriod    = 14;     // M5
input double InpMinATRPoints = 55.0;   // volatility floor
input double InpMaxATRPoints = 210.0;  // volatility ceiling
input double InpMinBodyATR   = 0.25;   // confirmation candle body (ATR)

input group "=== Filters ==="
input int    InpMaxSpreadPts = 30;
input int    InpStartHour    = 12;     // overlap window
input int    InpEndHour      = 18;
input bool   InpUseOverlapOnly = true;

input group "=== Misc ==="
input ulong  InpMagic        = 13400;
input bool   InpVerbose      = true;

CTrade g_trade;
int hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE, hPull = INVALID_HANDLE, hATR = INVALID_HANDLE;
datetime g_lastBar = 0;
double g_point = 0, g_tickSize = 1, g_tickValue = 1, g_valPerPt = 0, g_stopLevel = 0;
int g_digits = 0;
double g_initial = 0;
bool g_halted = false;
int g_wins = 0, g_losses = 0;

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
   hPull = iMA(_Symbol, PERIOD_M5, InpPullEMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR  = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE ||
      hPull == INVALID_HANDLE || hATR == INVALID_HANDLE) return INIT_FAILED;

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(40);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_initial = AccountInfoDouble(ACCOUNT_EQUITY);
   PrintFormat("X13 EDGE start equity=%.2f slPts=%d riskPerTrade=$%.2f",
               g_initial, InpSlPts, InpSlPts * g_valPerPt * 0.01);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hPull != INVALID_HANDLE) IndicatorRelease(hPull);
   if(hATR  != INVALID_HANDLE) IndicatorRelease(hATR);
   PrintFormat("X13 EDGE end equity=%.2f wins=%d losses=%d",
               AccountInfoDouble(ACCOUNT_EQUITY), g_wins, g_losses);
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
   double p = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) +
              HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
              HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   if(p >= 0) g_wins++; else g_losses++;
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

   int netDir = 0;
   int nPos = CountPositions(netDir);
   if(nPos >= InpMaxPositions) return;

   double f = Buf(hFast, 0), s = Buf(hSlow, 0);
   if(f <= 0 || s <= 0) return;
   bool biasUp = (f > s);

   double c1 = iClose(_Symbol, PERIOD_M5, 1);
   double o1 = iOpen(_Symbol, PERIOD_M5, 1);
   double l1 = iLow(_Symbol, PERIOD_M5, 1);
   double h1 = iHigh(_Symbol, PERIOD_M5, 1);
   double ema = Buf(hPull, 0);
   if(c1 <= 0 || o1 <= 0 || ema <= 0) return;

   double body = MathAbs(c1 - o1);
   if(body < atr * InpMinBodyATR) return;

   bool buy  = biasUp  && c1 > ema && l1 <= ema && c1 > o1;
   bool sell = !biasUp && c1 < ema && h1 >= ema && c1 < o1;
   if(!buy && !sell) return;
   if(nPos > 0 && netDir != 0 && ((netDir > 0) != buy)) return;

   double slDist = MathMax(InpSlPts * g_point, (spreadPts + g_stopLevel + 25.0) * g_point);
   double tpDist = MathMax(InpTpPts * g_point, slDist * 2.0);
   double slPts  = slDist / g_point;

   double lot = LotForRisk(eq * InpRiskPct / 100.0, slPts);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool ok = buy
      ? g_trade.Buy(lot, _Symbol, 0.0, NormalizeDouble(ask - slDist, g_digits),
                    NormalizeDouble(ask + tpDist, g_digits), "X13E")
      : g_trade.Sell(lot, _Symbol, 0.0, NormalizeDouble(bid + slDist, g_digits),
                     NormalizeDouble(bid - tpDist, g_digits), "X13E");
   if(ok && InpVerbose)
      PrintFormat("X13: %s lot=%.2f sl=%.0f tp=%.0f atr=%.0f spread=%.0f eq=%.2f",
                  buy ? "BUY" : "SELL", lot, slPts, tpDist / g_point, atrPts, spreadPts, eq);
  }

void OnTick()
  {
   datetime bar = iTime(_Symbol, PERIOD_M5, 0);
   if(bar == 0 || bar == g_lastBar) return;
   g_lastBar = bar;
   TryEntry();
  }
//+------------------------------------------------------------------+
