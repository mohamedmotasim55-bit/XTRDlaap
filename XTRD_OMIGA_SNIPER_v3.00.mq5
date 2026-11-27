//+------------------------------------------------------------------+
//| XTRD OMIGA - GOLD ADAPTIVE SCALPER v2.00                         |
//| New multi-engine M1 scalping architecture for XAUUSD             |
//| Engines: Trend Pullback, Breakout Retest, Liquidity Sweep, Range |
//| Independent hedging positions, per-ticket SL/TP and trailing     |
//| No daily-loss, equity-drawdown, or EA position-count stop.        |
//+------------------------------------------------------------------+
#property strict
#property version   "2.00"
#property description "Multi-engine XAUUSD scalper with independent setups, hedging positions, balance-step lots and per-position ATR/structure trailing."

#include <Trade/Trade.mqh>

//------------------------------- INPUTS -----------------------------
input group "01. General / Execution"
input string InpTradeSymbol                  = "";          // Empty = chart symbol
input ulong  InpMagicNumber                  = 26112520;
input bool   InpEnableTrading                = true;
input bool   InpResearchMode                 = false;       // true = log signals only
input bool   InpRequireHedgingAccount        = true;        // Needed for truly independent same-symbol positions
input int    InpDeviationPoints              = 30;
input int    InpMaxSpreadPoints               = 45;          // Broker-cost filter, not a loss limit; 0 disables
input double InpMaxSpreadToTarget             = 0.40;        // Current spread / expected TP distance
input int    InpTimerSeconds                  = 1;

input group "02. Volume Progression"
input double InpInitialLot                   = 0.01;
input double InpMaximumLotPerPosition        = 0.05;
input double InpLotIncrement                 = 0.01;
input double InpBalanceStepForLotIncrease    = 20.0;
input double InpReferenceBalance             = 10.0;         // Initial lot is retained below this balance

input group "03. Strategy Engines"
input bool   InpEnableTrendPullback           = true;
input bool   InpEnableBreakoutRetest          = true;
input bool   InpEnableLiquiditySweep          = true;
input bool   InpEnableRangeScalping           = true;
input int    InpM1FastEMA                     = 9;
input int    InpM1SlowEMA                     = 21;
input int    InpM5FastEMA                     = 21;
input int    InpM5SlowEMA                     = 50;
input int    InpATRPeriod                     = 14;
input int    InpADXPeriod                     = 14;
input double InpTrendADXMinimum               = 20.0;
input double InpRangeADXMaximum               = 18.0;
input int    InpBreakoutLookback              = 12;
input int    InpSweepLookback                 = 10;
input int    InpRangeLookback                 = 20;
input double InpPullbackTouchATR              = 0.22;
input double InpBreakoutBufferATR             = 0.08;
input double InpRetestToleranceATR            = 0.18;
input double InpSweepPenetrationATR           = 0.04;
input double InpSweepWickMinimumATR           = 0.18;

input group "04. Initial Stop / Targets"
input double InpMinimumStopATR                = 0.45;
input double InpMaximumStopATR                = 1.80;
input double InpStopStructureBufferATR        = 0.10;
input double InpTrendTargetR                  = 1.35;
input double InpBreakoutTargetR               = 1.20;
input double InpSweepTargetR                  = 1.15;
input double InpRangeTargetR                  = 0.95;

input group "05. Break-even / Trailing"
input bool   InpEnableBreakEven               = true;
input double InpBreakEvenAtR                  = 0.55;
input double InpBreakEvenOffsetPoints         = 3.0;
input bool   InpEnableTrailing                = true;
input double InpTrailStartR                   = 0.85;
input double InpTrailDistanceATR              = 0.35;        // Uses ATR captured for each position at entry
input double InpTrailDistanceSpreadMultiple  = 2.0;
input double InpTrailMinimumDistancePoints   = 20.0;
input int    InpTrailMinimumStepPoints       = 4;
input double InpEstimatedRoundTurnFeePerLot  = 0.0;         // Account-currency estimate; 0 if unknown

input group "05b. Survivability Core (v3.00)"
input double InpMaxStopPoints                 = 65.0;        // Hard cap on initial stop distance (points)
input double InpFixedTargetR                  = 1.50;        // TP distance = stop distance x this
input int    InpMaxPositions                  = 1;           // Only one position may exist at a time
input int    InpEntryCooldownMinutes          = 12;          // Minimum gap between two entries
input int    InpTimeStopSeconds               = 25;          // Close trades that are not working
input double InpEquityDayLockPercent          = 15.0;        // Stop entries for the day after this drop from the day high-water

input group "06. Diagnostics"
input bool   InpWriteCSVLog                   = true;
input bool   InpVerboseJournal                = true;
input bool   InpShowChartStatus               = true;

//------------------------------- GLOBALS ----------------------------
CTrade trade;
string g_symbol = "";
int g_atrHandle = INVALID_HANDLE;
int g_adxHandle = INVALID_HANDLE;
int g_m1FastHandle = INVALID_HANDLE;
int g_m1SlowHandle = INVALID_HANDLE;
int g_m5FastHandle = INVALID_HANDLE;
int g_m5SlowHandle = INVALID_HANDLE;
int g_csv = INVALID_HANDLE;
datetime g_lastClosedM1Bar = 0;
datetime g_lastEntryTime = 0;
datetime g_dayStamp = 0;
double   g_dayHwm = 0.0;
bool     g_dayLocked = false;
datetime g_lastStatusTime = 0;
double g_lastATR = 0.0;
double g_lastADX = 0.0;
datetime g_lastEngineSignal[5];

#define ENGINE_TREND    1
#define ENGINE_BREAKOUT 2
#define ENGINE_SWEEP    3
#define ENGINE_RANGE    4

//------------------------------- SMALL HELPERS -----------------------
void Log(const string message)
{
   if(InpVerboseJournal)
      Print("[XTRD_GOLD_ADAPTIVE] ", message);
}

double PointValue()
{
   return SymbolInfoDouble(g_symbol, SYMBOL_POINT);
}

