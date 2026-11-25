//+------------------------------------------------------------------+
//| XTRD_OMIGA_CENT_ENGINE_V2_0_4_H2.mq5                            |
//| Research EA: H2 compression breakout for cent accounts           |
//| Risk model: 0.25% of equity, sized with OrderCalcProfit           |
//+------------------------------------------------------------------+
#property strict
#property version   "2.040"
#property description "XTRD OMIGA CENT ENGINE V2.0.4 - H2 only"

#include <Trade/Trade.mqh>

CTrade trade;

//------------------------------ Inputs ------------------------------
input group "01. Identity and execution"
input ulong  InpMagic                 = 2040204;
input int    InpDeviationPoints       = 20;
input bool   InpAllowTrading          = false; // Must be enabled manually after validation
input bool   InpOnePositionOnly       = true;

input group "02. Risk"
input double InpRiskPercent           = 0.25;  // Percent of current equity
input double InpMaxRiskPercent        = 0.25;  // Hard cap; cannot be exceeded
input double InpMaxLot                = 1.00;
input bool   InpRejectIfMinLotTooRisky = true;

input group "03. H2 compression and breakout"
input int    InpCompressionSeconds    = 60;
input int    InpVelocitySeconds       = 3;
input double InpMaxBoxRangePoints     = 60.0;
input double InpBreakoutBufferPoints  = 2.0;
input double InpMinVelocityPtsPerSec  = 8.0;
input int    InpMinBoxTicks           = 12;
input int    InpMaxSpreadPoints       = 40;
input int    InpSignalCooldownSeconds = 10;

input group "04. Stop placement"
input double InpStopBehindEdgePoints  = 45.0;
input double InpMinStopPoints         = 40.0;
input double InpMaxStopPoints         = 70.0;

input group "05. Dynamic exit"
input double InpHarvestProfitPoints   = 35.0;
input double InpSlowdownMaxPoints     = 3.0;
input int    InpSlowdownTicks         = 10;
input double InpTrailBehindMicroPts   = 15.0;
input bool   InpUseMicroTrail         = true;

input group "06. Wave lock"
input int    InpWaveResetSeconds      = 5;
input double InpWaveReentryBufferPts  = 3.0;

input group "07. Diagnostics"
input bool   InpVerboseLog            = true;
input bool   InpWriteCsvLog           = true;
input string InpLogFile               = "XTRD_CENT_V204_H2_Diagnostics.csv";

//------------------------------ State -------------------------------
#define TICK_CAPACITY 2500
long   g_tickTime[TICK_CAPACITY];
double g_tickMid[TICK_CAPACITY];
int    g_tickCount = 0;

bool   g_waveLocked = false;
double g_lockedHigh = 0.0;
double g_lockedLow  = 0.0;
datetime g_insideSince = 0;
datetime g_lastEntryTime = 0;
datetime g_lastSignalTime = 0;
datetime g_lastLogTime = 0;

//------------------------------ Logging -----------------------------
void LogMsg(const string message)
{
   string line = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) +
                 " | " + _Symbol + " | " + message;
   if(InpVerboseLog) Print(line);

   if(InpWriteCsvLog)
   {
      int h = FileOpen(InpLogFile, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
      if(h != INVALID_HANDLE)
      {
         FileSeek(h, 0, SEEK_END);
         FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), _Symbol, message);
         FileClose(h);
      }
      else
         Print("DIAG_FILE_ERROR | cannot open ", InpLogFile, " | err=", GetLastError());
   }
}

void LogReject(const string reason)
{
   // Throttle repeated rejection messages, but keep signal evaluation on every tick.
   static datetime lastRejectLog = 0;
   datetime now = TimeCurrent();
   if(now != lastRejectLog)
   {
      lastRejectLog = now;
      LogMsg("REJECT | " + reason);
   }
}

void LogAccept(const string reason)
{
   LogMsg("SIGNAL | " + reason);
}

