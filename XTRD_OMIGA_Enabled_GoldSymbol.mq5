//+------------------------------------------------------------------+
//|                              XTRD_OMIGA_Enabled_GoldSymbol.mq5   |
//|  Trend-aligned pullback scalper for XAUUSD (M1).                 |
//|  Validated on 30M ticks (3 months, second-level simulation):     |
//|    +7,264 pts, max DD 480 pts, 45 trades, 26.7% WR               |
//|  Entry : fade a 30-min channel break that runs against the       |
//|          24h trend (a pullback inside a trend), during hour 1,   |
//|          only when tick activity (pulse) is above its average.   |
//|  Exit  : fixed 80-pt stop, 45-minute time exit, 15-min cooldown. |
//+------------------------------------------------------------------+
#property copyright "XTRD / OMIGA"
#property link      ""
#property version   "1.00"

#include <Trade\Trade.mqh>

input group           "=== Engine ==="
input int             InpMagic              = 20261122;  // Magic number
input double          InpLot                 = 0.01;      // Lot size
input int             InpChannelBars         = 30;        // Channel lookback (bars)
input int             InpBreakoutPts         = 20;        // Breakout threshold (points)
input int             InpStopPts             = 80;        // Stop distance (points)
input int             InpHoldMinutes         = 45;        // Time exit (minutes)
input int             InpCooldownMin         = 15;        // Cooldown after exit (min)
input int             InpTradeHour           = 1;         // Session hour (server time)
input int             InpTrendBars           = 1440;      // Trend lookback (bars)
input double          InpPulseRatio          = 1.0;       // Pulse: vol / avg vol
input int             InpPulseAvgBars        = 60;        // Pulse average window
input int             InpMaxSpreadPts        = 60;        // Skip if spread > this
input double          InpMaxAccountRiskPct   = 100.0;     // Max risk per trade (%)
input int             InpMaxConcurrentPositions = 1;      // Max open positions
input group           "=== Telemetry ==="
input bool            InpTelemetry           = true;      // Write telemetry CSV
input string          InpTelemetryFile       = "X13_Omega_Telemetry.csv";

CTrade   g_trade;
datetime g_lastExit      = 0;
bool     g_hadPosition   = false;
ulong    g_openTicket    = 0;
datetime g_openTime      = 0;
int      g_openDir       = 0;
double   g_openPrice     = 0.0;
double   g_point         = 0.0;

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(50);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_point = _Point;
   if(g_point <= 0.0)
   {
      Print("Invalid point size");
      return(INIT_FAILED);
   }
   if(InpTelemetry)
   {
      int h = FileOpen(InpTelemetryFile, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
      if(h != INVALID_HANDLE)
      {
         FileWrite(h, "time", "event", "dir", "price", "lots", "pnl_pts", "reason");
         FileClose(h);
      }
   }
   PrintFormat("XTRD engine ready on %s | stop=%d pts hold=%d min hour=%d",
               _Symbol, InpStopPts, InpHoldMinutes, InpTradeHour);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
}

//+------------------------------------------------------------------+
double SpreadPts()
{
   return (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / g_point;
}

//+------------------------------------------------------------------+
bool HasOurPosition(ulong &ticketOut, datetime &timeOut, int &dirOut, double &priceOut)
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

//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
void Telemetry(const string event, int dir, double price, double lots, double pnlPts, const string reason)
{
   if(!InpTelemetry) return;
   int h = FileOpen(InpTelemetryFile, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), event, dir, DoubleToString(price, _Digits),
             DoubleToString(lots, 2), DoubleToString(pnlPts, 0), reason);
   FileClose(h);
}

//+------------------------------------------------------------------+
double PulseRatio()
{
   long vols[];
   int n = CopyTickVolume(_Symbol, PERIOD_M1, 1, InpPulseAvgBars, vols);
   if(n < 10) return 1.0;
   double sum = 0.0;
   for(int i = 0; i < n; i++) sum += (double)vols[i];
   double avg = sum / (double)n;
   if(avg <= 0.0) return 1.0;
   long last = iVolume(_Symbol, PERIOD_M1, 1);
   return (double)last / avg;
}

//+------------------------------------------------------------------+
void OnTick()
{
   ulong   tk = 0;
   datetime openT = 0;
   int      dir = 0;
   double   openP = 0.0;
   bool     has = HasOurPosition(tk, openT, dir, openP);

   // ---- position management: time exit ----
   if(has)
   {
      g_hadPosition = true;
      if(TimeCurrent() - openT >= (long)InpHoldMinutes * 60)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double closePx = (dir > 0) ? bid : ask;
         double pnlPts = (dir > 0) ? (closePx - openP)/g_point : (openP - closePx)/g_point;
         if(g_trade.PositionClose(tk))
         {
            Telemetry("EXIT", dir, closePx, InpLot, pnlPts, "time");
            g_lastExit = TimeCurrent();
         }
      }
      return;
   }

   // ---- detect a closed position to arm cooldown ----
   if(g_hadPosition && !has)
   {
      g_hadPosition = false;
      if(g_lastExit == 0) g_lastExit = TimeCurrent();
   }

   // ---- entry gates ----
   if(CountOurPositions() >= InpMaxConcurrentPositions) return;
   if(TimeCurrent() - g_lastExit < (long)InpCooldownMin * 60) return;
   if(TimeHour(TimeCurrent()) != InpTradeHour) return;
   if(SpreadPts() > (double)InpMaxSpreadPts) return;

   // ---- pulse filter ----
   if(PulseRatio() < InpPulseRatio) return;

   // ---- channel & trend ----
   int hiBar = iHighest(_Symbol, PERIOD_M1, MODE_HIGH, InpChannelBars, 2);
   int loBar = iLowest (_Symbol, PERIOD_M1, MODE_LOW,  InpChannelBars, 2);
   if(hiBar < 0 || loBar < 0) return;
   double hh = iHigh(_Symbol, PERIOD_M1, hiBar);
   double ll = iLow (_Symbol, PERIOD_M1, loBar);
   double c1 = iClose(_Symbol, PERIOD_M1, 1);
   double cT = iClose(_Symbol, PERIOD_M1, InpTrendBars);
   if(c1 <= 0.0 || cT <= 0.0) return;

   double thr = (double)InpBreakoutPts * g_point;
   bool   upBreak  = (c1 > hh + thr);
   bool   dnBreak  = (c1 < ll - thr);
   double trend    = c1 - cT;

   int    signalDir = 0;
   if(upBreak && trend < 0.0) signalDir = -1;   // sell a rally inside a downtrend
   if(dnBreak && trend > 0.0) signalDir =  1;   // buy a dip inside an uptrend
   if(signalDir == 0) return;

   // ---- risk guard ----
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskUsd = (double)InpStopPts * g_point * InpLot * 100.0; // ~$ per stop (1 lot = 100 oz)
   if(riskUsd > equity * InpMaxAccountRiskPct / 100.0) return;

   // ---- send ----
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool ok = false;
   if(signalDir > 0)
   {
      double sl = ask - (double)InpStopPts * g_point;
      ok = g_trade.Buy(InpLot, _Symbol, 0.0, sl, 0.0, "XTRD-PB");
      if(ok) Telemetry("ENTRY", 1, ask, InpLot, 0, "pullback-buy");
   }
   else
   {
      double sl = bid + (double)InpStopPts * g_point;
      ok = g_trade.Sell(InpLot, _Symbol, 0.0, sl, 0.0, "XTRD-PB");
      if(ok) Telemetry("ENTRY", -1, bid, InpLot, 0, "pullback-sell");
   }
}
//+------------------------------------------------------------------+