int DigitsValue()
{
   return (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
}

double TickSizeValue()
{
   double v = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   if(v <= 0.0) v = PointValue();
   return v;
}

double NormalizePriceDown(const double price)
{
   double step = TickSizeValue();
   if(step <= 0.0) return NormalizeDouble(price, DigitsValue());
   return NormalizeDouble(MathFloor(price / step + 1e-9) * step, DigitsValue());
}

double NormalizePriceUp(const double price)
{
   double step = TickSizeValue();
   if(step <= 0.0) return NormalizeDouble(price, DigitsValue());
   return NormalizeDouble(MathCeil(price / step - 1e-9) * step, DigitsValue());
}

int VolumeDigits(const double step)
{
   for(int d = 0; d <= 8; d++)
      if(MathAbs(NormalizeDouble(step, d) - step) < 1e-10) return d;
   return 8;
}

double NormalizeVolumeDown(const double requested)
{
   double vmin = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   if(vmin <= 0.0 || vmax <= 0.0 || step <= 0.0 || requested + 1e-9 < vmin)
      return 0.0;
   double value = MathMin(requested, MathMin(vmax, InpMaximumLotPerPosition));
   value = MathFloor(value / step + 1e-8) * step;
   value = NormalizeDouble(value, VolumeDigits(step));
   if(value + 1e-9 < vmin) return 0.0;
   return value;
}

string EngineName(const int engine)
{
   if(engine == ENGINE_TREND) return "TREND_PULLBACK";
   if(engine == ENGINE_BREAKOUT) return "BREAKOUT_RETEST";
   if(engine == ENGINE_SWEEP) return "LIQUIDITY_SWEEP";
   if(engine == ENGINE_RANGE) return "RANGE_EDGE";
   return "UNKNOWN";
}

string EngineTag(const int engine)
{
   if(engine == ENGINE_TREND) return "GH20|T";
   if(engine == ENGINE_BREAKOUT) return "GH20|B";
   if(engine == ENGINE_SWEEP) return "GH20|S";
   if(engine == ENGINE_RANGE) return "GH20|R";
   return "GH20|?";
}

void CsvEvent(const string eventName, const string details)
{
   if(g_csv == INVALID_HANDLE) return;
   MqlTick tick;
   double spread = 0.0;
   if(SymbolInfoTick(g_symbol, tick) && PointValue() > 0.0)
      spread = (tick.ask - tick.bid) / PointValue();
   FileWrite(g_csv, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), eventName,
             g_symbol, DoubleToString(g_lastATR, DigitsValue()),
             DoubleToString(g_lastADX, 2), DoubleToString(spread, 1), details);
   FileFlush(g_csv);
}

void EventLog(const string eventName, const string details)
{
   Log(eventName + " " + details);
   CsvEvent(eventName, details);
}

bool IsHedgingAccount()
{
   ENUM_ACCOUNT_MARGIN_MODE mode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   bool hedgeMode = (mode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   bool oppositeAllowed = (bool)AccountInfoInteger(ACCOUNT_HEDGE_ALLOWED);
   return (hedgeMode && oppositeAllowed);
}

bool TradingAllowed()
{
   if(InpResearchMode || !InpEnableTrading) return false;
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) return false;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) return false;
   return true;
}

bool ReadBufferValue(const int handle, const int bufferIndex, const int shift, double &value)
{
   value = 0.0;
   if(handle == INVALID_HANDLE) return false;
   double data[1];
   if(CopyBuffer(handle, bufferIndex, shift, 1, data) != 1) return false;
   value = data[0];
   return MathIsValidNumber(value);
}

bool ReadMarketContext(double &atr, double &adx,
                       double &m1Fast, double &m1Slow,
                       double &m5Fast, double &m5Slow)
{
   if(!ReadBufferValue(g_atrHandle, 0, 1, atr) || atr <= 0.0) return false;
   if(!ReadBufferValue(g_adxHandle, 0, 1, adx)) return false;
   if(!ReadBufferValue(g_m1FastHandle, 0, 1, m1Fast)) return false;
   if(!ReadBufferValue(g_m1SlowHandle, 0, 1, m1Slow)) return false;
   if(!ReadBufferValue(g_m5FastHandle, 0, 1, m5Fast)) return false;
   if(!ReadBufferValue(g_m5SlowHandle, 0, 1, m5Slow)) return false;
   return true;
}

bool GetRates(MqlRates &rates[], const int count)
{
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(g_symbol, PERIOD_M1, 0, count, rates);
   return (copied >= count);
}

bool GetRange(const MqlRates &rates[], const int first, const int count,
              double &highest, double &lowest)
{
   int total = ArraySize(rates);
   if(first < 1 || count < 1 || first + count > total) return false;
   highest = -DBL_MAX;
   lowest = DBL_MAX;
   for(int i = first; i < first + count; i++)
   {
      if(rates[i].high > highest) highest = rates[i].high;
      if(rates[i].low < lowest) lowest = rates[i].low;
   }
   return (highest > lowest && lowest < DBL_MAX && highest > -DBL_MAX);
}

double LowerWick(const MqlRates &bar)
{
   return MathMin(bar.open, bar.close) - bar.low;
}

double UpperWick(const MqlRates &bar)
{
   return bar.high - MathMax(bar.open, bar.close);
}

//------------------------------- SIGNAL ENGINES ----------------------
int DetectTrendPullback(const MqlRates &rates[], const double atr, const double adx,
                         const double m1Fast, const double m1Slow,
                         const double m5Fast, const double m5Slow)
{
   if(!InpEnableTrendPullback || adx < InpTrendADXMinimum) return 0;
   MqlRates c = rates[1];
   MqlRates p = rates[2];
   double body = MathAbs(c.close - c.open);
   bool upTrend = (m1Fast > m1Slow && m5Fast > m5Slow);
   bool downTrend = (m1Fast < m1Slow && m5Fast < m5Slow);
   bool longPullback = upTrend && c.low <= m1Fast + atr * InpPullbackTouchATR &&
                       c.close > m1Fast && c.close > c.open &&
                       c.close >= p.close && body >= atr * 0.06;
   bool shortPullback = downTrend && c.high >= m1Fast - atr * InpPullbackTouchATR &&
                        c.close < m1Fast && c.close < c.open &&
                        c.close <= p.close && body >= atr * 0.06;
   if(longPullback) return 1;
   if(shortPullback) return -1;
   return 0;
}

int DetectBreakoutRetest(const MqlRates &rates[], const double atr)
{
   if(!InpEnableBreakoutRetest) return 0;
   double rangeHigh, rangeLow;
   if(!GetRange(rates, 3, InpBreakoutLookback, rangeHigh, rangeLow)) return 0;
   MqlRates breakout = rates[2];
   MqlRates retest = rates[1];
   double breakoutBuffer = atr * InpBreakoutBufferATR;
   double tolerance = atr * InpRetestToleranceATR;
   bool longRetest = breakout.close > rangeHigh + breakoutBuffer &&
                     retest.low <= rangeHigh + tolerance &&
                     retest.close > rangeHigh && retest.close > retest.open;
   bool shortRetest = breakout.close < rangeLow - breakoutBuffer &&
                      retest.high >= rangeLow - tolerance &&
                      retest.close < rangeLow && retest.close < retest.open;
   if(longRetest) return 1;
   if(shortRetest) return -1;
   return 0;
}