//------------------------------ Tick cache --------------------------
void AddTick(const MqlTick &tick)
{
   double mid = (tick.bid + tick.ask) * 0.5;
   if(mid <= 0.0) return;

   if(g_tickCount > 0 && g_tickTime[g_tickCount-1] == tick.time_msc)
   {
      g_tickMid[g_tickCount-1] = mid;
      return;
   }

   if(g_tickCount >= TICK_CAPACITY)
   {
      for(int i=1; i<TICK_CAPACITY; i++)
      {
         g_tickTime[i-1] = g_tickTime[i];
         g_tickMid[i-1]  = g_tickMid[i];
      }
      g_tickCount = TICK_CAPACITY-1;
   }

   g_tickTime[g_tickCount] = tick.time_msc;
   g_tickMid[g_tickCount]  = mid;
   g_tickCount++;
}

bool GetMidAtOrBefore(const long targetMsc, double &midOut, long &timeOut)
{
   for(int i=g_tickCount-1; i>=0; i--)
   {
      if(g_tickTime[i] <= targetMsc)
      {
         midOut = g_tickMid[i];
         timeOut = g_tickTime[i];
         return true;
      }
   }
   return false;
}

bool BuildCompressionBox(const long nowMsc, double &boxHigh, double &boxLow, int &usedTicks)
{
   long endMsc   = nowMsc - (long)InpVelocitySeconds * 1000;
   long startMsc = nowMsc - (long)InpCompressionSeconds * 1000;

   boxHigh = -DBL_MAX;
   boxLow  = DBL_MAX;
   usedTicks = 0;

   for(int i=g_tickCount-1; i>=0; i--)
   {
      long tm = g_tickTime[i];
      if(tm > endMsc) continue;
      if(tm < startMsc) break;

      double p = g_tickMid[i];
      if(p > boxHigh) boxHigh = p;
      if(p < boxLow)  boxLow = p;
      usedTicks++;
   }

   return (usedTicks >= InpMinBoxTicks && boxHigh > boxLow);
}

//------------------------------ Symbol helpers ----------------------
double PointSize()
{
   return SymbolInfoDouble(_Symbol, SYMBOL_POINT);
}

int VolumeDigits()
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int digits = 0;
   while(digits < 8 && MathAbs(step - MathRound(step)) > 1e-8)
   {
      step *= 10.0;
      digits++;
   }
   return digits;
}

double NormalizeVolumeDown(const double volume)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(step <= 0.0) return 0.0;
   double v = MathFloor(volume / step + 1e-10) * step;
   v = MathMin(v, maxv);
   v = MathMin(v, InpMaxLot);
   v = NormalizeDouble(v, VolumeDigits());

   if(v + 1e-10 < minv) return 0.0;
   return v;
}

bool HasOurPosition()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
   }
   return false;
}

bool HasAnyPositionOnSymbol()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
   }
   return false;
}

bool TradingEnvironmentOK(string &why)
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      why = "terminal disconnected";
      return false;
   }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      why = "automated trading disabled";
      return false;
   }
   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY)
   {
      why = "symbol trade mode does not allow new positions";
      return false;
   }
   return true;
}

