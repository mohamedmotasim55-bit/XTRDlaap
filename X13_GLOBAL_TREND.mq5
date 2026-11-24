//+------------------------------------------------------------------+
//|                                          X13_GLOBAL_TREND.mq5    |
//|   The only family that survived out-of-sample screening:         |
//|   H4/H1 Donchian breakout and pullback with ATR stops.           |
//|   Requires wide stops, therefore a funded account.               |
//+------------------------------------------------------------------+
#property copyright "X13 GLOBAL"
#property version   "7.00"
#property strict

#include <Trade/Trade.mqh>

input group "=== Timeframe ==="
input ENUM_TIMEFRAMES InpTF     = PERIOD_H4;  // signal timeframe
input int    InpBreakBars       = 20;         // Donchian lookback
input int    InpFastEMA         = 50;
input int    InpSlowEMA         = 200;
input int    InpATRPeriod       = 14;
input bool   InpUsePullback     = true;       // also trade EMA50 pullbacks

input group "=== Geometry ==="
input double InpSlATR           = 2.0;        // stop = ATR x this
input double InpTpMult          = 3.0;        // target = stop x this
input int    InpMinSlPts        = 300;
input int    InpMaxSlPts        = 6000;

input group "=== Risk ==="
input double InpRiskPct         = 2.0;        // equity risk per trade (%)
input int    InpMaxPositions    = 1;
input double InpMaxTotalRisk    = 5.0;
input double InpHaltPct         = 30.0;

input group "=== Filters ==="
input int    InpMaxSpreadPts    = 60;
input double InpMinATRPoints    = 150.0;

input group "=== Misc ==="
input ulong  InpMagic           = 13700;
input bool   InpVerbose         = true;

CTrade g_trade;
int hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE, hATR = INVALID_HANDLE;
datetime g_lastBar = 0;
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

   hFast = iMA(_Symbol, InpTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, InpTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR  = iATR(_Symbol, InpTF, InpATRPeriod);
   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || hATR == INVALID_HANDLE)
      return INIT_FAILED;

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(50);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_initial = AccountInfoDouble(ACCOUNT_EQUITY);
   PrintFormat("X13 GLOBAL start equity=%.2f point=%.3f valPerPt=%.5f",
               g_initial, g_point, g_valPerPt);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hATR  != INVALID_HANDLE) IndicatorRelease(hATR);
   PrintFormat("X13 GLOBAL end equity=%.2f", AccountInfoDouble(ACCOUNT_EQUITY));
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
   if(lot < minLot) return 0.0;     // never force an oversized minimum lot
   if(lot > maxLot) lot = maxLot;
   return NormalizeDouble(lot, 2);
  }

void TryEntry()
  {
   if(g_halted) return;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_initial > 0 && eq <= g_initial * (1.0 - InpHaltPct / 100.0))
     { g_halted = true; Print("X13: HALT equity floor"); return; }

   double spreadPts = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                       SymbolInfoDouble(_Symbol, SYMBOL_BID)) / g_point;
   if(spreadPts > InpMaxSpreadPts) return;

   double atr = Buf(hATR, 0);
   if(atr <= 0) return;
   double atrPts = atr / g_point;
   if(atrPts < InpMinATRPoints) return;

   int netDir = 0; double openRisk = 0.0;
   int nPos = CountPositions(netDir, openRisk);
   if(nPos >= InpMaxPositions) return;

   double f = Buf(hFast, 0), s = Buf(hSlow, 0);
   if(f <= 0 || s <= 0) return;

   double c1 = iClose(_Symbol, InpTF, 1);
   double o1 = iOpen(_Symbol, InpTF, 1);
   double l1 = iLow(_Symbol, InpTF, 1);
   double h1 = iHigh(_Symbol, InpTF, 1);
   if(c1 <= 0) return;

   int hiIdx = iHighest(_Symbol, InpTF, MODE_HIGH, InpBreakBars, 2);
   int loIdx = iLowest(_Symbol, InpTF, MODE_LOW, InpBreakBars, 2);
   if(hiIdx < 0 || loIdx < 0) return;
   double hi = iHigh(_Symbol, InpTF, hiIdx);
   double lo = iLow(_Symbol, InpTF, loIdx);

   bool up = (f > s);
   bool brkBuy  = up && c1 > hi;
   bool brkSell = !up && c1 < lo;
   bool pbBuy   = InpUsePullback && up && l1 <= f && c1 > f;
   bool pbSell  = InpUsePullback && !up && h1 >= f && c1 < f;

   int dir = 0;
   if(brkBuy || pbBuy)   dir = 1;
   if(brkSell || pbSell) dir = -1;
   if(dir == 0) return;
   if(nPos > 0 && netDir != 0 && ((netDir > 0) != (dir > 0))) return;

   double slDist = atr * InpSlATR;
   slDist = MathMax(slDist, InpMinSlPts * g_point);
   slDist = MathMin(slDist, InpMaxSlPts * g_point);
   double tpDist = slDist * InpTpMult;
   double slPts = slDist / g_point;

   double lot = LotForRisk(eq * InpRiskPct / 100.0, slPts);
   if(lot <= 0.0)
     {
      if(InpVerbose)
         PrintFormat("X13: skip, stop %.0f pts needs %.2f USD risk, above %.1f%% of equity",
                     slPts, slPts * g_valPerPt * 0.01, InpRiskPct);
      return;
     }
   if(openRisk + slPts * g_valPerPt * lot > eq * InpMaxTotalRisk / 100.0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool ok = (dir > 0)
      ? g_trade.Buy(lot, _Symbol, 0.0, NormalizeDouble(ask - slDist, g_digits),
                    NormalizeDouble(ask + tpDist, g_digits), "X13GT")
      : g_trade.Sell(lot, _Symbol, 0.0, NormalizeDouble(bid + slDist, g_digits),
                     NormalizeDouble(bid - tpDist, g_digits), "X13GT");
   if(ok && InpVerbose)
      PrintFormat("X13: %s lot=%.2f sl=%.0f tp=%.0f atr=%.0f eq=%.2f",
                  dir > 0 ? "BUY" : "SELL", lot, slPts, tpDist / g_point, atrPts, eq);
  }