int DetectLiquiditySweep(const MqlRates &rates[], const double atr)
{
   if(!InpEnableLiquiditySweep) return 0;
   double priorHigh, priorLow;
   if(!GetRange(rates, 2, InpSweepLookback, priorHigh, priorLow)) return 0;
   MqlRates c = rates[1];
   bool bullishSweep = c.low < priorLow - atr * InpSweepPenetrationATR &&
                       c.close > priorLow && c.close > c.open &&
                       LowerWick(c) >= atr * InpSweepWickMinimumATR;
   bool bearishSweep = c.high > priorHigh + atr * InpSweepPenetrationATR &&
                       c.close < priorHigh && c.close < c.open &&
                       UpperWick(c) >= atr * InpSweepWickMinimumATR;
   if(bullishSweep) return 1;
   if(bearishSweep) return -1;
   return 0;
}

int DetectRangeEdge(const MqlRates &rates[], const double atr, const double adx)
{
   if(!InpEnableRangeScalping || adx > InpRangeADXMaximum) return 0;
   double rangeHigh, rangeLow;
   if(!GetRange(rates, 2, InpRangeLookback, rangeHigh, rangeLow)) return 0;
   double width = rangeHigh - rangeLow;
   if(width < atr * 0.80) return 0;
   MqlRates c = rates[1];
   bool atLowerEdge = c.low <= rangeLow + width * 0.18 &&
                      c.close >= rangeLow + width * 0.25 && c.close > c.open &&
                      LowerWick(c) >= atr * 0.10;
   bool atUpperEdge = c.high >= rangeHigh - width * 0.18 &&
                      c.close <= rangeHigh - width * 0.25 && c.close < c.open &&
                      UpperWick(c) >= atr * 0.10;
   if(atLowerEdge) return 1;
   if(atUpperEdge) return -1;
   return 0;
}

//------------------------------- LOT / COST / STOPS ------------------
double DynamicLot()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double steps = 0.0;
   if(InpBalanceStepForLotIncrease > 0.0 && balance > InpReferenceBalance)
      steps = MathFloor((balance - InpReferenceBalance) / InpBalanceStepForLotIncrease);
   double requested = InpInitialLot + steps * InpLotIncrement;
   requested = MathMin(requested, InpMaximumLotPerPosition);
   return NormalizeVolumeDown(requested);
}

double BrokerStopDistance()
{
   double point = PointValue();
   long stops = SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze = SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long level = (long)MathMax((double)stops, (double)freeze);
   return MathMax(0.0, (double)level * point) + 2.0 * TickSizeValue();
}

bool SpreadAcceptable(const MqlTick &tick, const double expectedTargetDistance)
{
   double point = PointValue();
   if(point <= 0.0 || expectedTargetDistance <= 0.0) return false;
   double spreadPrice = tick.ask - tick.bid;
   double spreadPoints = spreadPrice / point;
   if(InpMaxSpreadPoints > 0 && spreadPoints > InpMaxSpreadPoints)
   {
      EventLog("ENTRY_REJECT", StringFormat("reason=SPREAD_ABOVE_MAX spread_pts=%.1f max_pts=%d", spreadPoints, InpMaxSpreadPoints));
      return false;
   }
   if(InpMaxSpreadToTarget > 0.0 && spreadPrice / expectedTargetDistance > InpMaxSpreadToTarget)
   {
      EventLog("ENTRY_REJECT", StringFormat("reason=SPREAD_COST_RATIO spread_target=%.3f max=%.3f", spreadPrice / expectedTargetDistance, InpMaxSpreadToTarget));
      return false;
   }
   return true;
}

bool CalculateStops(const int engine, const int direction, const MqlRates &rates[],
                    const double atr, const double entry, const double spread,
                    double &sl, double &tp, double &initialRisk, double &targetR)
{
   double structuralExtreme = 0.0;
   if(direction > 0)
   {
      if(engine == ENGINE_TREND || engine == ENGINE_RANGE)
      {
         int n = (engine == ENGINE_TREND ? 5 : 3);
         double h, l;
         if(!GetRange(rates, 1, n, h, l)) return false;
         structuralExtreme = l;
      }
      else structuralExtreme = rates[1].low;
   }
   else
   {
      if(engine == ENGINE_TREND || engine == ENGINE_RANGE)
      {
         int n = (engine == ENGINE_TREND ? 5 : 3);
         double h, l;
         if(!GetRange(rates, 1, n, h, l)) return false;
         structuralExtreme = h;
      }
      else structuralExtreme = rates[1].high;
   }

   double buffer = MathMax(atr * InpStopStructureBufferATR, spread * 0.50);
   double structuralDistance = (direction > 0 ? entry - structuralExtreme : structuralExtreme - entry) + buffer;
   if(structuralDistance <= 0.0) return false;
   if(structuralDistance > atr * InpMaximumStopATR)
   {
      EventLog("ENTRY_REJECT", StringFormat("engine=%s reason=STRUCTURE_TOO_WIDE distance_atr=%.2f", EngineName(engine), structuralDistance / atr));
      return false;
   }

   double brokerMin = BrokerStopDistance() + spread;
   initialRisk = MathMax(atr * InpMinimumStopATR, MathMax(structuralDistance, brokerMin));
   if(initialRisk > atr * InpMaximumStopATR)
   {
      EventLog("ENTRY_REJECT", StringFormat("engine=%s reason=STOP_EXCEEDS_ATR_MAX risk_atr=%.2f", EngineName(engine), initialRisk / atr));
      return false;
   }

   // Survivability core: never risk more than the cash-equivalent of InpMaxStopPoints.
   if(InpMaxStopPoints > 0.0)
      initialRisk = MathMin(initialRisk, InpMaxStopPoints * PointValue());
   initialRisk = MathMax(initialRisk, brokerMin);
   if(initialRisk > atr * InpMaximumStopATR) return false;
   targetR = (InpFixedTargetR > 0.0 ? InpFixedTargetR : InpTrendTargetR);

   if(direction > 0)
   {
      sl = NormalizePriceDown(entry - initialRisk);
      initialRisk = entry - sl;
      tp = NormalizePriceUp(entry + initialRisk * targetR);
   }
   else
   {
      sl = NormalizePriceUp(entry + initialRisk);
      initialRisk = sl - entry;
      tp = NormalizePriceDown(entry - initialRisk * targetR);
   }
   if(initialRisk <= 0.0 || tp <= 0.0) return false;
   return true;
}