//------------------------------ Risk sizing -------------------------
bool CalculateRiskVolume(const ENUM_ORDER_TYPE orderType,
                         const double entryPrice,
                         const double slPrice,
                         double &volume,
                         double &riskMoney,
                         double &estimatedLoss,
                         string &why)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskPct = MathMin(InpRiskPercent, InpMaxRiskPercent);
   if(equity <= 0.0 || riskPct <= 0.0)
   {
      why = "invalid equity or risk percentage";
      return false;
   }

   riskMoney = equity * riskPct / 100.0;

   double profitAtOneLot = 0.0;
   if(!OrderCalcProfit(orderType, _Symbol, 1.0, entryPrice, slPrice, profitAtOneLot))
   {
      why = "OrderCalcProfit failed, err=" + IntegerToString(GetLastError());
      return false;
   }

   estimatedLoss = MathAbs(profitAtOneLot);
   if(estimatedLoss <= 0.0)
   {
      why = "calculated loss per lot is zero";
      return false;
   }

   double rawVolume = riskMoney / estimatedLoss;
   volume = NormalizeVolumeDown(rawVolume);

   double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(volume <= 0.0)
   {
      why = "risk budget produces volume below minimum lot";
      return false;
   }

   if(InpRejectIfMinLotTooRisky && rawVolume < minv)
   {
      why = "minimum lot exceeds risk budget";
      return false;
   }

   double actualProfit = 0.0;
   if(!OrderCalcProfit(orderType, _Symbol, volume, entryPrice, slPrice, actualProfit))
   {
      why = "OrderCalcProfit volume check failed";
      return false;
   }

   double actualLoss = MathAbs(actualProfit);
   if(actualLoss > riskMoney + 0.0000001)
   {
      why = "normalized volume exceeds risk budget";
      return false;
   }

   double margin = 0.0;
   if(!OrderCalcMargin(orderType, _Symbol, volume, entryPrice, margin))
   {
      why = "OrderCalcMargin failed";
      return false;
   }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin > freeMargin)
   {
      why = "insufficient free margin; required=" + DoubleToString(margin, 2) +
            " free=" + DoubleToString(freeMargin, 2);
      return false;
   }

   estimatedLoss = actualLoss;
   return true;
}

//------------------------------ Wave lock ---------------------------
void UpdateWaveLock(const double mid)
{
   if(!g_waveLocked) return;

   double buffer = InpWaveReentryBufferPts * PointSize();
   bool inside = (mid <= g_lockedHigh + buffer && mid >= g_lockedLow - buffer);

   if(inside)
   {
      if(g_insideSince == 0) g_insideSince = TimeCurrent();
      if((TimeCurrent() - g_insideSince) >= InpWaveResetSeconds)
      {
         g_waveLocked = false;
         g_insideSince = 0;
         LogMsg("WAVE_UNLOCK | price returned inside prior compression box");
      }
   }
   else
      g_insideSince = 0;
}

void LockWave(const double boxHigh, const double boxLow)
{
   g_waveLocked = true;
   g_lockedHigh = boxHigh;
   g_lockedLow  = boxLow;
   g_insideSince = 0;
   LogMsg("WAVE_LOCK | high=" + DoubleToString(boxHigh, _Digits) +
          " low=" + DoubleToString(boxLow, _Digits));
}

//------------------------------ Dynamic exit ------------------------
bool GetRecentExtreme(const bool forBuy, const int count, double &extreme)
{
   if(g_tickCount < count) return false;

   extreme = forBuy ? DBL_MAX : -DBL_MAX;
   int start = MathMax(0, g_tickCount-count);
   for(int i=start; i<g_tickCount; i++)
   {
      if(forBuy) extreme = MathMin(extreme, g_tickMid[i]);
      else       extreme = MathMax(extreme, g_tickMid[i]);
   }
   return true;
}

bool GetSlowdownMove(const bool forBuy, const int count, double &movePoints)
{
   if(g_tickCount <= count) return false;
   double oldMid = g_tickMid[g_tickCount-1-count];
   double newMid = g_tickMid[g_tickCount-1];
   // Signed favourable progress: negative values mean the market reversed.
   movePoints = (forBuy ? (newMid-oldMid) : (oldMid-newMid)) / PointSize();
   return true;
}

