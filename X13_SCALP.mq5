//+------------------------------------------------------------------+
//|                                              X13_SCALP.mq5       |
//|   Tick-activity scalper. The only M1 family with positive GROSS  |
//|   expectancy in the 23-month screen (volume-per-point bursts).   |
//|   Purpose: measure it on real ticks where intrabar path is exact.|
//+------------------------------------------------------------------+
#property copyright "X13 GLOBAL"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input group "=== Signal ==="
input int    InpLookback     = 50;      // bars for the volume/point baseline
input double InpVolMult      = 2.0;     // burst threshold vs baseline
input double InpBodyATR      = 0.40;    // minimum body in ATR units
input int    InpATRPeriod    = 14;

input group "=== Geometry ==="
input int    InpSlPts        = 90;
input int    InpTpPts        = 150;
input int    InpBeAtPts      = 60;      // move stop to entry after this gain
input int    InpTrailStart   = 100;     // start trailing after this gain
input int    InpTrailPts     = 60;      // trail distance
input int    InpMaxBars      = 30;      // time exit

input group "=== Risk ==="
input double InpRiskPct      = 20.0;    // 0.01 lot is 9 USD at a 90 pt stop
input int    InpMaxPositions = 1;
input double InpHaltPct      = 60.0;

input group "=== Filters ==="
input int    InpMaxSpreadPts = 45;
input int    InpStartHour    = 0;
input int    InpEndHour      = 24;

input group "=== Misc ==="
input ulong  InpMagic        = 13800;
input bool   InpVerbose      = true;

CTrade g_trade;
int hATR = INVALID_HANDLE;
datetime g_lastBar = 0;
double g_point = 0, g_tickSize = 1, g_tickValue = 1, g_valPerPt = 0;
int g_digits = 0;
double g_initial = 0;
bool g_halted = false;
int g_opens = 0, g_rejects = 0, g_spreadRej = 0;

int OnInit()
  {
   g_point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(g_point <= 0 || g_tickSize <= 0 || g_tickValue <= 0) return INIT_FAILED;
   g_valPerPt = g_tickValue * (g_point / g_tickSize);
   hATR = iATR(_Symbol, PERIOD_M1, InpATRPeriod);
   if(hATR == INVALID_HANDLE) return INIT_FAILED;
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(50);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_initial = AccountInfoDouble(ACCOUNT_EQUITY);
   PrintFormat("X13 SCALP start eq=%.2f valPerPt=%.5f", g_initial, g_valPerPt);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   PrintFormat("X13 SCALP end eq=%.2f opens=%d rejects=%d spreadRej=%d",
               AccountInfoDouble(ACCOUNT_EQUITY), g_opens, g_rejects, g_spreadRej);
  }

int CountPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      n++;
     }
   return n;
  }

void Manage()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double cur = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                               : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double gain = (type == POSITION_TYPE_BUY) ? (cur - op) / g_point : (op - cur) / g_point;

      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(InpMaxBars > 0 && (TimeCurrent() - opened) > InpMaxBars * 60)
        { g_trade.PositionClose(t); continue; }

      double newSl = sl;
      if(gain >= InpTrailStart)
         newSl = (type == POSITION_TYPE_BUY) ? cur - InpTrailPts * g_point
                                             : cur + InpTrailPts * g_point;
      else if(gain >= InpBeAtPts)
         newSl = op;

      if(newSl != sl)
        {
         bool better = (type == POSITION_TYPE_BUY) ? (newSl > sl) : (newSl < sl || sl == 0);
         if(better && MathAbs(cur - newSl) / g_point > 10)
            g_trade.PositionModify(t, NormalizeDouble(newSl, g_digits), tp);
        }
     }
  }

void TryEntry()
  {
   if(g_halted) return;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_initial > 0 && eq <= g_initial * (1.0 - InpHaltPct / 100.0))
     { g_halted = true; Print("X13: HALT"); return; }
   if(CountPositions() >= InpMaxPositions) return;

   double spreadPts = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                       SymbolInfoDouble(_Symbol, SYMBOL_BID)) / g_point;
   if(spreadPts > InpMaxSpreadPts) { g_spreadRej++; return; }

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return;

   double atr[];
   if(CopyBuffer(hATR, 0, 0, 1, atr) != 1 || atr[0] <= 0) return;

   // volume per point on the last closed bar vs the baseline
   double vpp = 0, base = 0;
   int cnt = 0;
   for(int k = 1; k <= InpLookback; k++)
     {
      double r = (iHigh(_Symbol, PERIOD_M1, k) - iLow(_Symbol, PERIOD_M1, k)) / g_point;
      double v = (double)iVolume(_Symbol, PERIOD_M1, k);
      double x = v / MathMax(r, 1.0);
      if(k == 1) vpp = x;
      base += x; cnt++;
     }
   if(cnt == 0) return;
   base /= cnt;
   if(base <= 0) return;

   double o1 = iOpen(_Symbol, PERIOD_M1, 1);
   double c1 = iClose(_Symbol, PERIOD_M1, 1);
   double body = c1 - o1;
   if(MathAbs(body) < atr[0] * InpBodyATR) return;
   if(vpp < base * InpVolMult) return;

   int dir = (body > 0) ? 1 : -1;
   double lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double riskMoney = InpSlPts * g_valPerPt * lot;
   if(riskMoney > eq * InpRiskPct / 100.0)
     {
      if(InpVerbose)
         PrintFormat("X13: skip, min lot risks %.2f > %.1f%% of %.2f", riskMoney, InpRiskPct, eq);
      g_rejects++;
      return;
     }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool ok = (dir > 0)
      ? g_trade.Buy(lot, _Symbol, 0.0, NormalizeDouble(ask - InpSlPts * g_point, g_digits),
                    NormalizeDouble(ask + InpTpPts * g_point, g_digits), "X13S")
      : g_trade.Sell(lot, _Symbol, 0.0, NormalizeDouble(bid + InpSlPts * g_point, g_digits),
                     NormalizeDouble(bid - InpTpPts * g_point, g_digits), "X13S");
   if(ok) { g_opens++; }
   else if(InpVerbose) Print("X13: order failed ret=", g_trade.ResultRetcode());
  }

void OnTick()
  {
   Manage();
   datetime bar = iTime(_Symbol, PERIOD_M1, 0);
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