bool CheckMargin(const ENUM_ORDER_TYPE orderType, const double volume, const double price)
{
   double required = 0.0;
   if(!OrderCalcMargin(orderType, g_symbol, volume, price, required))
   {
      EventLog("MARGIN_CHECK_ERROR", StringFormat("error=%d volume=%.2f", GetLastError(), volume));
      return false;
   }
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(required > freeMargin)
   {
      EventLog("MARGIN_SKIP", StringFormat("volume=%.2f required=%.2f free=%.2f", volume, required, freeMargin));
      return false;
   }
   return true;
}

//------------------------------- POSITION STATE ----------------------
string StateKey(const string suffix, const long identifier)
{
   string symbolKey = g_symbol;
   StringReplace(symbolKey, ".", "");
   StringReplace(symbolKey, "_", "");
   if(StringLen(symbolKey) > 8) symbolKey = StringSubstr(symbolKey, 0, 8);
   long login = (long)AccountInfoInteger(ACCOUNT_LOGIN);
   return StringFormat("XG20%I64d_%I64u_%s_%s_%I64d", login, InpMagicNumber, symbolKey, suffix, identifier);
}

bool GetPositionByIdentifier(const long identifier, ulong &ticket)
{
   ticket = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if((long)PositionGetInteger(POSITION_IDENTIFIER) == identifier)
      {
         ticket = t;
         return true;
      }
   }
   return false;
}

void SavePositionState(const long identifier, const double risk, const double atr,
                       const double bestPrice, const double worstPrice,
                       const double openPrice, const int engine, const int direction)
{
   if(identifier <= 0) return;
   GlobalVariableSet(StateKey("R", identifier), risk);
   GlobalVariableSet(StateKey("A", identifier), atr);
   GlobalVariableSet(StateKey("B", identifier), bestPrice);  // MFE extreme
   GlobalVariableSet(StateKey("W", identifier), worstPrice); // MAE extreme
   GlobalVariableSet(StateKey("O", identifier), openPrice);
   GlobalVariableSet(StateKey("E", identifier), (double)engine);
   GlobalVariableSet(StateKey("D", identifier), (double)direction);
}

void CaptureLastFilledPosition(const double requestedRisk, const double atr,
                               const int engine, const double targetR)
{
   ulong deal = trade.ResultDeal();
   if(deal == 0 || !HistoryDealSelect(deal)) return;
   long identifier = (long)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   ulong ticket = 0;
   if(!GetPositionByIdentifier(identifier, ticket)) return;
   if(!PositionSelectByTicket(ticket)) return;

   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   int direction = (type == POSITION_TYPE_BUY ? 1 : -1);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double actualSL = PositionGetDouble(POSITION_SL);
   double actualTP = PositionGetDouble(POSITION_TP);
   bool missingSL = (actualSL <= 0.0);
   double risk = (actualSL > 0.0 ? MathAbs(openPrice - actualSL) : requestedRisk);
   if(risk <= 0.0) risk = requestedRisk;

   // Re-anchor TP to the actual fill, preserving the actual initial stop distance.
   double desiredTP = (direction > 0 ? NormalizePriceUp(openPrice + risk * targetR)
                                     : NormalizePriceDown(openPrice - risk * targetR));
   if(actualSL <= 0.0)
      actualSL = (direction > 0 ? NormalizePriceDown(openPrice - risk) : NormalizePriceUp(openPrice + risk));
   if(desiredTP > 0.0 && (missingSL || MathAbs(desiredTP - actualTP) > TickSizeValue()))
   {
      bool reanchored = trade.PositionModify(ticket, actualSL, desiredTP);
      uint reanchorCode = trade.ResultRetcode();
      if(!reanchored || (reanchorCode != TRADE_RETCODE_DONE && reanchorCode != TRADE_RETCODE_NO_CHANGES))
         EventLog("FILL_REANCHOR_WARNING", StringFormat("ticket=%I64u retcode=%u description=%s", ticket, reanchorCode, trade.ResultRetcodeDescription()));
      else
         EventLog("FILL_REANCHORED", StringFormat("ticket=%I64u open=%.5f sl=%.5f tp=%.5f risk=%.5f targetR=%.2f", ticket, openPrice, actualSL, desiredTP, risk, targetR));
   }

   SavePositionState(identifier, risk, atr, openPrice, openPrice, openPrice, engine, direction);
   EventLog("POSITION_TRACKED", StringFormat("ticket=%I64u id=%I64d engine=%s direction=%d risk=%.5f atr_entry=%.5f", ticket, identifier, EngineName(engine), direction, risk, atr));
}

void EnsurePositionState(const ulong ticket, const double currentATR)
{
   if(!PositionSelectByTicket(ticket)) return;
   long identifier = (long)PositionGetInteger(POSITION_IDENTIFIER);
   if(identifier <= 0) return;
   string keyR = StateKey("R", identifier);
   if(GlobalVariableCheck(keyR))
   {
      if((!GlobalVariableCheck(StateKey("A", identifier)) || GlobalVariableGet(StateKey("A", identifier)) <= 0.0) && currentATR > 0.0)
         GlobalVariableSet(StateKey("A", identifier), currentATR);
      if(!GlobalVariableCheck(StateKey("B", identifier)))
         GlobalVariableSet(StateKey("B", identifier), PositionGetDouble(POSITION_PRICE_OPEN));
      if(!GlobalVariableCheck(StateKey("W", identifier)))
         GlobalVariableSet(StateKey("W", identifier), PositionGetDouble(POSITION_PRICE_OPEN));
      if(!GlobalVariableCheck(StateKey("O", identifier)))
         GlobalVariableSet(StateKey("O", identifier), PositionGetDouble(POSITION_PRICE_OPEN));
      return;
   }

   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);
   double risk = (sl > 0.0 ? MathAbs(open - sl) : currentATR * InpMinimumStopATR);
   if(risk <= 0.0) risk = MathMax(currentATR * InpMinimumStopATR, TickSizeValue() * 5.0);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double best = open;
   MqlTick tick;
   if(SymbolInfoTick(g_symbol, tick)) best = (type == POSITION_TYPE_BUY ? tick.bid : tick.ask);
   int engine = ENGINE_TREND;
   string comment = PositionGetString(POSITION_COMMENT);
   if(StringFind(comment, "|B") >= 0) engine = ENGINE_BREAKOUT;
   else if(StringFind(comment, "|S") >= 0) engine = ENGINE_SWEEP;
   else if(StringFind(comment, "|R") >= 0) engine = ENGINE_RANGE;
   SavePositionState(identifier, risk, currentATR, best, best, open, engine, (type == POSITION_TYPE_BUY ? 1 : -1));
   EventLog("POSITION_STATE_RECOVERED", StringFormat("ticket=%I64u id=%I64d risk=%.5f atr_entry_est=%.5f", ticket, identifier, risk, currentATR));
}