void ManageOpenPosition(const MqlTick &tick)
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double currentPrice = (type == POSITION_TYPE_BUY ? tick.bid : tick.ask);
      double profitPts = (type == POSITION_TYPE_BUY ?
                          (currentPrice-openPrice) : (openPrice-currentPrice)) / PointSize();

      // Profit harvest: only after the trade has cleared the configured threshold.
      double slowdown = 1e9;
      bool hasSlowdown = GetSlowdownMove(type == POSITION_TYPE_BUY, InpSlowdownTicks, slowdown);
      if(profitPts >= InpHarvestProfitPoints && hasSlowdown &&
         slowdown <= InpSlowdownMaxPoints)
      {
         LogMsg("EXIT_HARVEST | ticket=" + (string)ticket +
                " profit_pts=" + DoubleToString(profitPts, 1) +
                " last_" + IntegerToString(InpSlowdownTicks) +
                "_tick_move=" + DoubleToString(slowdown, 1));
         trade.PositionClose(ticket);
         return;
      }

      if(InpUseMicroTrail && profitPts >= InpHarvestProfitPoints * 0.60)
      {
         double extreme = 0.0;
         if(GetRecentExtreme(type == POSITION_TYPE_BUY, 10, extreme))
         {
            double newSL = currentSL;
            if(type == POSITION_TYPE_BUY)
            {
               newSL = NormalizeDouble(extreme - InpTrailBehindMicroPts*PointSize(), _Digits);
               if((currentSL == 0.0 || newSL > currentSL + PointSize()) &&
                  newSL < tick.bid)
               {
                  long stops = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
                  long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
                  double minDist = (double)MathMax(stops, freeze) * PointSize();
                  if(tick.bid-newSL > minDist)
                  {
                     if(trade.PositionModify(ticket, newSL, currentTP))
                        LogMsg("TRAIL_UPDATE | BUY | ticket=" + (string)ticket +
                               " newSL=" + DoubleToString(newSL, _Digits));
                  }
               }
            }
            else
            {
               newSL = NormalizeDouble(extreme + InpTrailBehindMicroPts*PointSize(), _Digits);
               if((currentSL == 0.0 || newSL < currentSL - PointSize()) &&
                  newSL > tick.ask)
               {
                  long stops = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
                  long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
                  double minDist = (double)MathMax(stops, freeze) * PointSize();
                  if(newSL-tick.ask > minDist)
                  {
                     if(trade.PositionModify(ticket, newSL, currentTP))
                        LogMsg("TRAIL_UPDATE | SELL | ticket=" + (string)ticket +
                               " newSL=" + DoubleToString(newSL, _Digits));
                  }
               }
            }
         }
      }
   }
}