void OnTick()
  {
   datetime bar = iTime(_Symbol, InpTF, 0);
   if(bar == 0 || bar == g_lastBar) return;
   g_lastBar = bar;
   TryEntry();
  }

//--- native MT5 statistics, written by the terminal itself -------------
double OnTester()
  {
   string f = "X13_Native_" + _Symbol + ".csv";
   int h = FileOpen(f, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE) return 0.0;
   string rows[][2] = {
      {"metric","value"},
      {"net_profit",     DoubleToString(TesterStatistics(STAT_PROFIT), 2)},
      {"gross_profit",   DoubleToString(TesterStatistics(STAT_GROSS_PROFIT), 2)},
      {"gross_loss",     DoubleToString(TesterStatistics(STAT_GROSS_LOSS), 2)},
      {"profit_factor",  DoubleToString(TesterStatistics(STAT_PROFIT_FACTOR), 3)},
      {"expected_payoff",DoubleToString(TesterStatistics(STAT_EXPECTED_PAYOFF), 3)},
      {"trades",         DoubleToString(TesterStatistics(STAT_TRADES), 0)},
      {"profit_trades",  DoubleToString(TesterStatistics(STAT_PROFIT_TRADES), 0)},
      {"loss_trades",    DoubleToString(TesterStatistics(STAT_LOSS_TRADES), 0)},
      {"win_pct",        DoubleToString(100.0 * TesterStatistics(STAT_PROFIT_TRADES) /
                                        MathMax(TesterStatistics(STAT_TRADES), 1), 1)},
      {"equity_dd",      DoubleToString(TesterStatistics(STAT_EQUITY_DD), 2)},
      {"equity_dd_pct",  DoubleToString(TesterStatistics(STAT_EQUITYDD_PERCENT), 2)},
      {"balance_dd_pct", DoubleToString(TesterStatistics(STAT_BALANCEDD_PERCENT), 2)},
      {"sharpe",         DoubleToString(TesterStatistics(STAT_SHARPE_RATIO), 3)},
      {"recovery",       DoubleToString(TesterStatistics(STAT_RECOVERY_FACTOR), 3)},
      {"initial_deposit",DoubleToString(TesterStatistics(STAT_INITIAL_DEPOSIT), 2)},
      {"final_equity",   DoubleToString(TesterStatistics(STAT_BALANCE), 2)}
   };
   for(int r = 0; r < 17; r++)
      FileWrite(h, rows[r][0], rows[r][1]);
   FileClose(h);
   PrintFormat("X13 native stats -> %s  net=%.2f pf=%.3f trades=%d",
               f, TesterStatistics(STAT_PROFIT), TesterStatistics(STAT_PROFIT_FACTOR),
               (int)TesterStatistics(STAT_TRADES));
   return TesterStatistics(STAT_PROFIT);
  }

//+------------------------------------------------------------------+