bool TrailCanModify(const long identifier)
{
   string key = StateKey("T", identifier);
   datetime now = TimeCurrent();
   if(GlobalVariableCheck(key))
      return (now > (datetime)GlobalVariableGet(key));
   return true;
}

void MarkTrailModified(const long identifier)
{
   GlobalVariableSet(StateKey("T", identifier), (double)TimeCurrent());
}

void DeletePositionState(const long identifier)
{
   if(identifier <= 0) return;
   GlobalVariableDel(StateKey("R", identifier));
   GlobalVariableDel(StateKey("A", identifier));
   GlobalVariableDel(StateKey("B", identifier));
   GlobalVariableDel(StateKey("E", identifier));
   GlobalVariableDel(StateKey("W", identifier));
   GlobalVariableDel(StateKey("O", identifier));
   GlobalVariableDel(StateKey("D", identifier));
   GlobalVariableDel(StateKey("T", identifier));
}

//------------------------------- ENTRY EXECUTION ---------------------
bool OpenEngineTrade(const int engine, const int direction, const MqlRates &rates[],
                     const double atr)
{
   if(CountOurPositions() >= MathMax(1, InpMaxPositions))
   {
      EventLog("ENTRY_REJECT", StringFormat("engine=%s reason=POSITION_CAP open=%d cap=%d", EngineName(engine), CountOurPositions(), InpMaxPositions));
      return false;
   }
   if(InpEntryCooldownMinutes > 0 && g_lastEntryTime > 0 &&
      TimeCurrent() - g_lastEntryTime < InpEntryCooldownMinutes * 60)
   {
      EventLog("ENTRY_REJECT", StringFormat("engine=%s reason=COOLDOWN", EngineName(engine)));
      return false;
   }
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick)) return false;
   double spread = tick.ask - tick.bid;
   double entry = (direction > 0 ? tick.ask : tick.bid);
   double sl = 0.0, tp = 0.0, risk = 0.0, targetR = 0.0;

   if(!CalculateStops(engine, direction, rates, atr, entry, spread, sl, tp, risk, targetR))
      return false;
   double targetDistance = MathAbs(tp - entry);
   if(!SpreadAcceptable(tick, targetDistance)) return false;

   double volume = DynamicLot();
   if(volume <= 0.0)
   {
      EventLog("ENTRY_REJECT", StringFormat("engine=%s reason=LOT_BELOW_BROKER_MIN requested=%.3f broker_min=%.3f", EngineName(engine), InpInitialLot, SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN)));
      return false;
   }
   ENUM_ORDER_TYPE orderType = (direction > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!CheckMargin(orderType, volume, entry)) return false;

   // Recheck broker stop geometry against the current Bid/Ask immediately before sending.
   double minStop = BrokerStopDistance();
   if(direction > 0 && (tick.bid - sl < minStop || tp - tick.ask < minStop))
   {
      EventLog("ENTRY_REJECT", StringFormat("engine=%s reason=INVALID_BUY_STOP_GEOMETRY", EngineName(engine)));
      return false;
   }
   if(direction < 0 && (sl - tick.ask < minStop || tick.bid - tp < minStop))
   {
      EventLog("ENTRY_REJECT", StringFormat("engine=%s reason=INVALID_SELL_STOP_GEOMETRY", EngineName(engine)));
      return false;
   }

   string comment = EngineTag(engine);
   bool sent = false;
   if(direction > 0)
      sent = trade.Buy(volume, g_symbol, 0.0, sl, tp, comment);
   else
      sent = trade.Sell(volume, g_symbol, 0.0, sl, tp, comment);

   uint retcode = trade.ResultRetcode();
   if(!sent || (retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_DONE_PARTIAL && retcode != TRADE_RETCODE_PLACED))
   {
      EventLog("ORDER_REJECTED", StringFormat("engine=%s dir=%s lot=%.2f retcode=%u description=%s", EngineName(engine), (direction > 0 ? "BUY" : "SELL"), volume, retcode, trade.ResultRetcodeDescription()));
      return false;
   }

   g_lastEntryTime = TimeCurrent();
   EventLog("ENTRY_FILLED", StringFormat("engine=%s dir=%s lot=%.2f price=%.5f sl=%.5f tp=%.5f risk=%.5f targetR=%.2f deal=%I64u", EngineName(engine), (direction > 0 ? "BUY" : "SELL"), volume, trade.ResultPrice(), sl, tp, risk, targetR, trade.ResultDeal()));
   CaptureLastFilledPosition(risk, atr, engine, targetR);
   return true;
}