//------------------------------ Signal and entry --------------------
void EvaluateH2(const MqlTick &tick)
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      LogReject("terminal disconnected");
      return;
   }

   if(InpAllowTrading)
   {
      string envWhy;
      if(!TradingEnvironmentOK(envWhy))
      {
         LogReject(envWhy);
         return;
      }
   }

   if(InpOnePositionOnly && HasOurPosition())
   {
      LogReject("our position already open");
      return;
   }
   if(InpOnePositionOnly && HasAnyPositionOnSymbol())
   {
      LogReject("another position exists on this symbol");
      return;
   }

   if(g_waveLocked)
   {
      LogReject("wave lock active");
      return;
   }

   if(g_lastEntryTime > 0 && (TimeCurrent()-g_lastEntryTime) < InpSignalCooldownSeconds)
   {
      LogReject("entry cooldown active");
      return;
   }

   double point = PointSize();
   if(point <= 0.0) return;

   double spreadPts = (tick.ask-tick.bid)/point;
   if(spreadPts > InpMaxSpreadPoints)
   {
      LogReject("spread too wide: " + DoubleToString(spreadPts, 1));
      return;
   }

   double boxHigh, boxLow;
   int boxTicks = 0;
   if(!BuildCompressionBox(tick.time_msc, boxHigh, boxLow, boxTicks))
   {
      LogReject("insufficient ticks for compression box");
      return;
   }

   double boxRangePts = (boxHigh-boxLow)/point;
   if(boxRangePts > InpMaxBoxRangePoints)
   {
      LogReject("box range too wide: " + DoubleToString(boxRangePts, 1) + " pts");
      return;
   }

   double oldMid;
   long oldTime;
   long target = tick.time_msc - (long)InpVelocitySeconds*1000;
   if(!GetMidAtOrBefore(target, oldMid, oldTime))
   {
      LogReject("no velocity reference tick");
      return;
   }

   double mid = (tick.bid+tick.ask)*0.5;
   double elapsed = (double)(tick.time_msc-oldTime)/1000.0;
   if(elapsed <= 0.0)
   {
      LogReject("invalid velocity time interval");
      return;
   }

   double displacementPts = (mid-oldMid)/point;
   double velocity = displacementPts/elapsed;

   bool buySignal  = (mid > boxHigh + InpBreakoutBufferPoints*point &&
                      velocity >= InpMinVelocityPtsPerSec);
   bool sellSignal = (mid < boxLow - InpBreakoutBufferPoints*point &&
                      velocity <= -InpMinVelocityPtsPerSec);

   if(!buySignal && !sellSignal)
   {
      LogReject("no confirmed breakout | range=" + DoubleToString(boxRangePts,1) +
                " displacement=" + DoubleToString(displacementPts,1) +
                " velocity=" + DoubleToString(velocity,1));
      return;
   }

   ENUM_ORDER_TYPE orderType = buySignal ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double entry = buySignal ? tick.ask : tick.bid;
   double sl = buySignal ?
               boxHigh-InpStopBehindEdgePoints*point :
               boxLow+InpStopBehindEdgePoints*point;
   sl = NormalizeDouble(sl, _Digits);

   double stopPts = MathAbs(entry-sl)/point;
   if(stopPts < InpMinStopPoints || stopPts > InpMaxStopPoints)
   {
      LogReject("edge stop outside allowed range: " + DoubleToString(stopPts,1) +
                " pts; allowed=" + DoubleToString(InpMinStopPoints,1) +
                "-" + DoubleToString(InpMaxStopPoints,1));
      return;
   }

   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double brokerMin = (double)MathMax(stopsLevel, freezeLevel)*point;
   if(buySignal && (tick.bid-sl) < brokerMin)
   {
      LogReject("buy SL violates broker stops/freeze distance");
      return;
   }
   if(sellSignal && (sl-tick.ask) < brokerMin)
   {
      LogReject("sell SL violates broker stops/freeze distance");
      return;
   }

   double volume, riskMoney, estimatedLoss;
   string riskWhy;
   if(!CalculateRiskVolume(orderType, entry, sl, volume, riskMoney, estimatedLoss, riskWhy))
   {
      LogReject("risk sizing failed: " + riskWhy);
      return;
   }

   LogAccept((buySignal ? "BUY" : "SELL") +
             " | boxHigh=" + DoubleToString(boxHigh,_Digits) +
             " boxLow=" + DoubleToString(boxLow,_Digits) +
             " boxRangePts=" + DoubleToString(boxRangePts,1) +
             " displacementPts=" + DoubleToString(displacementPts,1) +
             " velocityPtsSec=" + DoubleToString(velocity,1) +
             " spreadPts=" + DoubleToString(spreadPts,1) +
             " entry=" + DoubleToString(entry,_Digits) +
             " SL=" + DoubleToString(sl,_Digits) +
             " stopPts=" + DoubleToString(stopPts,1) +
             " volume=" + DoubleToString(volume,VolumeDigits()) +
             " riskMoney=" + DoubleToString(riskMoney,2) +
             " estimatedLoss=" + DoubleToString(estimatedLoss,2));

   if(!InpAllowTrading)
   {
      LogMsg("DRY_RUN_SIGNAL | no order sent | " +
             string(buySignal ? "BUY" : "SELL") +
             " | volume_if_enabled=" + DoubleToString(volume,VolumeDigits()) +
             " | riskMoney=" + DoubleToString(riskMoney,2));
      g_lastSignalTime = TimeCurrent();
      LockWave(boxHigh, boxLow);
      return;
   }

   if(buySignal)
      trade.Buy(volume, _Symbol, 0.0, sl, 0.0, "XTRD V204 H2 BUY");
   else
      trade.Sell(volume, _Symbol, 0.0, sl, 0.0, "XTRD V204 H2 SELL");

   uint retcode = trade.ResultRetcode();
   if(retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED ||
      retcode == TRADE_RETCODE_DONE_PARTIAL)
   {
      g_lastEntryTime = TimeCurrent();
      g_lastSignalTime = TimeCurrent();
      LockWave(boxHigh, boxLow);
      LogMsg("ORDER_ACCEPTED | retcode=" + IntegerToString((int)retcode) +
             " description=" + trade.ResultRetcodeDescription() +
             " deal=" + (string)trade.ResultDeal() +
             " order=" + (string)trade.ResultOrder());
   }
   else
   {
      LogMsg("ORDER_FAILED | retcode=" + IntegerToString((int)retcode) +
             " description=" + trade.ResultRetcodeDescription() +
             " lastError=" + IntegerToString(GetLastError()));
   }
}

