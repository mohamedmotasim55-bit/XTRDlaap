//+------------------------------------------------------------------+
//|                                              X13_MAKER.mq5       |
//|   Passive-entry scalper. Every previous build paid the 22-point  |
//|   spread on a market order. This one rests a limit order on the  |
//|   passive side, so the fill happens at bid (buys) or ask (sells) |
//|   and the spread is earned instead of paid.                      |
//+------------------------------------------------------------------+
#property copyright "X13 GLOBAL"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input group "=== Entry ==="
input int    InpOffsetPts    = 5;      // limit price away from the touch
input int    InpExpirySec    = 180;    // cancel unfilled limit after this
input int    InpLookback     = 50;
input double InpVolMult      = 2.0;    // volume-per-point burst threshold
input double InpBodyATR      = 0.40;

input group "=== Geometry ==="
input int    InpTpPts        = 120;
input int    InpSlPts        = 120;

input group "=== Risk ==="
input double InpRiskPct      = 20.0;
input double InpHaltPct      = 60.0;

input group "=== Filters ==="
input int    InpMaxSpreadPts = 30;     // only rest orders in normal spread
input int    InpStartHour    = 0;
input int    InpEndHour      = 24;

input group "=== Misc ==="
input ulong  InpMagic        = 13900;
input bool   InpVerbose      = true;

CTrade g_trade;
int hATR = INVALID_HANDLE;
datetime g_lastBar = 0;
double g_point = 0, g_tickSize = 1, g_tickValue = 1, g_valPerPt = 0;
int g_digits = 0;
double g_initial = 0;
bool g_halted = false;
int g_placed = 0, g_filled = 0, g_expired = 0;

int OnInit()
  {
   g_point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(g_point <= 0 || g_tickSize <= 0 || g_tickValue <= 0) return INIT_FAILED;
   g_valPerPt = g_tickValue * (g_point / g_tickSize);
   hATR = iATR(_Symbol, PERIOD_M1, 14);
   if(hATR == INVALID_HANDLE) return INIT_FAILED;
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(50);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_initial = AccountInfoDouble(ACCOUNT_EQUITY);
   PrintFormat("X13 MAKER start eq=%.2f valPerPt=%.5f", g_initial, g_valPerPt);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   PrintFormat("X13 MAKER end eq=%.2f placed=%d filled=%d expired=%d",
               AccountInfoDouble(ACCOUNT_EQUITY), g_placed, g_filled, g_expired);
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

int CountPending()
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      n++;
     }
   return n;
  }

void CancelStale()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      datetime exp = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      if(exp > 0 && TimeCurrent() >= exp)
        { g_trade.OrderDelete(t); g_expired++; }
     }
  }

void TryPlace()
  {
   if(g_halted) return;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_initial > 0 && eq <= g_initial * (1.0 - InpHaltPct / 100.0))
     { g_halted = true; Print("X13: HALT"); return; }
   if(CountPositions() > 0 || CountPending() > 0) return;

   double spreadPts = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                       SymbolInfoDouble(_Symbol, SYMBOL_BID)) / g_point;
   if(spreadPts > InpMaxSpreadPts) return;

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return;

   double atr[];
   if(CopyBuffer(hATR, 0, 0, 1, atr) != 1 || atr[0] <= 0) return;

   double vpp = 0, base = 0;
   for(int k = 1; k <= InpLookback; k++)
     {
      double r = (iHigh(_Symbol, PERIOD_M1, k) - iLow(_Symbol, PERIOD_M1, k)) / g_point;
      double x = (double)iVolume(_Symbol, PERIOD_M1, k) / MathMax(r, 1.0);
      if(k == 1) vpp = x;
      base += x;
     }
   base /= InpLookback;
   if(base <= 0) return;

   double o1 = iOpen(_Symbol, PERIOD_M1, 1), c1 = iClose(_Symbol, PERIOD_M1, 1);
   double body = c1 - o1;
   if(MathAbs(body) < atr[0] * InpBodyATR) return;
   if(vpp < base * InpVolMult) return;

   double lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double riskMoney = InpSlPts * g_valPerPt * lot;
   if(riskMoney > eq * InpRiskPct / 100.0)
     {
      if(InpVerbose) PrintFormat("X13: skip, min lot risks %.2f > %.1f%%", riskMoney, InpRiskPct);
      return;
     }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   datetime expiry = TimeCurrent() + InpExpirySec;

   bool ok;
   if(body > 0)
     {
      double px = NormalizeDouble(bid - InpOffsetPts * g_point, g_digits);
      ok = g_trade.BuyLimit(lot, px, _Symbol,
                            NormalizeDouble(px - InpSlPts * g_point, g_digits),
                            NormalizeDouble(px + InpTpPts * g_point, g_digits),
                            ORDER_TIME_SPECIFIED, expiry, "X13M");
     }
   else
     {
      double px = NormalizeDouble(ask + InpOffsetPts * g_point, g_digits);
      ok = g_trade.SellLimit(lot, px, _Symbol,
                             NormalizeDouble(px + InpSlPts * g_point, g_digits),
                             NormalizeDouble(px - InpTpPts * g_point, g_digits),
                             ORDER_TIME_SPECIFIED, expiry, "X13M");
     }
   if(ok) g_placed++;
   else if(InpVerbose) Print("X13: place failed ret=", g_trade.ResultRetcode());
  }

void OnTick()
  {
   CancelStale();
   datetime bar = iTime(_Symbol, PERIOD_M1, 0);
   if(bar == 0 || bar == g_lastBar) return;
   g_lastBar = bar;
   TryPlace();
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
      {"final_equity",   DoubleToString(TesterStatistics(STAT_EQUITY), 2)}
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