void EvaluateAllEngines()
{
   if(g_dayLocked) return;
   int requiredBars = (int)MathMax((double)(InpRangeLookback + 3), MathMax((double)(InpSweepLookback + 3), (double)(InpBreakoutLookback + 4)));
   requiredBars = (int)MathMax((double)requiredBars, 10.0);
   MqlRates rates[];
   if(!GetRates(rates, requiredBars))
   {
      EventLog("SIGNAL_WAIT", "reason=INSUFFICIENT_M1_HISTORY");
      return;
   }

   double atr, adx, m1Fast, m1Slow, m5Fast, m5Slow;
   if(!ReadMarketContext(atr, adx, m1Fast, m1Slow, m5Fast, m5Slow) || atr <= 0.0)
   {
      EventLog("SIGNAL_WAIT", "reason=INDICATOR_DATA_NOT_READY");
      return;
   }
   g_lastATR = atr;
   g_lastADX = adx;
   datetime signalBar = rates[1].time;

   int dirs[5];
   dirs[ENGINE_TREND] = DetectTrendPullback(rates, atr, adx, m1Fast, m1Slow, m5Fast, m5Slow);
   dirs[ENGINE_BREAKOUT] = DetectBreakoutRetest(rates, atr);
   dirs[ENGINE_SWEEP] = DetectLiquiditySweep(rates, atr);
   dirs[ENGINE_RANGE] = DetectRangeEdge(rates, atr, adx);

   // Do not double-count the same rejection/retest candle under overlapping labels.
   // Different engines can still trade together when their actual setup types differ.
   if(dirs[ENGINE_BREAKOUT] != 0 && dirs[ENGINE_TREND] == dirs[ENGINE_BREAKOUT])
   {
      EventLog("SIGNAL_DEDUP", "TREND_PULLBACK suppressed: same candle already qualified as BREAKOUT_RETEST");
      dirs[ENGINE_TREND] = 0;
   }
   if(dirs[ENGINE_SWEEP] != 0 && dirs[ENGINE_RANGE] == dirs[ENGINE_SWEEP])
   {
      EventLog("SIGNAL_DEDUP", "RANGE_EDGE suppressed: same rejection candle already qualified as LIQUIDITY_SWEEP");
      dirs[ENGINE_RANGE] = 0;
   }

   for(int engine = ENGINE_TREND; engine <= ENGINE_RANGE; engine++)
   {
      int direction = dirs[engine];
      if(direction == 0) continue;
      // Each engine gets its own bar fingerprint. Other engines may enter on this same M1 bar.
      if(g_lastEngineSignal[engine] == signalBar) continue;
      g_lastEngineSignal[engine] = signalBar;
      string details = StringFormat("engine=%s dir=%s bar=%s adx=%.2f atr=%.5f m1ema=%.5f/%.5f m5ema=%.5f/%.5f", EngineName(engine), (direction > 0 ? "BUY" : "SELL"), TimeToString(signalBar, TIME_DATE|TIME_MINUTES), adx, atr, m1Fast, m1Slow, m5Fast, m5Slow);
      EventLog("SIGNAL", details);
      if(TradingAllowed())
         OpenEngineTrade(engine, direction, rates, atr);
      else
         EventLog("SIGNAL_ONLY", StringFormat("engine=%s dir=%s", EngineName(engine), (direction > 0 ? "BUY" : "SELL")));
   }
}

//------------------------------- PER-TICKET TRAILING -----------------
void ManageOpenPositions()
{
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick)) return;
   double point = PointValue();
   if(point <= 0.0) return;
   double spread = tick.ask - tick.bid;
   double brokerMin = BrokerStopDistance();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      EnsurePositionState(ticket, g_lastATR);
      if(InpTimeStopSeconds > 0)
      {
         datetime openedAt = (datetime)PositionGetInteger(POSITION_TIME);
         double livePL = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         if(TimeCurrent() - openedAt >= InpTimeStopSeconds && livePL <= 0.0)
         {
            if(trade.PositionClose(ticket))
               EventLog("TIME_STOP", StringFormat("ticket=%I64u age=%d profit=%.2f", ticket, (int)(TimeCurrent() - openedAt), livePL));
            continue;
         }
      }
      long identifier = (long)PositionGetInteger(POSITION_IDENTIFIER);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double oldSL = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool isBuy = (type == POSITION_TYPE_BUY);

      string keyR = StateKey("R", identifier);
      string keyA = StateKey("A", identifier);
      string keyB = StateKey("B", identifier);
      string keyW = StateKey("W", identifier);
      if(!GlobalVariableCheck(keyR) || !GlobalVariableCheck(keyA) || !GlobalVariableCheck(keyB)) continue;
      double initialRisk = GlobalVariableGet(keyR);
      double atrEntry = GlobalVariableGet(keyA);
      double best = GlobalVariableGet(keyB);
      double worst = (GlobalVariableCheck(keyW) ? GlobalVariableGet(keyW) : open);
      if(initialRisk <= 0.0 || atrEntry <= 0.0) continue;

      double live = (isBuy ? tick.bid : tick.ask);
      if(isBuy && live > best) { best = live; GlobalVariableSet(keyB, best); }
      if(!isBuy && live < best) { best = live; GlobalVariableSet(keyB, best); }
      if(isBuy && live < worst) { worst = live; GlobalVariableSet(keyW, worst); }
      if(!isBuy && live > worst) { worst = live; GlobalVariableSet(keyW, worst); }
      double favorable = (isBuy ? best - open : open - best);
      if(favorable <= 0.0) continue;

      double feeDistance = 0.0;
      double tickValue = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = TickSizeValue();
      if(InpEstimatedRoundTurnFeePerLot > 0.0 && tickValue > 0.0 && tickSize > 0.0)
         feeDistance = InpEstimatedRoundTurnFeePerLot * tickSize / tickValue;
      double beOffset = MathMax(InpBreakEvenOffsetPoints * point, feeDistance);

      double candidate = oldSL;
      bool shouldModify = false;
      if(InpEnableBreakEven && favorable >= initialRisk * InpBreakEvenAtR)
      {
         double beSL = (isBuy ? open + beOffset : open - beOffset);
         if(isBuy && (oldSL <= 0.0 || beSL > candidate)) { candidate = beSL; shouldModify = true; }
         if(!isBuy && (oldSL <= 0.0 || beSL < candidate)) { candidate = beSL; shouldModify = true; }
      }

      if(InpEnableTrailing && favorable >= initialRisk * InpTrailStartR)
      {
         double trailDistance = MathMax(atrEntry * InpTrailDistanceATR,
                                MathMax(spread * InpTrailDistanceSpreadMultiple,
                                        InpTrailMinimumDistancePoints * point));
         trailDistance = MathMax(trailDistance, brokerMin);
         double trailSL = (isBuy ? best - trailDistance : best + trailDistance);
         if(InpEnableBreakEven && favorable >= initialRisk * InpBreakEvenAtR)
         {
            if(isBuy) trailSL = MathMax(trailSL, open + beOffset);
            else trailSL = MathMin(trailSL, open - beOffset);
         }
         if(isBuy && (oldSL <= 0.0 || trailSL > candidate)) { candidate = trailSL; shouldModify = true; }
         if(!isBuy && (oldSL <= 0.0 || trailSL < candidate)) { candidate = trailSL; shouldModify = true; }
      }
      if(!shouldModify) continue;

      // Respect live broker stop/freeze distance without ever moving an SL backwards.
      if(isBuy)
      {
         candidate = MathMin(candidate, tick.bid - brokerMin);
         candidate = NormalizePriceDown(candidate);
         if(candidate <= 0.0 || (oldSL > 0.0 && candidate <= oldSL + InpTrailMinimumStepPoints * point)) continue;
      }
      else
      {
         candidate = MathMax(candidate, tick.ask + brokerMin);
         candidate = NormalizePriceUp(candidate);
         if(candidate <= 0.0 || (oldSL > 0.0 && candidate >= oldSL - InpTrailMinimumStepPoints * point)) continue;
      }

      if(!TrailCanModify(identifier)) continue;
      bool modified = trade.PositionModify(ticket, candidate, tp);
      uint rc = trade.ResultRetcode();
      MarkTrailModified(identifier);
      if(modified && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_NO_CHANGES))
         EventLog("STOP_MODIFIED", StringFormat("ticket=%I64u id=%I64d side=%s sl=%.5f favorable_R=%.2f atr_entry=%.5f", ticket, identifier, (isBuy ? "BUY" : "SELL"), candidate, favorable / initialRisk, atrEntry));
      else if(rc != TRADE_RETCODE_NO_CHANGES)
         EventLog("STOP_MODIFY_REJECTED", StringFormat("ticket=%I64u rc=%u description=%s", ticket, rc, trade.ResultRetcodeDescription()));
   }
}