//------------------------------ Lifecycle ---------------------------
int OnInit()
{
   if(InpRiskPercent <= 0.0 || InpRiskPercent > InpMaxRiskPercent ||
      InpMaxRiskPercent > 1.0)
   {
      Print("INIT_FAILED | invalid risk configuration; risk must be >0 and <= hard cap <=1%");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpCompressionSeconds <= InpVelocitySeconds ||
      InpVelocitySeconds < 1 || InpMinBoxTicks < 2 ||
      InpMinStopPoints <= 0.0 || InpMaxStopPoints < InpMinStopPoints)
   {
      Print("INIT_FAILED | invalid H2 parameters");
      return INIT_PARAMETERS_INCORRECT;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   LogMsg("INIT | version=2.040 | engine=H2_PRO | risk=" +
          DoubleToString(InpRiskPercent,2) + "% | trading=" +
          (InpAllowTrading ? "ENABLED" : "DISABLED") +
          " | point=" + DoubleToString(PointSize(),_Digits) +
          " | digits=" + IntegerToString(_Digits) +
          " | minLot=" + DoubleToString(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),VolumeDigits()) +
          " | lotStep=" + DoubleToString(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),VolumeDigits()) +
          " | stopsLevel=" + IntegerToString((int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)) +
          " | freezeLevel=" + IntegerToString((int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL)));
   return INIT_SUCCEEDED;
}

void OnTick()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   if(tick.bid <= 0.0 || tick.ask <= 0.0 || tick.ask < tick.bid) return;

   AddTick(tick);
   ManageOpenPosition(tick);

   double mid = (tick.bid+tick.ask)*0.5;
   UpdateWaveLock(mid);

   // Evaluate every received tick; rejection diagnostics are throttled separately.
   EvaluateH2(tick);
}

void OnDeinit(const int reason)
{
   LogMsg("DEINIT | reason=" + IntegerToString(reason) +
          " | ticks_cached=" + IntegerToString(g_tickCount));
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(HistoryDealSelect(trans.deal))
      {
         string sym = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
         long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
         if(sym == _Symbol && (ulong)magic == InpMagic)
         {
            long entryType = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
            double price = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
            double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
            double commission = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
            double swap = HistoryDealGetDouble(trans.deal, DEAL_SWAP);
            LogMsg("DEAL | entry=" + IntegerToString((int)entryType) +
                   " price=" + DoubleToString(price,_Digits) +
                   " profit=" + DoubleToString(profit,2) +
                   " commission=" + DoubleToString(commission,2) +
                   " swap=" + DoubleToString(swap,2));
         }
      }
   }
}
//+------------------------------------------------------------------+
