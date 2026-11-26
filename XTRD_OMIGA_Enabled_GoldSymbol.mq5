//+------------------------------------------------------------------+
//|                              XTRD_OMIGA_Enabled_GoldSymbol.mq5   |
//|  Trend-aligned pullback scalper for XAUUSD (M1).                 |
//|  Entry : fade a 30-min channel break running against the 24h     |
//|          trend (a pullback inside a trend), hour 1, only when    |
//|          tick activity is above its 60-min average.              |
//|  Exit  : fixed 80-pt stop, 45-minute time exit, 15-min cooldown. |
//+------------------------------------------------------------------+
#property copyright "XTRD / OMIGA"
#property link      ""
#property version   "1.01"

#include <Trade\Trade.mqh>

input group           "=== Engine ==="
input int             InpMagic              = 20261122;
input double          InpLot                 = 0.01;
input int             InpChannelBars         = 30;
input int             InpBreakoutPts         = 20;
input int             InpStopPts             = 80;
input int             InpHoldMinutes         = 45;
input int             InpCooldownMin         = 15;
input int             InpTradeHour           = 1;
input int             InpTrendBars           = 1440;
input double          InpPulseRatio          = 1.0;
input int             InpPulseAvgBars        = 60;
input int             InpMaxSpreadPts        = 60;
input double          InpMaxAccountRiskPct   = 100.0;
input int             InpMaxConcurrentPositions = 1;
input group           "=== Telemetry ==="
input bool            InpTelemetry           = true;
input string          InpTelemetryFile       = "X13_Omega_Telemetry.csv";

CTrade   g_trade;
datetime g_lastExit      = 0;
bool     g_hadPosition   = false;
datetime g_blockUntil    = 0;
double   g_point         = 0.0;

int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(50);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_point = _Point;
   if(g_point <= 0.0) { Print("Invalid point size"); return(INIT_FAILED); }
   if(InpTelemetry)
   {
      int h = FileOpen(InpTelemetryFile, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
      if(h != INVALID_HANDLE)
      {
         FileWrite(h, "time", "event", "dir", "price", "lots", "pnl_pts", "reason");
         FileClose(h);
      }
   }
   PrintFormat("XTRD engine ready on %s | stop=%d hold=%d hour=%d", _Symbol, InpStopPts, InpHoldMinutes, InpTradeHour);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { }

double SpreadPts()
{
   return (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / g_point;
}

bool BarClose(const int shift, double &value)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   int n = CopyClose(_Symbol, PERIOD_M1, 0, shift + 1, buf);
   if(n <= shift) return false;
   value = buf[shift];
   return true;
}

bool Channel(const int lookback, const int start, double &hh, double &ll)
{
   double hi[], lo[];
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   int need = start + lookback + 1;
   int nh = CopyHigh(_Symbol, PERIOD_M1, 0, need, hi);
   int nl = CopyLow (_Symbol, PERIOD_M1, 0, need, lo);
   if(nh < need || nl < need) return false;
   hh = -1.0e100;
   ll =  1.0e100;
   for(int i = start; i < start + lookback; i++)
   {
      if(hi[i] > hh) hh = hi[i];
      if(lo[i] < ll) ll = lo[i];
   }
   return true;
}

double PulseRatio()
{
   long vols[];
   ArraySetAsSeries(vols, true);
   int n = CopyTickVolume(_Symbol, PERIOD_M1, 0, InpPulseAvgBars + 1, vols);
   if(n < 10) return 1.0;
   double sum = 0.0;
   int cnt = 0;
   for(int i = 1; i < n; i++) { sum += (double)vols[i]; cnt++; }
   if(cnt <= 0) return 1.0;
   double avg = sum / (double)cnt;
   if(avg <= 0.0) return 1.0;
   return (double)vols[1] / avg;
}

bool HasOurPosition(datetime &timeOut, int &dirOut, double &priceOut, ulong &ticketOut)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      ticketOut = tk;
      timeOut   = (datetime)PositionGetInteger(POSITION_TIME);
      dirOut    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      priceOut  = PositionGetDouble(POSITION_PRICE_OPEN);
      return true;
   }
   return false;
}

int CountOurPositions()
{
   int n = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      n++;
   }
   return n;
}

void Telemetry(const string event, const int dir, const double price,
               const double lots, const double pnlPts, const string reason)
{
   if(!InpTelemetry) return;
   int h = FileOpen(InpTelemetryFile, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), event, dir,
             DoubleToString(price, _Digits), DoubleToString(lots, 2),
             DoubleToString(pnlPts, 0), reason);
   FileClose(h);
}

void OnTick()
{
   ulong    tk = 0;
   datetime openT = 0;
   int      dir = 0;
   double   openP = 0.0;

   if(HasOurPosition(openT, dir, openP, tk))
   {
      g_hadPosition = true;
      if((long)(TimeCurrent() - openT) >= (long)InpHoldMinutes * 60)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double closePx = (dir > 0) ? bid : ask;
         double pnlPts  = (dir > 0) ? (closePx - openP)/g_point : (openP - closePx)/g_point;
         if(g_trade.PositionClose(tk))
         {
            Telemetry("EXIT", dir, closePx, InpLot, pnlPts, "time");
            g_lastExit = TimeCurrent();
         }
      }
      return;
   }

   if(g_hadPosition)
   {
      g_hadPosition = false;
      if(g_lastExit == 0) g_lastExit = TimeCurrent();
   }

   if(TimeCurrent() < g_blockUntil) return;
   if(CountOurPositions() >= InpMaxConcurrentPositions) return;
   if((long)(TimeCurrent() - g_lastExit) < (long)InpCooldownMin * 60) return;
   MqlDateTime dtNow;
   TimeToStruct(TimeCurrent(), dtNow);
   if(dtNow.hour != InpTradeHour) return;
   if(SpreadPts() > (double)InpMaxSpreadPts) return;
   if(PulseRatio() < InpPulseRatio) return;

   double hh, ll, c1, cT;
   if(!Channel(InpChannelBars, 2, hh, ll)) return;
   if(!BarClose(1, c1)) return;
   if(!BarClose(InpTrendBars, cT)) return;
   if(c1 <= 0.0 || cT <= 0.0) return;

   double thr = (double)InpBreakoutPts * g_point;
   bool   upBreak = (c1 > hh + thr);
   bool   dnBreak = (c1 < ll - thr);
   double trend   = c1 - cT;

   int signalDir = 0;
   if(upBreak && trend < 0.0) signalDir = -1;
   if(dnBreak && trend > 0.0) signalDir =  1;
   if(signalDir == 0) return;

   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskUsd = (double)InpStopPts * g_point * InpLot * 100.0;
   if(riskUsd > equity * InpMaxAccountRiskPct / 100.0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(signalDir > 0)
   {
      double sl = ask - (double)InpStopPts * g_point;
      if(g_trade.Buy(InpLot, _Symbol, 0.0, sl, 0.0, "XTRD-PB"))
      { g_blockUntil = TimeCurrent() + 180; Telemetry("ENTRY", 1, ask, InpLot, 0, "pullback-buy"); }
   }
   else
   {
      double sl = bid + (double)InpStopPts * g_point;
      if(g_trade.Sell(InpLot, _Symbol, 0.0, sl, 0.0, "XTRD-PB"))
      { g_blockUntil = TimeCurrent() + 180; Telemetry("ENTRY", -1, bid, InpLot, 0, "pullback-sell"); }
   }
}
//+------------------------------------------------------------------+