//------------------------------- STATUS / INIT -----------------------
int CountOurPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == g_symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) count++;
   }
   return count;
}

void UpdateStatus()
{
   if(!InpShowChartStatus) return;
   MqlTick tick;
   double spreadPts = 0.0;
   if(SymbolInfoTick(g_symbol, tick) && PointValue() > 0.0)
      spreadPts = (tick.ask - tick.bid) / PointValue();
   Comment("XTRD OMIGA GOLD ADAPTIVE SCALPER v2.00\n",
           "Symbol: ", g_symbol, " | Mode: ", (TradingAllowed() ? "TRADING" : "SIGNAL ONLY"), "\n",
           "ADX M1: ", DoubleToString(g_lastADX, 1), " | ATR M1: ", DoubleToString(g_lastATR, DigitsValue()),
           " | Spread: ", DoubleToString(spreadPts, 1), " points\n",
           "Open positions: ", CountOurPositions(), " | Dynamic lot: ", DoubleToString(DynamicLot(), 2), "\n",
           "Engines: Trend / Breakout-Retest / Sweep / Range | Multi-entry per M1 bar enabled\n",
           "No EA daily-loss stop, drawdown stop, or position-count cap.");
}

void OpenCsv()
{
   if(!InpWriteCSVLog) return;
   string safeSymbol = g_symbol;
   StringReplace(safeSymbol, ".", "_");
   StringReplace(safeSymbol, "/", "_");
   string fileName = StringFormat("XTRD_GOLD_ADAPTIVE_v2_%s_%I64u.csv", safeSymbol, InpMagicNumber);
   g_csv = FileOpen(fileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_ANSI, ';');
   if(g_csv == INVALID_HANDLE)
   {
      Log(StringFormat("CSV open failed, error=%d", GetLastError()));
      return;
   }
   if(FileSize(g_csv) == 0)
      FileWrite(g_csv, "time", "event", "symbol", "atr", "adx", "spread_points", "details");
   FileSeek(g_csv, 0, SEEK_END);
}

int OnInit()
{
   g_symbol = (InpTradeSymbol == "" ? _Symbol : InpTradeSymbol);
   if(!SymbolSelect(g_symbol, true))
   {
      Print("[XTRD_GOLD_ADAPTIVE] Cannot select symbol: ", g_symbol);
      return INIT_FAILED;
   }
   if(g_symbol != _Symbol)
   {
      Print("[XTRD_GOLD_ADAPTIVE] Attach the EA to the same symbol set in InpTradeSymbol; OnTick is driven by the chart symbol.");
      return INIT_FAILED;
   }
   if(InpRequireHedgingAccount && !IsHedgingAccount())
   {
      Print("[XTRD_GOLD_ADAPTIVE] A hedging account is required for independent simultaneous positions on the same symbol.");
      return INIT_FAILED;
   }
   if(InpInitialLot <= 0.0 || InpMaximumLotPerPosition < InpInitialLot ||
      InpLotIncrement < 0.0 || InpBalanceStepForLotIncrease < 0.0 || InpReferenceBalance < 0.0 ||
      InpATRPeriod < 2 || InpADXPeriod < 2 || InpM1FastEMA < 2 || InpM1SlowEMA <= InpM1FastEMA ||
      InpM5FastEMA < 2 || InpM5SlowEMA <= InpM5FastEMA || InpBreakoutLookback < 3 ||
      InpSweepLookback < 3 || InpRangeLookback < 5 || InpMinimumStopATR <= 0.0 ||
      InpMaximumStopATR <= InpMinimumStopATR || InpStopStructureBufferATR < 0.0 ||
      InpTrendTargetR <= 0.0 || InpBreakoutTargetR <= 0.0 || InpSweepTargetR <= 0.0 || InpRangeTargetR <= 0.0 ||
      InpBreakEvenAtR < 0.0 || InpTrailStartR < 0.0 || InpTrailDistanceATR < 0.0 ||
      InpTrailMinimumDistancePoints < 0.0 || InpMaxSpreadToTarget < 0.0)
   {
      Print("[XTRD_GOLD_ADAPTIVE] Invalid input parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(!InpEnableTrendPullback && !InpEnableBreakoutRetest && !InpEnableLiquiditySweep && !InpEnableRangeScalping)
   {
      Print("[XTRD_GOLD_ADAPTIVE] At least one strategy engine must be enabled.");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_atrHandle = iATR(g_symbol, PERIOD_M1, InpATRPeriod);
   g_adxHandle = iADX(g_symbol, PERIOD_M1, InpADXPeriod);
   g_m1FastHandle = iMA(g_symbol, PERIOD_M1, InpM1FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_m1SlowHandle = iMA(g_symbol, PERIOD_M1, InpM1SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_m5FastHandle = iMA(g_symbol, PERIOD_M5, InpM5FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_m5SlowHandle = iMA(g_symbol, PERIOD_M5, InpM5SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(g_atrHandle == INVALID_HANDLE || g_adxHandle == INVALID_HANDLE ||
      g_m1FastHandle == INVALID_HANDLE || g_m1SlowHandle == INVALID_HANDLE ||
      g_m5FastHandle == INVALID_HANDLE || g_m5SlowHandle == INVALID_HANDLE)
   {
      Print("[XTRD_GOLD_ADAPTIVE] Failed to create one or more indicator handles.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(g_symbol);
   trade.SetAsyncMode(false);

   g_lastClosedM1Bar = iTime(g_symbol, PERIOD_M1, 1); // Wait for the next fully closed M1 bar after attach.
   ReadBufferValue(g_atrHandle, 0, 1, g_lastATR);
   ReadBufferValue(g_adxHandle, 0, 1, g_lastADX);
   OpenCsv();
   EventSetTimer((int)MathMax(1.0, (double)InpTimerSeconds));

   EventLog("INITIALIZED", StringFormat("version=2.00 balance=%.2f hedging=%s initial_lot=%.2f max_lot=%.2f balance_step=%.2f engines=%s%s%s%s",
      AccountInfoDouble(ACCOUNT_BALANCE), (IsHedgingAccount() ? "true" : "false"), InpInitialLot,
      InpMaximumLotPerPosition, InpBalanceStepForLotIncrease,
      (InpEnableTrendPullback ? "TREND " : ""), (InpEnableBreakoutRetest ? "BREAKOUT " : ""),
      (InpEnableLiquiditySweep ? "SWEEP " : ""), (InpEnableRangeScalping ? "RANGE" : "")));
   EventLog("RISK_POLICY", "No daily-loss stop, no equity drawdown stop, no cash-risk entry cap, no EA position-count cap; broker margin/volume/stops rules remain active.");
   EventLog("ENTRY_POLICY", "Market execution after closed-bar confirmation; four independent signal fingerprints; multiple engines may enter during the same M1 bar; no global one-entry-per-minute limit.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_adxHandle != INVALID_HANDLE) IndicatorRelease(g_adxHandle);
   if(g_m1FastHandle != INVALID_HANDLE) IndicatorRelease(g_m1FastHandle);
   if(g_m1SlowHandle != INVALID_HANDLE) IndicatorRelease(g_m1SlowHandle);
   if(g_m5FastHandle != INVALID_HANDLE) IndicatorRelease(g_m5FastHandle);
   if(g_m5SlowHandle != INVALID_HANDLE) IndicatorRelease(g_m5SlowHandle);
   if(g_csv != INVALID_HANDLE) { FileFlush(g_csv); FileClose(g_csv); g_csv = INVALID_HANDLE; }
   Comment("");
}

void ManageEquityDayLock()
{
   if(InpEquityDayLockPercent <= 0.0) return;
   datetime stamp = (datetime)((long)TimeCurrent() - (long)TimeCurrent() % 86400);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(stamp != g_dayStamp)
   {
      g_dayStamp = stamp;
      g_dayHwm = equity;
      g_dayLocked = false;
   }
   if(equity > g_dayHwm) g_dayHwm = equity;
   if(!g_dayLocked && g_dayHwm > 0.0 && equity <= g_dayHwm * (1.0 - InpEquityDayLockPercent / 100.0))
   {
      g_dayLocked = true;
      EventLog("EQUITY_DAY_LOCK", StringFormat("equity=%.2f day_hwm=%.2f drop_pct=%.2f", equity, g_dayHwm, InpEquityDayLockPercent));
   }
}

void OnTick()
{
   ManageEquityDayLock();
   ManageOpenPositions();
   datetime closedBar = iTime(g_symbol, PERIOD_M1, 1);
   if(closedBar > 0 && closedBar != g_lastClosedM1Bar)
   {
      g_lastClosedM1Bar = closedBar;
      EvaluateAllEngines();
   }
   UpdateStatus();
}

void OnTimer()
{
   ManageOpenPositions();
   if(TimeCurrent() != g_lastStatusTime)
   {
      g_lastStatusTime = TimeCurrent();
      UpdateStatus();
   }
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0) return;
   if(!HistoryDealSelect(trans.deal)) return;
   string symbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   ulong magic = (ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   if(symbol != g_symbol || magic != InpMagicNumber) return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   long identifier = (long)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   long type = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   double volume = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   double price = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
   double commission = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   double swap = HistoryDealGetDouble(trans.deal, DEAL_SWAP);

   EventLog("DEAL", StringFormat("deal=%I64u position_id=%I64d entry=%s type=%s volume=%.2f price=%.5f profit=%.2f commission=%.2f swap=%.2f",
      trans.deal, identifier, EnumToString((ENUM_DEAL_ENTRY)entry), EnumToString((ENUM_DEAL_TYPE)type),
      volume, price, profit, commission, swap));
   if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
   {
      ulong stillOpenTicket = 0;
      bool remainsOpen = GetPositionByIdentifier(identifier, stillOpenTicket);
      if(!remainsOpen)
      {
         string keyR = StateKey("R", identifier);
         string keyA = StateKey("A", identifier);
         string keyB = StateKey("B", identifier);
         string keyW = StateKey("W", identifier);
         string keyO = StateKey("O", identifier);
         string keyE = StateKey("E", identifier);
         string keyD = StateKey("D", identifier);
         double r = (GlobalVariableCheck(keyR) ? GlobalVariableGet(keyR) : 0.0);
         double atr = (GlobalVariableCheck(keyA) ? GlobalVariableGet(keyA) : 0.0);
         double best = (GlobalVariableCheck(keyB) ? GlobalVariableGet(keyB) : price);
         double worst = (GlobalVariableCheck(keyW) ? GlobalVariableGet(keyW) : price);
         double open = (GlobalVariableCheck(keyO) ? GlobalVariableGet(keyO) : price);
         double direction = (GlobalVariableCheck(keyD) ? GlobalVariableGet(keyD) : 0.0);
         double mfe = (r > 0.0 ? (direction > 0.0 ? best - open : open - best) / r : 0.0);
         double mae = (r > 0.0 ? (direction > 0.0 ? open - worst : worst - open) / r : 0.0);
         double engineValue = (GlobalVariableCheck(keyE) ? GlobalVariableGet(keyE) : 0.0);
         EventLog("POSITION_CLOSED_METRICS", StringFormat("position_id=%I64d engine=%s mfe_R=%.2f mae_R=%.2f initial_atr=%.5f deal_profit=%.2f commission=%.2f swap=%.2f",
            identifier, EngineName((int)engineValue), mfe, mae, atr, profit, commission, swap));
         DeletePositionState(identifier);
      }
   }
}
//+------------------------------------------------------------------+
