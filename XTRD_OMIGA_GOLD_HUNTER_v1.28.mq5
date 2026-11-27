//+------------------------------------------------------------------+
//| XTRD OMIGA - GOLD HUNTER v1.28                                   |
//| v1.28: staged per-position exit management; no account-loss/risk-entry caps; unlimited EA position slots |
//| Tick-driven signal-directed continuation Expert Advisor with staged break-even and per-position trailing     |
//| Independent rebuild based on v1.02 source review.                 |
//| IMPORTANT: Trading is enabled by default; verify broker symbol settings and test in MT5 before live use. |
//+------------------------------------------------------------------+
#property strict
#property version   "1.28"
#property description "Adaptive tick-and-candle gold hunter with signal-directed entries, ATR stop geometry, staged break-even, per-position trailing, fill-price stop re-anchoring and unrestricted EA position slots subject to broker execution limits."

//------------------------------- INPUTS -----------------------------
input group "01. General / Safety"
input string InpTradeSymbol                 = "";          // Empty = chart symbol
input ulong  InpMagicNumber                 = 26112410;
input bool   InpResearchMode                = false;        // true = no trade requests are sent
input bool   InpEnableTrading                = true;      // Strategy Tester auto-trades; explicitly enable for demo/live
input bool   InpSignalOnlyMode               = false;        // true = signals/logging only
input bool   InpRequireHedgingAccount        = false;        // Required for independent stacked positions
input int    InpDeviationPoints              = 30;
input int    InpAbsoluteMaxPositions         = 0;           // 0 = no EA-side position-count cap
input int    InpStartingMaxPositions         = 0;           // Not used when InpAbsoluteMaxPositions=0
input double InpBalanceStepForExtraPosition  = 0.0;        // Each +$10 realized balance adds one slot, up to five
input int    InpMaxPendingOrders             = 0;           // 0 = no EA-side pending-order count cap
input double InpFreeMarginReservePercent     = 0.0;        // 0 = no extra reserve; actual broker margin checks remain
input int    InpExecutionPauseSeconds        = 1;
input int    InpPauseAfterNoMoneySeconds      = 2;         // Brief retry throttle after broker margin rejection
input int    InpPauseAfterMarketClosedSeconds = 30;

input group "02. Volume Scaling"
input double InpInitialLot                  = 0.01;
input double InpMaximumLotPerPosition       = 0.05;        // Hard per-position lot ceiling
input double InpLotIncrement                = 0.01;
input double InpBalanceStepForLotIncrease   = 20.0;        // Each +$20 balance adds one 0.01 lot increment, capped at 0.05
input double InpReferenceBalance            = 10.0;        // Balance at which initial lot/position capacity applies

input group "03. Tick Signal Engine"
input bool   InpEnableMovementScanner       = true;
input bool   InpEnableMicroHunter           = true;
input bool   InpEnableMomentumEngine        = true;
input int    InpFastTickWindow              = 6;
input int    InpSlowTickWindow              = 24;          // Non-overlapping baseline window after fast window
input int    InpMinimumTicksForSignal       = 31;          // At least fast + slow + 1
input double InpMinimumDirectionalRatio     = 0.58;
input double InpMinimumFastMovePoints       = 1.2;
input double InpMinimumFastSpeedPointsSec   = 0.20;
input double InpMinimumSignalScore          = 55.0;        // Moderate composite threshold; tick movement leads
input bool   InpRequireEMAAlignment          = true;        // M1/M5 trend context must not oppose the tick impulse
input double InpMinimumEfficiency           = 0.10;        // Minimum fast-window path efficiency
input bool   InpUseM1ContextAsScore         = true;        // M1 EMA/candle context for score and optional alignment
input int    InpM1FastEMA                   = 5;
input int    InpM1SlowEMA                   = 13;
input int    InpATRPeriod                   = 14;
input ENUM_TIMEFRAMES InpATRTimeframe       = PERIOD_M1;
input bool   InpUseM5ContextAsScore         = true;        // M5 EMA/candle context for score and optional alignment
input int    InpM5FastEMA                   = 21;
input int    InpM5SlowEMA                   = 50;

input group "04. Spread Intelligence"
input int    InpHardMaxSpreadPoints         = 120;         // Absolute ceiling; set 0 to disable only this ceiling
input double InpSpreadSpikeMultiplier       = 2.5;         // Current spread must not spike above EMA * multiplier
input double InpSpreadToATRMaximum          = 0.80;        // Spread / ATR ceiling; set 0 to disable
input double InpSpreadEmaAlpha              = 0.08;
input int    InpSpreadWarmupSamples         = 20;

input group "05. Entry / Pending Orders"
input bool   InpEnableDualStop              = false;        // false = arm only the side confirmed by the live signal; true = legacy two-sided bracket
input bool   InpEnableOCO                   = true;
input bool   InpEnableStacking              = true;
input bool   InpRequireContinuationSignal   = true;
input int    InpRearmCooldownSeconds        = 0;          // Minimum age of newest position before another continuation add
input int    InpPostExitCooldownSeconds      = 0;          // Wait after a position closes before re-arming a new entry
input int    InpMinimumSecondsBetweenEntries = 0;          // Minimum spacing between actual filled entries
input bool   InpOneEntryPerM1Bar             = false;        // Avoid repeated entries during one noisy one-minute candle
input double InpMinimumAdvanceBetweenAddsATR= 0.10;        // Avoid duplicate stacking at nearly the same price
input double InpMinimumEntryDistancePoints  = 10.0;
input double InpEntrySpreadMultiplier        = 1.15;        // Pending trigger remains beyond spread, but closer than v1.25
input double InpEntryATRMultiplier          = 0.08;
input double InpMaximumEntryDistancePoints  = 300.0;
input double InpPendingRepricePoints        = 20.0;
input int    InpMinimumSecondsBetweenReprice= 3;
input int    InpPendingExpiryMinutes        = 2;           // 0 = use GTC if broker allows
input bool   InpCancelPendingWhenSignalDies = true;       // Expiry remains the normal stale-order control

input group "06. Trade Exits (no account-level loss/risk entry limits)"
input double InpTakeProfitRiskReward         = 2.00;        // Fixed TP distance = initial SL distance x this R multiple; 0 disables TP
input double InpInitialSLATRMultiplier      = 0.40;        // Per-position technical SL distance based on ATR; not an account-level loss cap
input bool   InpEnableAdaptiveTrailing       = true;
input double InpBreakEvenActivationATR      = 0.30;        // Move SL to small positive offset after initial favorable movement
input double InpBreakEvenOffsetPoints        = 2.0;         // Offset beyond entry; adjust for commission/symbol costs
input double InpTrailActivationATR          = 0.65;        // Additional ATR trigger; trailing also waits until trail distance is covered
input double InpTrailDistanceATR            = 0.20;
input double InpTrailDistanceSpreadMultiple = 1.0;
input double InpTrailMinimumDistancePoints  = 20.0;
input int    InpTrailMinimumStepPoints      = 4;
input int    InpTrailModifyCooldownSeconds  = 1;
input bool   InpEnableMomentumExit           = false;       // Optional: close on opposite signal once the position has net positive floating profit
input double InpMomentumExitMinimumProfit   = 0.05;
input double InpEstimatedRoundTurnFeePerLot= 0.0;

input group "07. Research / Diagnostics"
input bool   InpWriteCSVLog                  = true;
input bool   InpVerboseJournal               = true;
input bool   InpShowChartStatus              = true;
input int    InpHistoryReconcileSeconds     = 30;

//------------------------------- GLOBALS ----------------------------
string   g_symbol = "";
int      g_atr_handle = INVALID_HANDLE;
int      g_m1_fast_handle = INVALID_HANDLE;
int      g_m1_slow_handle = INVALID_HANDLE;
int      g_m5_fast_handle = INVALID_HANDLE;
int      g_m5_slow_handle = INVALID_HANDLE;

#define GH_TICK_BUFFER 512
#define GH_DEAL_CACHE  512

double   g_mid[GH_TICK_BUFFER];
long     g_tick_msc[GH_TICK_BUFFER];
int      g_tick_head = 0;
int      g_tick_count = 0;

ulong    g_seen_deals[GH_DEAL_CACHE];
int      g_seen_deal_head = 0;
int      g_seen_deal_count = 0;

int      g_csv_handle = INVALID_HANDLE;
datetime g_pause_until = 0;
datetime g_last_history_scan = 0;
datetime g_last_status_time = 0;
datetime g_last_reprice_time = 0;
// Each position gets its own trailing/stop-modification cooldown. A shared timer
// allowed one busy ticket to starve other simultaneous positions.
ulong    g_trail_tickets[GH_DEAL_CACHE];
datetime g_trail_update_times[GH_DEAL_CACHE];
int      g_trail_registry_next = 0;
datetime g_last_delete_attempt_time = 0;
datetime g_last_research_log_time = 0;
datetime g_last_close_attempt = 0;
datetime g_last_entry_time = 0;
datetime g_last_exit_time = 0;
datetime g_last_entry_m1_bar = 0;
int      g_last_signal_code = 0;
int      g_consecutive_send_errors = 0;

double   g_atr = 0.0;
double   g_atr_cache = 0.0;
datetime g_last_atr_bar_time = 0;
datetime g_last_m1_context_time = 0;
datetime g_last_m5_context_time = 0;
datetime g_last_m1_candle_time = 0;
datetime g_last_m5_candle_time = 0;
double   g_spread_ema = 0.0;
int      g_spread_samples = 0;
double   g_fast_speed = 0.0;
double   g_slow_speed = 0.0;
double   g_fast_move_points = 0.0;
double   g_directional_ratio = 0.5;
double   g_efficiency = 0.0;
double   g_acceleration_ratio = 1.0;
int      g_m1_candle_bias = 0;
int      g_m5_candle_bias = 0;
double   g_m1_candle_strength = 0.0;
double   g_m5_candle_strength = 0.0;
bool     g_spread_blocked = false;
double   g_score_up = 0.0;
double   g_score_down = 0.0;
int      g_m1_bias = 0;
int      g_m5_bias = 0;
bool     g_signal_up = false;
bool     g_signal_down = false;

//------------------------------- UTILITIES --------------------------
void Log(const string message)
{
   if(InpVerboseJournal)
      Print("[XTRD_GH128] ", message);
}

double PointSize()
{
   return SymbolInfoDouble(g_symbol, SYMBOL_POINT);
}

int PriceDigits()
{
   return (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
}

double NormalizePrice(const double price)
{
   double tick_size = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0.0)
      tick_size = PointSize();
   if(tick_size <= 0.0)
      return NormalizeDouble(price, PriceDigits());
   double aligned = MathRound(price / tick_size) * tick_size;
   return NormalizeDouble(aligned, PriceDigits());
}

double NormalizePriceDown(const double price)
{
   double tick_size = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0.0) tick_size = PointSize();
   if(tick_size <= 0.0) return NormalizeDouble(price, PriceDigits());
   double aligned = MathFloor(price / tick_size + 1e-9) * tick_size;
   return NormalizeDouble(aligned, PriceDigits());
}

double NormalizePriceUp(const double price)
{
   double tick_size = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0.0) tick_size = PointSize();
   if(tick_size <= 0.0) return NormalizeDouble(price, PriceDigits());
   double aligned = MathCeil(price / tick_size - 1e-9) * tick_size;
   return NormalizeDouble(aligned, PriceDigits());
}

double NormalizeDistanceUp(const double distance)
{
   double tick_size = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0.0) tick_size = PointSize();
   if(tick_size <= 0.0) return NormalizeDouble(distance, PriceDigits());
   double aligned = MathCeil(distance / tick_size - 1e-9) * tick_size;
   return NormalizeDouble(aligned, PriceDigits());
}

int VolumeDigitsFromStep(const double step)
{
   if(step >= 1.0) return 0;
   if(step >= 0.1) return 1;
   if(step >= 0.01) return 2;
   if(step >= 0.001) return 3;
   if(step >= 0.0001) return 4;
   return 5;
}

double NormalizeVolumeDown(const double requested)
{
   double vmin = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   if(vmin <= 0.0 || vmax <= 0.0 || step <= 0.0)
      return 0.0;
   if(requested + 1e-9 < vmin)
      return 0.0; // Never round a too-small requested lot UP to broker minimum.
   double value = MathMin(requested, MathMin(vmax, InpMaximumLotPerPosition));
   value = MathFloor(value / step + 1e-8) * step;
   value = NormalizeDouble(value, VolumeDigitsFromStep(step));
   if(value + 1e-9 < vmin)
      return 0.0;
   return value;
}

bool IsHedgingAccount()
{
   ENUM_ACCOUNT_MARGIN_MODE mode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   return (mode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

bool TradingPermitted()
{
   bool tester_execution = (bool)MQLInfoInteger(MQL_TESTER);
   if(InpResearchMode || (!InpEnableTrading && !tester_execution) || InpSignalOnlyMode)
      return false;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return false;
   return true;
}

void CsvWrite(const string event_name, const string details)
{
   if(!InpWriteCSVLog || g_csv_handle == INVALID_HANDLE)
      return;
   FileWrite(g_csv_handle, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
             event_name, g_symbol, DoubleToString(g_atr, PriceDigits()),
             DoubleToString(g_fast_speed, 2), DoubleToString(g_slow_speed, 2),
             DoubleToString(g_directional_ratio, 3), DoubleToString(g_efficiency, 3),
             DoubleToString(g_score_up, 1), DoubleToString(g_score_down, 1), details);
   FileFlush(g_csv_handle);
}

void SetExecutionPause(const uint retcode)
{
   if(retcode == TRADE_RETCODE_MARKET_CLOSED)
   {
      int closed_pause = MathMax(30, InpPauseAfterMarketClosedSeconds);
      g_pause_until = TimeCurrent() + closed_pause;
      Log(StringFormat("MARKET CLOSED: entry requests paused for %d seconds; this is a session condition, not an execution-error streak.", closed_pause));
      CsvWrite("MARKET_CLOSED_PAUSE", StringFormat("retcode=%u;seconds=%d", retcode, closed_pause));
      return;
   }

   int seconds = InpExecutionPauseSeconds;
   if(retcode == TRADE_RETCODE_NO_MONEY)
      seconds = MathMax(1, InpPauseAfterNoMoneySeconds);
   else if(retcode == TRADE_RETCODE_INVALID_STOPS || retcode == TRADE_RETCODE_INVALID_PRICE)
      seconds = MathMax(seconds, 3);
   g_consecutive_send_errors++;
   if(g_consecutive_send_errors >= 3)
      seconds = MathMax(seconds, 2);
   if(g_consecutive_send_errors >= 5)
      seconds = MathMax(seconds, 5);
   g_pause_until = TimeCurrent() + MathMax(1, seconds);
   CsvWrite("EXECUTION_PAUSE", StringFormat("retcode=%u;seconds=%d", retcode, seconds));
}

bool GetATR(double &value)
{
   if(g_atr_handle == INVALID_HANDLE)
   {
      value = 0.0;
      return false;
   }
   datetime closed_bar = iTime(g_symbol, InpATRTimeframe, 1);
   if(closed_bar > 0 && closed_bar == g_last_atr_bar_time && g_atr_cache > 0.0)
   {
      value = g_atr_cache;
      return true;
   }
   double buffer[];
   ArraySetAsSeries(buffer, true);
   if(CopyBuffer(g_atr_handle, 0, 1, 1, buffer) != 1)
   {
      value = g_atr_cache;
      return (value > 0.0);
   }
   value = buffer[0];
   g_atr_cache = value;
   if(closed_bar > 0) g_last_atr_bar_time = closed_bar;
   return (value > 0.0);
}
bool GetEMABias(const int fast_handle, const int slow_handle, int &bias)
{
   bias = 0;
   if(fast_handle == INVALID_HANDLE || slow_handle == INVALID_HANDLE)
      return false;
   double fast[1], slow[1];
   if(CopyBuffer(fast_handle, 0, 1, 1, fast) != 1)
      return false;
   if(CopyBuffer(slow_handle, 0, 1, 1, slow) != 1)
      return false;
   if(fast[0] > slow[0]) bias = 1;
   else if(fast[0] < slow[0]) bias = -1;
   return true;
}

bool UpdateTimeframeContext()
{
   bool m1_ok = true;
   bool m5_ok = true;
   if(InpUseM1ContextAsScore)
   {
      datetime closed_time = iTime(g_symbol, PERIOD_M1, 1);
      if(closed_time > 0 && closed_time != g_last_m1_context_time)
      {
         m1_ok = GetEMABias(g_m1_fast_handle, g_m1_slow_handle, g_m1_bias);
         if(m1_ok) g_last_m1_context_time = closed_time;
      }
      else m1_ok = (g_last_m1_context_time > 0);
   }
   if(InpUseM5ContextAsScore)
   {
      datetime closed_time = iTime(g_symbol, PERIOD_M5, 1);
      if(closed_time > 0 && closed_time != g_last_m5_context_time)
      {
         m5_ok = GetEMABias(g_m5_fast_handle, g_m5_slow_handle, g_m5_bias);
         if(m5_ok) g_last_m5_context_time = closed_time;
      }
      else m5_ok = (g_last_m5_context_time > 0);
   }
   return (m1_ok && m5_ok);
}

//------------------------------- CSV / DIAGNOSTICS ------------------
void OpenResearchLog()
{
   if(!InpWriteCSVLog)
      return;
   string safe_symbol = g_symbol;
   StringReplace(safe_symbol, ".", "_");
   StringReplace(safe_symbol, "/", "_");
   string file_name = StringFormat("XTRD_GH128_%s_%I64u.csv", safe_symbol, InpMagicNumber);
   g_csv_handle = FileOpen(file_name, FILE_READ|FILE_WRITE|FILE_CSV|FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_ANSI, ',');
   if(g_csv_handle == INVALID_HANDLE)
   {
      Log(StringFormat("CSV open failed, error=%d. Journal logging remains available.", GetLastError()));
      return;
   }
   if(FileSize(g_csv_handle) == 0)
      FileWrite(g_csv_handle, "time", "event", "symbol", "atr", "fast_pts_sec", "baseline_pts_sec",
                "directional_ratio", "efficiency", "score_up", "score_down", "details");
   FileSeek(g_csv_handle, 0, SEEK_END);
   FileFlush(g_csv_handle);
}

//------------------------------- TICK BUFFER / SIGNALS --------------
void PushTick(const MqlTick &tick)
{
   double point = PointSize();
   if(point <= 0.0 || tick.bid <= 0.0 || tick.ask < tick.bid)
      return;

   double spread_points = (tick.ask - tick.bid) / point;
   if(g_spread_samples == 0)
      g_spread_ema = spread_points;
   else
      g_spread_ema = InpSpreadEmaAlpha * spread_points + (1.0 - InpSpreadEmaAlpha) * g_spread_ema;
   g_spread_samples++;

   long time_msc = tick.time_msc;
   if(g_tick_count > 0)
   {
      int newest_index = (g_tick_head - 1 + GH_TICK_BUFFER) % GH_TICK_BUFFER;
      if(g_tick_msc[newest_index] == time_msc && MathAbs(g_mid[newest_index] - (tick.bid + tick.ask) * 0.5) < point * 0.1)
         return;
   }

   g_mid[g_tick_head] = (tick.bid + tick.ask) * 0.5;
   g_tick_msc[g_tick_head] = time_msc;
   g_tick_head = (g_tick_head + 1) % GH_TICK_BUFFER;
   if(g_tick_count < GH_TICK_BUFFER)
      g_tick_count++;
}

bool GetBufferedTick(const int offset, double &price, long &time_msc)
{
   if(offset < 0 || offset >= g_tick_count)
      return false;
   int index = (g_tick_head - 1 - offset + GH_TICK_BUFFER * 2) % GH_TICK_BUFFER;
   price = g_mid[index];
   time_msc = g_tick_msc[index];
   return true;
}

double Clamp01(const double value)
{
   return MathMax(0.0, MathMin(1.0, value));
}

// Read the last CLOSED candle. Candle direction/strength only adds context;
// it never blocks a valid tick impulse by itself.
int ReadClosedCandleBias(const ENUM_TIMEFRAMES timeframe, double &strength)
{
   strength = 0.0;
   MqlRates candle[1];
   if(CopyRates(g_symbol, timeframe, 1, 1, candle) != 1)
      return 0;
   double range = candle[0].high - candle[0].low;
   double body = candle[0].close - candle[0].open;
   if(range <= 0.0 || MathAbs(body) <= 0.0)
      return 0;
   double body_ratio = Clamp01(MathAbs(body) / range);
   double close_location = (candle[0].close - candle[0].low) / range;
   double directional_close = (body > 0.0 ? close_location : 1.0 - close_location);
   strength = Clamp01(0.65 * body_ratio + 0.35 * directional_close);
   if(body > 0.0) return 1;
   if(body < 0.0) return -1;
   return 0;
}

void UpdateClosedCandleContexts()
{
   datetime m1_closed = iTime(g_symbol, PERIOD_M1, 1);
   if(m1_closed > 0 && m1_closed != g_last_m1_candle_time)
   {
      g_m1_candle_bias = ReadClosedCandleBias(PERIOD_M1, g_m1_candle_strength);
      g_last_m1_candle_time = m1_closed;
   }
   datetime m5_closed = iTime(g_symbol, PERIOD_M5, 1);
   if(m5_closed > 0 && m5_closed != g_last_m5_candle_time)
   {
      g_m5_candle_bias = ReadClosedCandleBias(PERIOD_M5, g_m5_candle_strength);
      g_last_m5_candle_time = m5_closed;
   }
}

void CalculateSignalMetrics()
{
   g_fast_speed = 0.0;
   g_slow_speed = 0.0;
   g_fast_move_points = 0.0;
   g_directional_ratio = 0.5;
   g_efficiency = 0.0;
   g_acceleration_ratio = 1.0;
   g_score_up = 0.0;
   g_score_down = 0.0;
   g_signal_up = false;
   g_signal_down = false;
   UpdateTimeframeContext();
   UpdateClosedCandleContexts();

   double point = PointSize();
   int required = InpFastTickWindow + InpSlowTickWindow + 1;
   if(point <= 0.0 || g_tick_count < MathMax(InpMinimumTicksForSignal, required))
      return;

   double newest, fast_old, slow_old;
   long newest_time, fast_old_time, slow_old_time;
   if(!GetBufferedTick(0, newest, newest_time) ||
      !GetBufferedTick(InpFastTickWindow, fast_old, fast_old_time) ||
      !GetBufferedTick(InpFastTickWindow + InpSlowTickWindow, slow_old, slow_old_time))
      return;

   double fast_seconds = MathMax(0.001, (double)(newest_time - fast_old_time) / 1000.0);
   double slow_seconds = MathMax(0.001, (double)(fast_old_time - slow_old_time) / 1000.0);
   double fast_delta = (newest - fast_old) / point;
   double slow_delta = (fast_old - slow_old) / point;
   g_fast_move_points = fast_delta;
   g_fast_speed = MathAbs(fast_delta) / fast_seconds;
   g_slow_speed = MathAbs(slow_delta) / slow_seconds;
   g_acceleration_ratio = g_fast_speed / MathMax(g_slow_speed, 0.10);

   int up = 0, down = 0;
   double path_points = 0.0;
   for(int i = 0; i < InpFastTickWindow; i++)
   {
      double p0, p1;
      long t0, t1;
      if(!GetBufferedTick(i, p0, t0) || !GetBufferedTick(i + 1, p1, t1))
         continue;
      double change = (p0 - p1) / point;
      path_points += MathAbs(change);
      if(change > 0.0) up++;
      else if(change < 0.0) down++;
   }
   int moves = up + down;
   if(moves <= 0 || path_points <= 0.0)
      return;

   double up_ratio = (double)up / moves;
   double down_ratio = (double)down / moves;
   g_directional_ratio = MathMax(up_ratio, down_ratio);
   g_efficiency = Clamp01(MathAbs(fast_delta) / path_points);

   double speed_score = Clamp01(g_fast_speed / MathMax(InpMinimumFastSpeedPointsSec * 2.0, 1.0));
   double acceleration_score = Clamp01(g_acceleration_ratio / 2.0);
   double efficiency_score = Clamp01(g_efficiency / 0.55);
   double up_consistency = up_ratio;
   double down_consistency = down_ratio;

   // Cached last-closed candle direction and strength are soft evidence alongside EMA context.
   double up_context = 0.0;
   double down_context = 0.0;
   if(InpUseM1ContextAsScore)
   {
      up_context += (g_m1_bias > 0 ? 5.0 : (g_m1_bias == 0 ? 2.5 : 0.0));
      down_context += (g_m1_bias < 0 ? 5.0 : (g_m1_bias == 0 ? 2.5 : 0.0));
   }
   if(InpUseM5ContextAsScore)
   {
      up_context += (g_m5_bias > 0 ? 3.0 : (g_m5_bias == 0 ? 1.5 : 0.0));
      down_context += (g_m5_bias < 0 ? 3.0 : (g_m5_bias == 0 ? 1.5 : 0.0));
   }
   // Closed candle pressure is additive/subtractive, never a mandatory gate.
   up_context += (g_m1_candle_bias > 0 ? 7.0 * g_m1_candle_strength : (g_m1_candle_bias < 0 ? -2.0 * g_m1_candle_strength : 0.0));
   down_context += (g_m1_candle_bias < 0 ? 7.0 * g_m1_candle_strength : (g_m1_candle_bias > 0 ? -2.0 * g_m1_candle_strength : 0.0));
   up_context += (g_m5_candle_bias > 0 ? 4.0 * g_m5_candle_strength : (g_m5_candle_bias < 0 ? -1.0 * g_m5_candle_strength : 0.0));
   down_context += (g_m5_candle_bias < 0 ? 4.0 * g_m5_candle_strength : (g_m5_candle_bias > 0 ? -1.0 * g_m5_candle_strength : 0.0));
   if(!InpUseM1ContextAsScore && !InpUseM5ContextAsScore)
   {
      up_context += 3.0;
      down_context += 3.0;
   }
   g_score_up = 35.0 * up_consistency + 25.0 * efficiency_score +
                20.0 * speed_score + 10.0 * acceleration_score + up_context;
   g_score_down = 35.0 * down_consistency + 25.0 * efficiency_score +
                  20.0 * speed_score + 10.0 * acceleration_score + down_context;

   double abs_move = MathAbs(fast_delta);
   // Use the configured minimums as written. v1.24 silently weakened several
   // thresholds (45-50% of their inputs), which admitted many low-quality impulses.
   bool enough_activity = (moves >= (int)MathMax(3, MathCeil(InpFastTickWindow * 0.50)));
   bool enough_move = (abs_move >= InpMinimumFastMovePoints ||
                       (g_m1_candle_strength >= 0.78 && abs_move >= InpMinimumFastMovePoints * 0.80));
   bool enough_speed = (g_fast_speed >= InpMinimumFastSpeedPointsSec ||
                        abs_move >= MathMax(3.0, (g_atr / point) * 0.10));
   bool enough_direction = (g_directional_ratio >= InpMinimumDirectionalRatio);
   bool enough_efficiency = (g_efficiency >= InpMinimumEfficiency ||
                             ((g_m1_candle_strength >= 0.82 || g_m5_candle_strength >= 0.84) &&
                              g_directional_ratio >= MathMin(0.90, InpMinimumDirectionalRatio + 0.08)));
   bool common_quality = (enough_activity && enough_move && enough_speed &&
                          enough_direction && enough_efficiency);

   // Two complementary hunting paths: micro movement and faster impulse/expansion.
   bool expansion_move = (abs_move >= MathMax(3.5, (g_atr / point) * 0.10));
   if(InpEnableMovementScanner && common_quality)
   {
      bool micro_up = (InpEnableMicroHunter && fast_delta > 0.0 && g_score_up >= InpMinimumSignalScore);
      bool micro_down = (InpEnableMicroHunter && fast_delta < 0.0 && g_score_down >= InpMinimumSignalScore);
      bool impulse_up = (InpEnableMomentumEngine && fast_delta > 0.0 &&
                         (g_acceleration_ratio >= 0.90 || expansion_move) &&
                         (g_score_up >= InpMinimumSignalScore - 3.0));
      bool impulse_down = (InpEnableMomentumEngine && fast_delta < 0.0 &&
                           (g_acceleration_ratio >= 0.90 || expansion_move) &&
                           (g_score_down >= InpMinimumSignalScore - 3.0));
      bool ema_allows_up = true;
      bool ema_allows_down = true;
      if(InpRequireEMAAlignment)
      {
         bool have_ema_context = false;
         if(InpUseM1ContextAsScore)
         {
            have_ema_context = true;
            ema_allows_up = ema_allows_up && (g_m1_bias >= 0);
            ema_allows_down = ema_allows_down && (g_m1_bias <= 0);
         }
         if(InpUseM5ContextAsScore)
         {
            have_ema_context = true;
            ema_allows_up = ema_allows_up && (g_m5_bias >= 0);
            ema_allows_down = ema_allows_down && (g_m5_bias <= 0);
         }
         // Require at least one active timeframe to confirm the direction;
         // a flat/neutral EMA is acceptable only when the other timeframe agrees.
         if(have_ema_context)
         {
            bool bullish_confirmed = ((InpUseM1ContextAsScore && g_m1_bias > 0) ||
                                      (InpUseM5ContextAsScore && g_m5_bias > 0));
            bool bearish_confirmed = ((InpUseM1ContextAsScore && g_m1_bias < 0) ||
                                      (InpUseM5ContextAsScore && g_m5_bias < 0));
            ema_allows_up = ema_allows_up && bullish_confirmed;
            ema_allows_down = ema_allows_down && bearish_confirmed;
         }
      }
      g_signal_up = (micro_up || impulse_up) && ema_allows_up;
      g_signal_down = (micro_down || impulse_down) && ema_allows_down;
   }
}

int CurrentSignalCode()
{
   if(g_signal_up && g_signal_down) return 3;
   if(g_signal_up) return 1;
   if(g_signal_down) return -1;
   return 0;
}

bool SpreadIsAcceptable(const double atr_value)
{
   MqlTick tick;
   double point = PointSize();
   if(point <= 0.0 || !SymbolInfoTick(g_symbol, tick))
      return false;
   double spread_points = (tick.ask - tick.bid) / point;
   if(InpHardMaxSpreadPoints > 0 && spread_points > InpHardMaxSpreadPoints)
      return false;
   if(g_spread_samples >= InpSpreadWarmupSamples && g_spread_ema > 0.0 &&
      spread_points > g_spread_ema * MathMax(1.0, InpSpreadSpikeMultiplier))
      return false;
   if(InpSpreadToATRMaximum > 0.0 && atr_value > 0.0 &&
      spread_points > (atr_value / point) * InpSpreadToATRMaximum)
      return false;
   return true;
}

//------------------------------- POSITION / ORDER SCANNING ----------
int CountOurPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == g_symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         count++;
   }
   return count;
}

int CountOurPendingOrders()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
         count++;
   }
   return count;
}

bool HasOurDirection(const ENUM_POSITION_TYPE direction)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == direction)
         return true;
   }
   return false;
}

bool HasMixedDirections()
{
   return (HasOurDirection(POSITION_TYPE_BUY) && HasOurDirection(POSITION_TYPE_SELL));
}

bool GetNewestOpenPosition(double &open_price, datetime &open_time, int &direction)
{
   open_price = 0.0;
   open_time = 0;
   direction = 0;
   bool found = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;
      datetime pos_time = (datetime)PositionGetInteger(POSITION_TIME);
      if(!found || pos_time >= open_time)
      {
         found = true;
         open_time = pos_time;
         open_price = PositionGetDouble(POSITION_PRICE_OPEN);
         direction = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1);
      }
   }
   return found;
}

bool FindPending(const ENUM_ORDER_TYPE type, ulong &ticket, double &price,
                 double &sl, double &tp, datetime &setup_time)
{
   ticket = 0; price = 0.0; sl = 0.0; tp = 0.0; setup_time = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong current = OrderGetTicket(i);
      if(current == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol ||
         (ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != type)
         continue;
      ticket = current;
      price = OrderGetDouble(ORDER_PRICE_OPEN);
      sl = OrderGetDouble(ORDER_SL);
      tp = OrderGetDouble(ORDER_TP);
      setup_time = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      return true;
   }
   return false;
}

int DynamicPositionLimit()
{
   if(InpAbsoluteMaxPositions <= 0)
      return 999999; // 0 means no EA-side position-count cap; broker margin remains authoritative.
   int base_limit = MathMax(1, MathMin(InpStartingMaxPositions, InpAbsoluteMaxPositions));
   if(InpBalanceStepForExtraPosition <= 0.0)
      return base_limit; // Zero disables capacity growth.
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   int increments = 0;
   if(balance > InpReferenceBalance)
      increments = (int)MathFloor((balance - InpReferenceBalance) / InpBalanceStepForExtraPosition);
   return MathMin(InpAbsoluteMaxPositions, base_limit + increments);
}

double DynamicPositionLot()
{
   double lot = InpInitialLot;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(InpBalanceStepForLotIncrease > 0.0 && balance > InpReferenceBalance)
   {
      int increments = (int)MathFloor((balance - InpReferenceBalance) / InpBalanceStepForLotIncrease);
      lot += increments * InpLotIncrement;
   }
   lot = MathMin(lot, InpMaximumLotPerPosition);
   return NormalizeVolumeDown(lot);
}

//------------------------------- EXECUTION HELPERS ------------------
bool MarginAndRequestCheck(MqlTradeRequest &request, const double volume, const double price)
{
   ENUM_ORDER_TYPE calc_type = (request.type == ORDER_TYPE_BUY_STOP ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double required_margin = 0.0;
   if(!OrderCalcMargin(calc_type, g_symbol, volume, price, required_margin))
   {
      Log(StringFormat("OrderCalcMargin failed, error=%d", GetLastError()));
      CsvWrite("MARGIN_CALC_FAIL", StringFormat("volume=%.2f", volume));
      g_pause_until = TimeCurrent() + MathMax(1, InpExecutionPauseSeconds);
      return false;
   }
   double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double reserve_pct = MathMax(0.0, MathMin(90.0, InpFreeMarginReservePercent));
   double minimum_reserve = AccountInfoDouble(ACCOUNT_EQUITY) * reserve_pct / 100.0;
   if(required_margin < 0.0 || free_margin - required_margin < minimum_reserve)
   {
      Log(StringFormat("MARGIN SKIP: %.2f lot; required=%.2f free=%.2f reserve=%.2f",
                       volume, required_margin, free_margin, minimum_reserve));
      CsvWrite("MARGIN_SKIP", StringFormat("volume=%.2f;required=%.2f;free=%.2f;reserve=%.2f",
                                            volume, required_margin, free_margin, minimum_reserve));
      g_pause_until = TimeCurrent() + MathMax(1, InpPauseAfterNoMoneySeconds);
      return false;
   }

   MqlTradeCheckResult check;
   ZeroMemory(check);
   ResetLastError();
   if(!OrderCheck(request, check) || (check.retcode != 0 && check.retcode != TRADE_RETCODE_DONE))
   {
      Log(StringFormat("OrderCheck failed: error=%d retcode=%u comment=%s",
                       GetLastError(), check.retcode, check.comment));
      CsvWrite("ORDERCHECK_FAIL", StringFormat("retcode=%u;%s", check.retcode, check.comment));
      if(check.retcode == TRADE_RETCODE_NO_MONEY)
         g_pause_until = TimeCurrent() + MathMax(1, InpPauseAfterNoMoneySeconds);
      else
         g_pause_until = TimeCurrent() + MathMax(1, InpExecutionPauseSeconds);
      return false;
   }
   // OrderCheck supplies the projected free margin after this exact request.
   // Keep the configured reserve based on the result, not only the isolated OrderCalcMargin estimate.
   if(minimum_reserve > 0.0 && check.margin_free < minimum_reserve)
   {
      Log(StringFormat("ORDERCHECK RESERVE SKIP: projected free margin %.2f below reserve %.2f",
                       check.margin_free, minimum_reserve));
      CsvWrite("ORDERCHECK_RESERVE_SKIP", StringFormat("projected_free=%.2f;reserve=%.2f",
                                                        check.margin_free, minimum_reserve));
      g_pause_until = TimeCurrent() + MathMax(1, InpPauseAfterNoMoneySeconds);
      return false;
   }
   return true;
}

ENUM_ORDER_TYPE_TIME GetAllowedOrderTime(datetime &expiration)
{
   expiration = 0;
   long modes = SymbolInfoInteger(g_symbol, SYMBOL_EXPIRATION_MODE);
   if(InpPendingExpiryMinutes > 0 && (modes & SYMBOL_EXPIRATION_SPECIFIED) == SYMBOL_EXPIRATION_SPECIFIED)
   {
      expiration = TimeCurrent() + InpPendingExpiryMinutes * 60;
      return ORDER_TIME_SPECIFIED;
   }
   if((modes & SYMBOL_EXPIRATION_GTC) == SYMBOL_EXPIRATION_GTC)
      return ORDER_TIME_GTC;
   if((modes & SYMBOL_EXPIRATION_DAY) == SYMBOL_EXPIRATION_DAY)
      return ORDER_TIME_DAY;
   return (ENUM_ORDER_TYPE_TIME)-1;
}

bool SendPending(const ENUM_ORDER_TYPE type, const double volume, const double price,
                 const double sl, const double tp, const string comment)
{
   if(!TradingPermitted() || TimeCurrent() < g_pause_until)
   {
      if(TimeCurrent() - g_last_research_log_time >= 5)
      {
         Log(StringFormat("RESEARCH/PERMISSION setup: %s lot=%.2f price=%.*f SL=%.*f TP=%.*f",
                          EnumToString(type), volume, PriceDigits(), price, PriceDigits(), sl, PriceDigits(), tp));
         CsvWrite("RESEARCH_SETUP", StringFormat("%s;lot=%.2f;price=%.*f;sl=%.*f;tp=%.*f",
                                                  EnumToString(type), volume, PriceDigits(), price, PriceDigits(), sl, PriceDigits(), tp));
         g_last_research_log_time = TimeCurrent();
      }
      return false;
   }

   datetime expiration = 0;
   ENUM_ORDER_TYPE_TIME time_type = GetAllowedOrderTime(expiration);
   if((int)time_type < 0)
   {
      Log("Broker does not advertise a supported pending-order expiration mode.");
      CsvWrite("EXPIRATION_UNSUPPORTED", "pending order skipped");
      return false;
   }

   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action = TRADE_ACTION_PENDING;
   request.symbol = g_symbol;
   request.magic = InpMagicNumber;
   request.volume = volume;
   request.type = type;
   request.price = NormalizePrice(price);
   request.sl = NormalizePrice(sl);
   request.tp = NormalizePrice(tp);
   request.deviation = InpDeviationPoints;
   request.type_filling = ORDER_FILLING_RETURN;
   request.type_time = time_type;
   request.expiration = expiration;
   request.comment = comment;

   if(!MarginAndRequestCheck(request, volume, request.price))
      return false;

   ResetLastError();
   bool sent = OrderSend(request, result);
   if(!sent || (result.retcode != TRADE_RETCODE_PLACED && result.retcode != TRADE_RETCODE_DONE))
   {
      Log(StringFormat("PENDING SEND FAILED type=%s retcode=%u error=%d comment=%s",
                       EnumToString(type), result.retcode, GetLastError(), result.comment));
      SetExecutionPause(result.retcode);
      return false;
   }
   g_consecutive_send_errors = 0;
   double estimated_sl_result = 0.0;
   double estimated_tp_result = 0.0;
   ENUM_ORDER_TYPE profit_type = (type == ORDER_TYPE_BUY_STOP ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   bool sl_estimated = OrderCalcProfit(profit_type, g_symbol, volume, request.price, request.sl, estimated_sl_result);
   bool tp_estimated = OrderCalcProfit(profit_type, g_symbol, volume, request.price, request.tp, estimated_tp_result);
   Log(StringFormat("PENDING PLACED ticket=%I64u type=%s lot=%.2f price=%.*f SL=%.*f TP=%.*f estSL=%s%.2f estTP=%s%.2f",
                    result.order, EnumToString(type), volume, PriceDigits(), request.price,
                    PriceDigits(), request.sl, PriceDigits(), request.tp,
                    (sl_estimated ? "" : "NA:"), estimated_sl_result,
                    (tp_estimated ? "" : "NA:"), estimated_tp_result));
   CsvWrite("PENDING_PLACED", StringFormat("ticket=%I64u;%s;lot=%.2f;price=%.*f;sl=%.*f;tp=%.*f;estSL=%s%.2f;estTP=%s%.2f",
                                             result.order, EnumToString(type), volume,
                                             PriceDigits(), request.price, PriceDigits(), request.sl,
                                             PriceDigits(), request.tp,
                                             (sl_estimated ? "" : "NA:"), estimated_sl_result,
                                             (tp_estimated ? "" : "NA:"), estimated_tp_result));
   return true;
}

bool DeletePending(const ulong ticket)
{
   if(ticket == 0) return false;
   if(TimeCurrent() - g_last_delete_attempt_time < 1)
      return false;
   if(!TradingPermitted())
   {
      Log(StringFormat("RESEARCH cancel pending ticket=%I64u", ticket));
      CsvWrite("RESEARCH_CANCEL", StringFormat("ticket=%I64u", ticket));
      g_last_delete_attempt_time = TimeCurrent();
      return false;
   }
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action = TRADE_ACTION_REMOVE;
   request.order = ticket;
   request.symbol = g_symbol;
   request.magic = InpMagicNumber;
   bool sent = OrderSend(request, result);
   g_last_delete_attempt_time = TimeCurrent();
   if(!sent || (result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED))
   {
      Log(StringFormat("PENDING DELETE FAILED ticket=%I64u retcode=%u %s", ticket, result.retcode, result.comment));
      return false;
   }
   Log(StringFormat("PENDING DELETED ticket=%I64u", ticket));
   CsvWrite("PENDING_DELETED", StringFormat("ticket=%I64u", ticket));
   return true;
}

bool ModifyPending(const ulong ticket, const ENUM_ORDER_TYPE type,
                   const double new_price, const double new_sl, const double new_tp)
{
   if(!TradingPermitted() || !OrderSelect(ticket))
      return false;
   datetime expiration = 0;
   ENUM_ORDER_TYPE_TIME time_type = GetAllowedOrderTime(expiration);
   if((int)time_type < 0)
      return false;

   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action = TRADE_ACTION_MODIFY;
   request.order = ticket;
   request.symbol = g_symbol;
   request.magic = InpMagicNumber;
   request.price = NormalizePrice(new_price);
   request.sl = NormalizePrice(new_sl);
   request.tp = NormalizePrice(new_tp);
   request.type_time = time_type;
   request.expiration = expiration;

   bool sent = OrderSend(request, result);
   if(!sent || (result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_NO_CHANGES))
   {
      Log(StringFormat("PENDING MODIFY FAILED ticket=%I64u retcode=%u %s", ticket, result.retcode, result.comment));
      if(result.retcode == TRADE_RETCODE_INVALID_STOPS || result.retcode == TRADE_RETCODE_INVALID_PRICE)
         SetExecutionPause(result.retcode);
      return false;
   }
   g_last_reprice_time = TimeCurrent();
   CsvWrite("PENDING_MODIFIED", StringFormat("ticket=%I64u;type=%s;price=%.*f", ticket,
                                               EnumToString(type), PriceDigits(), request.price));
   return true;
}

bool ModifyPositionStops(const ulong ticket, const double sl, const double tp)
{
   if(!TradingPermitted() || !PositionSelectByTicket(ticket))
      return false; // Entry cooldowns must never suspend protective stop/TP management.
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol = g_symbol;
   request.magic = InpMagicNumber;
   request.sl = (sl > 0.0 ? NormalizePrice(sl) : 0.0);
   request.tp = (tp > 0.0 ? NormalizePrice(tp) : 0.0);
   bool sent = OrderSend(request, result);
   if(!sent || (result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_NO_CHANGES))
   {
      Log(StringFormat("POSITION SLTP FAILED ticket=%I64u retcode=%u %s", ticket, result.retcode, result.comment));
      return false;
   }
   CsvWrite("POSITION_STOPS_MODIFIED", StringFormat("ticket=%I64u;sl=%.*f;tp=%.*f",
                                                       ticket, PriceDigits(), request.sl,
                                                       PriceDigits(), request.tp));
   return true;
}

ENUM_ORDER_TYPE_FILLING GetMarketFillingMode()
{
   long modes = SymbolInfoInteger(g_symbol, SYMBOL_FILLING_MODE);
   if((modes & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((modes & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

bool ClosePositionTicket(const ulong ticket, const string reason)
{
   if(!TradingPermitted() || !PositionSelectByTicket(ticket))
      return false;
   if(TimeCurrent() - g_last_close_attempt < 2)
      return false;
   ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double volume = PositionGetDouble(POSITION_VOLUME);
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick))
      return false;

   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action = TRADE_ACTION_DEAL;
   request.position = ticket; // Required to close the exact position on a hedging account.
   request.symbol = g_symbol;
   request.magic = InpMagicNumber;
   request.volume = volume;
   request.type = (pos_type == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
   request.price = (pos_type == POSITION_TYPE_BUY ? tick.bid : tick.ask);
   request.deviation = InpDeviationPoints;
   request.type_filling = GetMarketFillingMode();
   request.comment = reason;

   bool sent = OrderSend(request, result);
   if(!sent || (result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_DONE_PARTIAL && result.retcode != TRADE_RETCODE_PLACED))
   {
      Log(StringFormat("POSITION CLOSE FAILED ticket=%I64u retcode=%u %s", ticket, result.retcode, result.comment));
      SetExecutionPause(result.retcode);
      return false;
   }
   g_last_close_attempt = TimeCurrent();
   Log(StringFormat("POSITION CLOSE REQUEST ticket=%I64u reason=%s retcode=%u", ticket, reason, result.retcode));
   CsvWrite("POSITION_CLOSE_REQUEST", StringFormat("ticket=%I64u;reason=%s;retcode=%u", ticket, reason, result.retcode));
   return true;
}

//------------------------------- OCO / PENDING ENGINE ---------------
void CancelAllOurPendings()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == g_symbol &&
         (ulong)OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         DeletePending(ticket);
   }
}

void CancelPendingType(const ENUM_ORDER_TYPE type)
{
   ulong ticket; double price, sl, tp; datetime setup;
   while(FindPending(type, ticket, price, sl, tp, setup))
   {
      if(!DeletePending(ticket)) break;
      if(!OrderSelect(ticket)) break;
   }
}

void CancelOppositePendings()
{
   bool have_buy = HasOurDirection(POSITION_TYPE_BUY);
   bool have_sell = HasOurDirection(POSITION_TYPE_SELL);
   if(have_buy && have_sell)
   {
      if(CountOurPendingOrders() > 0)
      {
         CancelAllOurPendings();
         Log("OCO RACE: both directions exist; all pending orders cancelled and new entries suspended until flat.");
         CsvWrite("OCO_RACE", "both buy and sell positions detected");
      }
      return;
   }
   if(!have_buy && !have_sell)
      return;

   ENUM_ORDER_TYPE unwanted = (have_buy ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP);
   ulong ticket; double price, sl, tp; datetime setup;
   while(FindPending(unwanted, ticket, price, sl, tp, setup))
   {
      if(!DeletePending(ticket)) break;
      // Repeat only while a matching order is still visible; avoids stale duplicate OCO tickets.
      if(!OrderSelect(ticket)) break;
   }
}

//------------------------------- PRICE DISTANCES --------------------
double BrokerMinimumDistancePrice()
{
   double point = PointSize();
   long stops = SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze = SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (MathMax(stops, freeze) + 2.0) * point;
}

double CalculateEntryDistance()
{
   double point = PointSize();
   if(point <= 0.0) return 0.0;
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick)) return 0.0;
   double spread_points = (tick.ask - tick.bid) / point;
   double distance = MathMax(InpMinimumEntryDistancePoints * point,
                             MathMax(g_atr * InpEntryATRMultiplier,
                                     MathMax(spread_points * MathMax(1.0, InpEntrySpreadMultiplier) * point, BrokerMinimumDistancePrice())));
   if(InpMaximumEntryDistancePoints > 0.0)
      distance = MathMin(distance, InpMaximumEntryDistancePoints * point);
   distance = MathMax(distance, BrokerMinimumDistancePrice());
   return distance;
}

double NormalizeRequestedEntryVolume(const double requested_volume)
{
   // No dollar or equity-percentage risk cap is applied to entry volume.
   // Volume is still normalized to the broker's min/max/step and the EA lot ceiling.
   return NormalizeVolumeDown(requested_volume);
}

double CalculateProtectedSLDistance(const double volume, const double entry_price, const int direction)
{
   double point = PointSize();
   MqlTick tick;
   if(point <= 0.0 || volume <= 0.0 || entry_price <= 0.0 || !SymbolInfoTick(g_symbol, tick))
      return 0.0;

   double spread = MathMax(0.0, tick.ask - tick.bid);
   double broker_distance = BrokerMinimumDistancePrice();
   double safety_buffer = MathMax(2.0 * point, spread * 0.10);
   double minimum_distance = NormalizeDistanceUp(MathMax(spread + broker_distance + safety_buffer,
                                                          InpTrailMinimumDistancePoints * point));
   double chosen_distance = NormalizeDistanceUp(MathMax(minimum_distance, g_atr * InpInitialSLATRMultiplier));

   CsvWrite("SL_GEOMETRY", StringFormat("direction=%d;distance_points=%.1f;spread_points=%.1f;broker_points=%.1f;volume=%.3f;cash_risk_cap=DISABLED",
                                        direction, chosen_distance / point, spread / point, broker_distance / point, volume));
   return chosen_distance;
}

//------------------------------- ENTRY ENGINE ----------------------
bool HasQualifiedSignal()
{
   return (g_signal_up || g_signal_down);
}

void LogSignalIfChanged()
{
   int code = CurrentSignalCode();
   if(code == g_last_signal_code)
      return;
   g_last_signal_code = code;
   MqlTick tick;
   double spread_points = 0.0;
   if(SymbolInfoTick(g_symbol, tick) && PointSize() > 0.0)
      spread_points = (tick.ask - tick.bid) / PointSize();
   string state = (code == 1 ? "UP" : (code == -1 ? "DOWN" : (code == 3 ? "BOTH" : "NEUTRAL")));
   string details = StringFormat("state=%s;scoreUp=%.1f;scoreDown=%.1f;fast=%.2f;baseline=%.2f;ratio=%.2f;eff=%.2f;move=%.1f;spread=%.1f;emaM1=%d;emaM5=%d;candleM1=%d:%.2f;candleM5=%d:%.2f;positions=%d;limit=%d",
                                 state, g_score_up, g_score_down, g_fast_speed, g_slow_speed,
                                 g_directional_ratio, g_efficiency, g_fast_move_points,
                                 spread_points, g_m1_bias, g_m5_bias, g_m1_candle_bias, g_m1_candle_strength,
                                 g_m5_candle_bias, g_m5_candle_strength, CountOurPositions(), DynamicPositionLimit());
   Log("SIGNAL " + details);
   CsvWrite("SIGNAL", details);
}

bool PendingPriceIsSafe(const ENUM_ORDER_TYPE type, const double price)
{
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick)) return false;
   double min_distance = BrokerMinimumDistancePrice();
   if(type == ORDER_TYPE_BUY_STOP)
      return (price >= tick.ask + min_distance);
   if(type == ORDER_TYPE_SELL_STOP)
      return (price <= tick.bid - min_distance);
   return false;
}

double CalculatePendingTakeProfit(const ENUM_ORDER_TYPE type,
                                  const double entry_price,
                                  const double tp_distance)
{
   if(InpTakeProfitRiskReward <= 0.0 || tp_distance <= 0.0 || entry_price <= 0.0)
      return 0.0;
   if(type == ORDER_TYPE_BUY_STOP)
      return NormalizePriceUp(entry_price + tp_distance);
   if(type == ORDER_TYPE_SELL_STOP)
      return NormalizePriceDown(entry_price - tp_distance);
   return 0.0;
}

void MaintainOrPlacePending(const ENUM_ORDER_TYPE type, const double desired_price,
                            const double volume, const double sl_distance, const double tp_distance,
                            const string comment)
{
   ulong ticket; double old_price, old_sl, old_tp; datetime setup_time;
   bool exists = FindPending(type, ticket, old_price, old_sl, old_tp, setup_time);
   if(exists && InpPendingExpiryMinutes > 0 && setup_time > 0 &&
      TimeCurrent() - setup_time >= InpPendingExpiryMinutes * 60)
   {
      DeletePending(ticket); // Local expiry fallback when the broker only supports GTC/DAY.
      return;
   }
   double new_sl = (type == ORDER_TYPE_BUY_STOP ? desired_price - sl_distance : desired_price + sl_distance);
   new_sl = (type == ORDER_TYPE_BUY_STOP ? NormalizePriceDown(new_sl) : NormalizePriceUp(new_sl));
   double new_tp = CalculatePendingTakeProfit(type, desired_price, tp_distance);

   if(!PendingPriceIsSafe(type, desired_price))
      return;

   if(!exists)
   {
      if(InpMaxPendingOrders > 0 && CountOurPendingOrders() >= InpMaxPendingOrders)
         return;
      SendPending(type, volume, desired_price, new_sl, new_tp, comment);
      return;
   }

   double threshold = MathMax(1.0, InpPendingRepricePoints) * PointSize();
   bool price_changed = (MathAbs(old_price - desired_price) >= threshold &&
                         TimeCurrent() - g_last_reprice_time >= InpMinimumSecondsBetweenReprice);
   double tick_size = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0.0) tick_size = PointSize();
   bool tp_changed = (MathAbs(old_tp - new_tp) >= MathMax(tick_size * 0.5, PointSize() * 0.5));
   // If spread widened after the pending order was armed, widen its SL too.
   // Never tighten an already-armed initial stop merely because spread contracted.
   double sl_for_old_price = (type == ORDER_TYPE_BUY_STOP ? old_price - sl_distance : old_price + sl_distance);
   sl_for_old_price = (type == ORDER_TYPE_BUY_STOP ? NormalizePriceDown(sl_for_old_price) : NormalizePriceUp(sl_for_old_price));
   double sl_step = MathMax(2.0, (double)InpTrailMinimumStepPoints) * PointSize();
   bool sl_widened = false;
   if(type == ORDER_TYPE_BUY_STOP && old_sl > 0.0 && sl_for_old_price < old_sl - sl_step)
      sl_widened = true;
   if(type == ORDER_TYPE_SELL_STOP && old_sl > 0.0 && sl_for_old_price > old_sl + sl_step)
      sl_widened = true;

   if((price_changed || sl_widened || tp_changed) && TimeCurrent() - g_last_reprice_time >= InpMinimumSecondsBetweenReprice)
   {
      // Avoid modifying an order inside the broker's freeze zone.
      double freeze_distance = SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL) * PointSize();
      MqlTick tick;
      if(!SymbolInfoTick(g_symbol, tick)) return;
      if(type == ORDER_TYPE_BUY_STOP && MathAbs(old_price - tick.ask) <= freeze_distance) return;
      if(type == ORDER_TYPE_SELL_STOP && MathAbs(old_price - tick.bid) <= freeze_distance) return;
      double target_price = (price_changed ? desired_price : old_price);
      double target_sl = old_sl;
      if(price_changed) target_sl = new_sl;
      else if(sl_widened) target_sl = sl_for_old_price;
      double target_tp = CalculatePendingTakeProfit(type, target_price, tp_distance);
      ModifyPending(ticket, type, target_price, target_sl, target_tp);
   }
}

void EnsureEntryStructure()
{
   if(!InpEnableMovementScanner)
      return;
   // Spread safety is checked even when the tick signal fades, so an old pending
   // order cannot remain armed through a sudden spread blowout.
   if(!SpreadIsAcceptable(g_atr))
   {
      if(CountOurPendingOrders() > 0)
         CancelAllOurPendings();
      if(!g_spread_blocked)
         CsvWrite("ENTRY_PAUSE_SPREAD", "pending orders cancelled because current spread failed safety checks");
      g_spread_blocked = true;
      return;
   }
   g_spread_blocked = false;
   if(!HasQualifiedSignal())
   {
      if(InpCancelPendingWhenSignalDies && CountOurPendingOrders() > 0)
         CancelAllOurPendings();
      return;
   }
   if(TimeCurrent() < g_pause_until)
      return;

   int positions = CountOurPositions();
   datetime now = TimeCurrent();
   datetime current_m1_bar = iTime(g_symbol, PERIOD_M1, 0);

   // Do not immediately re-enter the same short-lived impulse after an SL/TP close.
   if(positions == 0 && g_last_exit_time > 0 &&
      now - g_last_exit_time < MathMax(0, InpPostExitCooldownSeconds))
   {
      if(CountOurPendingOrders() > 0) CancelAllOurPendings();
      return;
   }
   if(g_last_entry_time > 0 && now - g_last_entry_time < MathMax(0, InpMinimumSecondsBetweenEntries))
   {
      if(CountOurPendingOrders() > 0) CancelAllOurPendings();
      return;
   }
   if(InpOneEntryPerM1Bar && current_m1_bar > 0 && current_m1_bar == g_last_entry_m1_bar)
   {
      if(CountOurPendingOrders() > 0) CancelAllOurPendings();
      return;
   }

   int allowed_positions = DynamicPositionLimit();
   if(HasMixedDirections())
   {
      CancelAllOurPendings();
      return;
   }
   if(positions >= allowed_positions)
   {
      CancelAllOurPendings();
      return;
   }
   if(!InpEnableStacking && positions > 0)
      return;

   bool have_buy = HasOurDirection(POSITION_TYPE_BUY);
   bool have_sell = HasOurDirection(POSITION_TYPE_SELL);
   if(positions > 0)
   {
      double reference_price = 0.0;
      datetime reference_time = 0;
      int reference_direction = 0;
      if(!GetNewestOpenPosition(reference_price, reference_time, reference_direction))
         return;
      if((have_buy && reference_direction != 1) || (have_sell && reference_direction != -1))
         return;
      if(TimeCurrent() - reference_time < InpRearmCooldownSeconds)
         return;
      if(InpRequireContinuationSignal)
      {
         if(have_buy && !g_signal_up) return;
         if(have_sell && !g_signal_down) return;
      }
      if(InpMinimumAdvanceBetweenAddsATR > 0.0)
      {
         MqlTick current;
         if(!SymbolInfoTick(g_symbol, current)) return;
         double market_price = (have_buy ? current.ask : current.bid);
         double advance = (have_buy ? market_price - reference_price : reference_price - market_price);
         if(advance < g_atr * InpMinimumAdvanceBetweenAddsATR)
            return;
      }
   }

   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick)) return;
   double point = PointSize();
   double requested_lot = DynamicPositionLot();
   double distance = CalculateEntryDistance();
   if(point <= 0.0 || distance <= 0.0 || requested_lot <= 0.0)
   {
      Log("Entry geometry/volume unavailable; check symbol specification and broker minimum lot.");
      CsvWrite("ENTRY_GEOMETRY_SKIP", StringFormat("lot=%.3f;distance=%.5f", requested_lot, distance));
      return;
   }
   double buy_price = NormalizePrice(tick.ask + distance);
   double sell_price = NormalizePrice(tick.bid - distance);

   int selected_direction = 0;
   if(positions == 0 && !InpEnableDualStop)
   {
      if(g_signal_up && !g_signal_down) selected_direction = 1;
      else if(g_signal_down && !g_signal_up) selected_direction = -1;
      else if(g_signal_up && g_signal_down)
      {
         if(g_score_up >= g_score_down + 3.0) selected_direction = 1;
         else if(g_score_down >= g_score_up + 3.0) selected_direction = -1;
      }
      if(selected_direction == 0)
      {
         if(InpCancelPendingWhenSignalDies) CancelAllOurPendings();
         return;
      }
   }

   double lot = NormalizeRequestedEntryVolume(requested_lot);
   if(lot <= 0.0)
   {
      Log(StringFormat("BROKER VOLUME INVALID: requested lot %.3f cannot be normalized to this symbol's minimum/step/max or the EA lot ceiling %.3f.",
                       requested_lot, InpMaximumLotPerPosition));
      CsvWrite("BROKER_VOLUME_INVALID", StringFormat("requested=%.3f;ea_max=%.3f", requested_lot, InpMaximumLotPerPosition));
      return;
   }

   double buy_sl_distance = CalculateProtectedSLDistance(lot, buy_price, 1);
   double sell_sl_distance = CalculateProtectedSLDistance(lot, sell_price, -1);
   double buy_tp_distance = (InpTakeProfitRiskReward > 0.0 ? buy_sl_distance * InpTakeProfitRiskReward : 0.0);
   double sell_tp_distance = (InpTakeProfitRiskReward > 0.0 ? sell_sl_distance * InpTakeProfitRiskReward : 0.0);

   // Flat state: by default arm only the side supported by the current signal.
   // The old two-sided breakout bracket remains available as an explicit opt-in.
   if(positions == 0)
   {
      if(InpEnableDualStop)
      {
         if(buy_sl_distance > 0.0)
            MaintainOrPlacePending(ORDER_TYPE_BUY_STOP, buy_price, lot, buy_sl_distance, buy_tp_distance, "GH128_BRACKET_BUY");
         else
            CancelPendingType(ORDER_TYPE_BUY_STOP);
         if(sell_sl_distance > 0.0)
            MaintainOrPlacePending(ORDER_TYPE_SELL_STOP, sell_price, lot, sell_sl_distance, sell_tp_distance, "GH128_BRACKET_SELL");
         else
            CancelPendingType(ORDER_TYPE_SELL_STOP);
         return;
      }

      if(selected_direction > 0)
      {
         ulong opposite; double op, osl, otp; datetime ost;
         if(FindPending(ORDER_TYPE_SELL_STOP, opposite, op, osl, otp, ost))
         {
            if(!DeletePending(opposite) || OrderSelect(opposite)) return;
         }
         if(buy_sl_distance > 0.0)
            MaintainOrPlacePending(ORDER_TYPE_BUY_STOP, buy_price, lot, buy_sl_distance, buy_tp_distance, "GH128_SIGNAL_BUY");
         else
            CancelPendingType(ORDER_TYPE_BUY_STOP);
      }
      else if(selected_direction < 0)
      {
         ulong opposite; double op, osl, otp; datetime ost;
         if(FindPending(ORDER_TYPE_BUY_STOP, opposite, op, osl, otp, ost))
         {
            if(!DeletePending(opposite) || OrderSelect(opposite)) return;
         }
         if(sell_sl_distance > 0.0)
            MaintainOrPlacePending(ORDER_TYPE_SELL_STOP, sell_price, lot, sell_sl_distance, sell_tp_distance, "GH128_SIGNAL_SELL");
         else
            CancelPendingType(ORDER_TYPE_SELL_STOP);
      }
      else if(InpCancelPendingWhenSignalDies)
      {
         CancelAllOurPendings();
      }
      return;
   }

   // With an open position, only arm a continuation stop in the held direction.
   if(have_buy)
   {
      ulong opposite; double op, osl, otp; datetime ost;
      if(FindPending(ORDER_TYPE_SELL_STOP, opposite, op, osl, otp, ost)) DeletePending(opposite);
      if(buy_sl_distance > 0.0)
         MaintainOrPlacePending(ORDER_TYPE_BUY_STOP, buy_price, lot, buy_sl_distance,
                                buy_sl_distance * MathMax(0.0, InpTakeProfitRiskReward), "GH128_ADD_BUY");
      else
         CancelPendingType(ORDER_TYPE_BUY_STOP);
   }
   else if(have_sell)
   {
      ulong opposite; double op, osl, otp; datetime ost;
      if(FindPending(ORDER_TYPE_BUY_STOP, opposite, op, osl, otp, ost)) DeletePending(opposite);
      if(sell_sl_distance > 0.0)
         MaintainOrPlacePending(ORDER_TYPE_SELL_STOP, sell_price, lot, sell_sl_distance,
                                sell_sl_distance * MathMax(0.0, InpTakeProfitRiskReward), "GH128_ADD_SELL");
      else
         CancelPendingType(ORDER_TYPE_SELL_STOP);
   }
}

//------------------------------- POSITION MANAGEMENT ----------------
bool TrailTicketCanUpdate(const ulong ticket)
{
   int cooldown = MathMax(0, InpTrailModifyCooldownSeconds);
   if(cooldown == 0) return true;
   datetime now = TimeCurrent();
   for(int i = 0; i < GH_DEAL_CACHE; i++)
   {
      if(g_trail_tickets[i] == ticket)
         return (now - g_trail_update_times[i] >= cooldown);
   }
   return true; // First update for this position.
}

void MarkTrailTicketUpdated(const ulong ticket)
{
   for(int i = 0; i < GH_DEAL_CACHE; i++)
   {
      if(g_trail_tickets[i] == ticket)
      {
         g_trail_update_times[i] = TimeCurrent();
         return;
      }
   }
   int slot = g_trail_registry_next % GH_DEAL_CACHE;
   g_trail_tickets[slot] = ticket;
   g_trail_update_times[slot] = TimeCurrent();
   g_trail_registry_next++;
}

void ManageAdaptiveTrailing()
{
   if(!InpEnableAdaptiveTrailing || g_atr <= 0.0)
      return;
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick))
      return;
   double point = PointSize();
   if(point <= 0.0) return;
   double broker_min = BrokerMinimumDistancePrice();
   double spread = tick.ask - tick.bid;
   double trail_distance = MathMax(InpTrailMinimumDistancePoints * point,
                                   MathMax(g_atr * InpTrailDistanceATR,
                                           spread * InpTrailDistanceSpreadMultiple));
   trail_distance = MathMax(trail_distance, broker_min);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double old_sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double favorable_move = (type == POSITION_TYPE_BUY ? tick.bid - open_price : open_price - tick.ask);
      if(favorable_move <= 0.0 || !TrailTicketCanUpdate(ticket))
         continue;

      // Stage 1: protect a position near break-even once it has moved in its favor.
      // The offset is positive, but actual net profit still depends on commission/swap.
      if(InpBreakEvenActivationATR > 0.0 && favorable_move >= g_atr * InpBreakEvenActivationATR)
      {
         double offset = MathMax(0.0, InpBreakEvenOffsetPoints) * point;
         double be_candidate = (type == POSITION_TYPE_BUY ?
                                NormalizePriceUp(open_price + offset) :
                                NormalizePriceDown(open_price - offset));
         bool be_needed = (type == POSITION_TYPE_BUY ?
                           (old_sl <= 0.0 || old_sl < be_candidate - point * 0.5) :
                           (old_sl <= 0.0 || old_sl > be_candidate + point * 0.5));
         bool be_valid = (type == POSITION_TYPE_BUY ?
                          be_candidate < tick.bid - broker_min :
                          be_candidate > tick.ask + broker_min);
         if(be_needed && be_valid)
         {
            if(ModifyPositionStops(ticket, be_candidate, tp))
            {
               MarkTrailTicketUpdated(ticket);
               Log(StringFormat("BREAK-EVEN SET ticket=%I64u entry=%.*f sl=%.*f favorable_points=%.1f",
                                ticket, PriceDigits(), open_price, PriceDigits(), be_candidate,
                                favorable_move / point));
            }
            continue;
         }
      }

      // Stage 2: trail only after a materially larger favorable excursion.
      // This avoids the v1.27 behavior where a 0.10 ATR trigger plus spread
      // locked only a small fraction of the initial stop distance.
      double activation = MathMax(g_atr * InpTrailActivationATR,
                                  trail_distance + spread + 2.0 * point);
      if(favorable_move < activation)
         continue;

      double candidate = (type == POSITION_TYPE_BUY ? tick.bid - trail_distance : tick.ask + trail_distance);
      candidate = (type == POSITION_TYPE_BUY ? NormalizePriceDown(candidate) : NormalizePriceUp(candidate));
      bool improve = false;
      if(type == POSITION_TYPE_BUY)
      {
         if(candidate < tick.bid - broker_min &&
            (old_sl <= 0.0 || candidate > old_sl + InpTrailMinimumStepPoints * point))
            improve = true;
      }
      else
      {
         if(candidate > tick.ask + broker_min &&
            (old_sl <= 0.0 || candidate < old_sl - InpTrailMinimumStepPoints * point))
            improve = true;
      }
      if(improve && TrailTicketCanUpdate(ticket))
      {
         if(ModifyPositionStops(ticket, candidate, tp))
         {
            MarkTrailTicketUpdated(ticket);
            Log(StringFormat("TRAIL UPDATED ticket=%I64u entry=%.*f sl=%.*f favorable_points=%.1f trail_points=%.1f",
                             ticket, PriceDigits(), open_price, PriceDigits(), candidate,
                             favorable_move / point, trail_distance / point));
         }
      } // Never widens an existing stop.
   }
}

void ManageMomentumExit()
{
   if(!InpEnableMomentumExit)
      return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double floating = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double estimated_round_turn_fee = MathMax(0.0, InpEstimatedRoundTurnFeePerLot) * volume;
      bool reversal = (type == POSITION_TYPE_BUY ? g_signal_down : g_signal_up);
      if(reversal && floating - estimated_round_turn_fee >= InpMomentumExitMinimumProfit)
         ClosePositionTicket(ticket, "GH128_MOMENTUM_PROFIT_EXIT");
   }
}

//------------------------------- HISTORY RECONCILIATION -------------
bool DealWasSeen(const ulong ticket)
{
   for(int i = 0; i < g_seen_deal_count; i++)
   {
      if(g_seen_deals[i] == ticket)
         return true;
   }
   return false;
}

void RememberDeal(const ulong ticket)
{
   if(ticket == 0 || DealWasSeen(ticket)) return;
   g_seen_deals[g_seen_deal_head] = ticket;
   g_seen_deal_head = (g_seen_deal_head + 1) % GH_DEAL_CACHE;
   if(g_seen_deal_count < GH_DEAL_CACHE)
      g_seen_deal_count++;
}

void ReanchorStopsToActualFill(const long position_id, const ulong source_order)
{
   if(position_id <= 0 || source_order == 0 || !HistoryOrderSelect(source_order))
      return;

   double requested_entry = HistoryOrderGetDouble(source_order, ORDER_PRICE_OPEN);
   double requested_sl = HistoryOrderGetDouble(source_order, ORDER_SL);
   double requested_tp = HistoryOrderGetDouble(source_order, ORDER_TP);
   if(requested_entry <= 0.0 || requested_sl <= 0.0)
      return;

   double original_sl_distance = MathAbs(requested_entry - requested_sl);
   double original_tp_distance = (requested_tp > 0.0 ? MathAbs(requested_tp - requested_entry) : 0.0);
   double point = PointSize();
   double tick_size = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0.0) tick_size = point;
   if(point <= 0.0 || tick_size <= 0.0 || original_sl_distance <= 0.0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick))
      return;
   double broker_distance = BrokerMinimumDistancePrice();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber ||
         PositionGetInteger(POSITION_IDENTIFIER) != position_id)
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double actual_entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double current_sl = PositionGetDouble(POSITION_SL);
      double current_tp = PositionGetDouble(POSITION_TP);
      if(actual_entry <= 0.0)
         return;

      double slip_points = MathAbs(actual_entry - requested_entry) / point;
      double new_sl = (type == POSITION_TYPE_BUY ?
                       NormalizePriceDown(actual_entry - original_sl_distance) :
                       NormalizePriceUp(actual_entry + original_sl_distance));
      bool sl_valid = (type == POSITION_TYPE_BUY ?
                       new_sl < tick.bid - broker_distance :
                       new_sl > tick.ask + broker_distance);
      if(!sl_valid)
      {
         Log(StringFormat("FILL REANCHOR BLOCKED: position=%I64u slip=%.1f points; actual-price SL is inside broker stop/freeze distance; existing SL retained.",
                          ticket, slip_points));
         CsvWrite("FILL_REANCHOR_BLOCKED", StringFormat("position=%I64u;slip_points=%.1f;actual_entry=%.*f;new_sl=%.*f;bid=%.*f;ask=%.*f;broker_distance=%.*f",
                   ticket, slip_points, PriceDigits(), actual_entry, PriceDigits(), new_sl,
                   PriceDigits(), tick.bid, PriceDigits(), tick.ask, PriceDigits(), broker_distance));
         return;
      }

      double new_tp = 0.0;
      if(original_tp_distance > 0.0)
      {
         double candidate_tp = (type == POSITION_TYPE_BUY ?
                                NormalizePriceUp(actual_entry + original_tp_distance) :
                                NormalizePriceDown(actual_entry - original_tp_distance));
         bool tp_valid = (type == POSITION_TYPE_BUY ?
                          candidate_tp > tick.ask + broker_distance :
                          candidate_tp < tick.bid - broker_distance);
         new_tp = (tp_valid ? candidate_tp : current_tp);
      }

      bool sl_changed = (current_sl <= 0.0 || MathAbs(current_sl - new_sl) >= tick_size * 0.5);
      bool tp_changed = (original_tp_distance > 0.0 && new_tp > 0.0 &&
                         (current_tp <= 0.0 || MathAbs(current_tp - new_tp) >= tick_size * 0.5));
      if((sl_changed || tp_changed) && ModifyPositionStops(ticket, new_sl, new_tp))
      {
         double expected_loss = 0.0;
         ENUM_ORDER_TYPE calc_type = (type == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
         bool calc_ok = OrderCalcProfit(calc_type, g_symbol, PositionGetDouble(POSITION_VOLUME),
                                        actual_entry, new_sl, expected_loss);
         Log(StringFormat("FILL REANCHORED: position=%I64u slip=%.1f points; SL risk estimate=%s%.2f; actual=%.*f; SL=%.*f; TP=%.*f",
                          ticket, slip_points, (calc_ok ? "" : "n/a "), (calc_ok ? MathAbs(expected_loss) : 0.0),
                          PriceDigits(), actual_entry, PriceDigits(), new_sl, PriceDigits(), new_tp));
         CsvWrite("FILL_REANCHORED", StringFormat("position=%I64u;slip_points=%.1f;actual_entry=%.*f;sl=%.*f;tp=%.*f;estimated_sl_loss=%s%.4f",
                   ticket, slip_points, PriceDigits(), actual_entry, PriceDigits(), new_sl,
                   PriceDigits(), new_tp, (calc_ok ? "" : "n/a;"), (calc_ok ? MathAbs(expected_loss) : 0.0)));
      }
      return;
   }
}

void ProcessDeal(const ulong deal_ticket, const string source, const bool select_deal = true)
{
   if(deal_ticket == 0 || DealWasSeen(deal_ticket))
      return;
   // HistoryDealSelect resets the currently selected history list. Use it for transaction
   // callbacks, but not while iterating a HistorySelect() result in ReconcileHistory().
   if(select_deal && !HistoryDealSelect(deal_ticket))
      return;
   string deal_symbol = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
   ulong magic = (ulong)HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);
   if(deal_symbol != g_symbol || magic != InpMagicNumber)
      return;

   RememberDeal(deal_ticket);
   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
   ENUM_DEAL_TYPE deal_type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(deal_ticket, DEAL_TYPE);
   long position_id = HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
   if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
   {
      ulong source_order = (ulong)HistoryDealGetInteger(deal_ticket, DEAL_ORDER);
      ReanchorStopsToActualFill(position_id, source_order);
      g_last_entry_time = TimeCurrent();
      datetime active_bar = iTime(g_symbol, PERIOD_M1, 0);
      if(active_bar > 0) g_last_entry_m1_bar = active_bar;
      CsvWrite("ENTRY_SIGNAL_SNAPSHOT", StringFormat("position_id=%I64d;score_up=%.1f;score_down=%.1f;signal=%d;ema_m1=%d;ema_m5=%d;fast_speed=%.3f;fast_move=%.2f;direction_ratio=%.3f;efficiency=%.3f;atr=%.5f",
                                                       position_id, g_score_up, g_score_down, CurrentSignalCode(),
                                                       g_m1_bias, g_m5_bias, g_fast_speed, g_fast_move_points,
                                                       g_directional_ratio, g_efficiency, g_atr));
   }
   if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
      g_last_exit_time = TimeCurrent();

   double volume = HistoryDealGetDouble(deal_ticket, DEAL_VOLUME);
   double price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
   double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
   double commission = HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);
   double swap = HistoryDealGetDouble(deal_ticket, DEAL_SWAP);
   string details = StringFormat("deal=%I64u;position_id=%I64d;source=%s;entry=%s;type=%s;volume=%.2f;price=%.*f;profit=%.2f;commission=%.2f;swap=%.2f;score_up=%.1f;score_down=%.1f;ema_m1=%d;ema_m5=%d;fast_speed=%.3f;direction_ratio=%.3f;efficiency=%.3f",
                                 deal_ticket, position_id, source, EnumToString(entry), EnumToString(deal_type), volume,
                                 PriceDigits(), price, profit, commission, swap,
                                 g_score_up, g_score_down, g_m1_bias, g_m5_bias,
                                 g_fast_speed, g_directional_ratio, g_efficiency);
   Log("DEAL " + details);
   CsvWrite("DEAL", details);

   if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
   {
      if(InpEnableOCO)
         CancelOppositePendings();
   }
}

void ReconcileHistory()
{
   datetime now = TimeCurrent();
   if(g_last_history_scan > 0 && now - g_last_history_scan < MathMax(5, InpHistoryReconcileSeconds))
      return;
   datetime from_time = (g_last_history_scan > 0 ? g_last_history_scan - 5 : now - 86400);
   if(from_time < 0) from_time = 0;
   if(!HistorySelect(from_time, now))
      return;
   g_last_history_scan = now;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal > 0)
         ProcessDeal(deal, "HISTORY_RECONCILE", false);
   }
}

//------------------------------- STATUS / INIT ----------------------
void UpdateChartStatus()
{
   if(!InpShowChartStatus)
      return;
   string mode = (TradingPermitted() ? "TRADING ENABLED" : "RESEARCH / SIGNAL ONLY");
   string signal = (g_signal_up ? "UP" : (g_signal_down ? "DOWN" : "WAIT"));
   if(g_signal_up && g_signal_down) signal = "BOTH";
   MqlTick tick;
   double spread_points = 0.0;
   if(SymbolInfoTick(g_symbol, tick) && PointSize() > 0.0)
      spread_points = (tick.ask - tick.bid) / PointSize();
   Comment("XTRD OMIGA - GOLD HUNTER v1.28\n",
           "Symbol: ", g_symbol, " | Mode: ", mode, "\n",
           "Signal: ", signal, " | Scores U/D: ", DoubleToString(g_score_up, 1), "/", DoubleToString(g_score_down, 1), "\n",
           "Fast/base speed: ", DoubleToString(g_fast_speed, 2), "/", DoubleToString(g_slow_speed, 2), " pts/s\n",
           "Direction: ", DoubleToString(g_directional_ratio, 2), " | Efficiency: ", DoubleToString(g_efficiency, 2),
           " | EMA M1/M5: ", g_m1_bias, "/", g_m5_bias,
           " | Candle M1/M5: ", g_m1_candle_bias, "/", g_m5_candle_bias, "\n",
           "Spread: ", DoubleToString(spread_points, 1), " pts (EMA ", DoubleToString(g_spread_ema, 1), ") | ATR: ", DoubleToString(g_atr, PriceDigits()), "\n",
           "Positions: ", CountOurPositions(), "/", (InpAbsoluteMaxPositions <= 0 ? "UNLIMITED" : IntegerToString(DynamicPositionLimit())), " | Pendings: ", CountOurPendingOrders(),
           " | Lot now: ", DoubleToString(DynamicPositionLot(), 2),
           " | Account-loss guards: OFF | Position cap: ", (InpAbsoluteMaxPositions <= 0 ? "OFF" : IntegerToString(InpAbsoluteMaxPositions)), "\n",
           "Pause until: ", (g_pause_until > TimeCurrent() ? TimeToString(g_pause_until, TIME_SECONDS) : "none"));
}

int OnInit()
{
   g_symbol = (InpTradeSymbol == "" ? _Symbol : InpTradeSymbol);
   if(!SymbolSelect(g_symbol, true))
   {
      Print("[XTRD_GH128] Cannot select symbol ", g_symbol);
      return INIT_FAILED;
   }
   if(g_symbol != _Symbol)
   {
      Print("[XTRD_GH128] Attach the EA to the same chart symbol selected in InpTradeSymbol. OnTick is driven by the chart symbol.");
      return INIT_FAILED;
   }

   if(InpAbsoluteMaxPositions < 0 || InpStartingMaxPositions < 0 ||
      (InpAbsoluteMaxPositions > 0 && (InpStartingMaxPositions < 1 || InpStartingMaxPositions > InpAbsoluteMaxPositions)) ||
      InpMaxPendingOrders < 0 || InpInitialLot <= 0.0 || InpMaximumLotPerPosition < InpInitialLot ||
      InpLotIncrement <= 0.0 || InpBalanceStepForLotIncrease < 0.0 ||
      InpBalanceStepForExtraPosition < 0.0 || InpFastTickWindow < 2 ||
      InpSlowTickWindow < 2 || InpMinimumSignalScore < 0.0 || InpMinimumSignalScore > 100.0 ||
      InpSpreadEmaAlpha <= 0.0 || InpSpreadEmaAlpha > 1.0 || InpEntrySpreadMultiplier < 1.0 ||
      InpMinimumDirectionalRatio < 0.5 || InpMinimumDirectionalRatio > 1.0 ||
      InpM1FastEMA < 1 || InpM1SlowEMA <= InpM1FastEMA ||
      InpM5FastEMA < 1 || InpM5SlowEMA <= InpM5FastEMA ||
      InpTakeProfitRiskReward < 0.0 || InpInitialSLATRMultiplier <= 0.0 || InpTrailActivationATR < 0.0 ||
      InpBreakEvenActivationATR < 0.0 || InpBreakEvenOffsetPoints < 0.0)
   {
      Print("[XTRD_GH128] Invalid input combination. Check limits, lots, balance steps and tick windows.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!IsHedgingAccount())
      Print("[XTRD_GH128] Netting account detected: same-symbol entries are aggregated by the broker; EA will continue, but separate independent tickets are available only on hedging accounts.");

   long order_modes = SymbolInfoInteger(g_symbol, SYMBOL_ORDER_MODE);
   if((order_modes & SYMBOL_ORDER_STOP) != SYMBOL_ORDER_STOP)
   {
      Print("[XTRD_GH128] This symbol does not advertise STOP pending orders. BUY STOP / SELL STOP cannot be used.");
      return INIT_FAILED;
   }

   g_atr_handle = iATR(g_symbol, InpATRTimeframe, InpATRPeriod);
   if(g_atr_handle == INVALID_HANDLE)
   {
      Print("[XTRD_GH128] Failed to create ATR handle.");
      return INIT_FAILED;
   }

   if(InpUseM1ContextAsScore)
   {
      g_m1_fast_handle = iMA(g_symbol, PERIOD_M1, InpM1FastEMA, 0, MODE_EMA, PRICE_CLOSE);
      g_m1_slow_handle = iMA(g_symbol, PERIOD_M1, InpM1SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(g_m1_fast_handle == INVALID_HANDLE || g_m1_slow_handle == INVALID_HANDLE)
      {
         Print("[XTRD_GH128] Failed to create M1 EMA context handles.");
         return INIT_FAILED;
      }
   }
   if(InpUseM5ContextAsScore)
   {
      g_m5_fast_handle = iMA(g_symbol, PERIOD_M5, InpM5FastEMA, 0, MODE_EMA, PRICE_CLOSE);
      g_m5_slow_handle = iMA(g_symbol, PERIOD_M5, InpM5SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(g_m5_fast_handle == INVALID_HANDLE || g_m5_slow_handle == INVALID_HANDLE)
      {
         Print("[XTRD_GH128] Failed to create M5 EMA context handles.");
         return INIT_FAILED;
      }
   }

   OpenResearchLog();
   EventSetTimer(1);

   Log(StringFormat("v1.28 initialized. balance=%.2f start_positions=%d absolute_max=%d initial_lot=%.2f max_lot=%.2f lot_step=%.2f lot_balance_step=%.2f position_balance_step=%.2f",
                    AccountInfoDouble(ACCOUNT_BALANCE), InpStartingMaxPositions, InpAbsoluteMaxPositions,
                    InpInitialLot, InpMaximumLotPerPosition, InpLotIncrement,
                    InpBalanceStepForLotIncrease, InpBalanceStepForExtraPosition));
   Log("Signal model: configured tick-quality thresholds + last CLOSED M1/M5 context + non-opposing EMA alignment.");
   Log(StringFormat("Entry model: %s signal-directed pending entry, OCO and continuation stacking; Strategy Tester auto-executes by default.", (InpEnableDualStop ? "dual-stop" : "single-side")));
   Log(StringFormat("Pacing: post-exit=%ds; min-filled-entry-gap=%ds; one-entry-per-M1-bar=%s; EMA-alignment=%s",
                    InpPostExitCooldownSeconds, InpMinimumSecondsBetweenEntries,
                    (InpOneEntryPerM1Bar ? "true" : "false"), (InpRequireEMAAlignment ? "true" : "false")));
   Log(StringFormat("Exit model: ATR SL + %.2fR TP; break-even trigger=%.2f ATR offset=%.1f points; trail trigger=%.2f ATR distance=%.2f ATR/spread x%.2f; per-position modification timers.",
                    InpTakeProfitRiskReward, InpBreakEvenActivationATR, InpBreakEvenOffsetPoints,
                    InpTrailActivationATR, InpTrailDistanceATR, InpTrailDistanceSpreadMultiple));
   Log("No per-position cash/equity risk cap and no account-level drawdown entry halt.");
   Log(StringFormat("Entry availability: positions=%s; pending-order cap=%s; cooldowns=%d/%d/%d sec; broker free-margin reserve=%.1f%%.",
                    (InpAbsoluteMaxPositions <= 0 ? "UNLIMITED" : IntegerToString(InpAbsoluteMaxPositions)),
                    (InpMaxPendingOrders <= 0 ? "UNLIMITED" : IntegerToString(InpMaxPendingOrders)),
                    InpRearmCooldownSeconds, InpPostExitCooldownSeconds, InpMinimumSecondsBetweenEntries,
                    InpFreeMarginReservePercent));
   CsvWrite("INITIALIZED", StringFormat("balance=%.2f;equity=%.2f;hedging=%s;contract=%.2f;point=%.*f;ticksize=%.*f;tickvalue=%.5f",
                                        AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY),
                                        (IsHedgingAccount() ? "true" : "false"),
                                        SymbolInfoDouble(g_symbol, SYMBOL_TRADE_CONTRACT_SIZE),
                                        PriceDigits(), PointSize(), PriceDigits(),
                                        SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE),
                                        SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE)));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_atr_handle != INVALID_HANDLE) IndicatorRelease(g_atr_handle);
   if(g_m1_fast_handle != INVALID_HANDLE) IndicatorRelease(g_m1_fast_handle);
   if(g_m1_slow_handle != INVALID_HANDLE) IndicatorRelease(g_m1_slow_handle);
   if(g_m5_fast_handle != INVALID_HANDLE) IndicatorRelease(g_m5_fast_handle);
   if(g_m5_slow_handle != INVALID_HANDLE) IndicatorRelease(g_m5_slow_handle);
   if(g_csv_handle != INVALID_HANDLE)
   {
      FileFlush(g_csv_handle);
      FileClose(g_csv_handle);
      g_csv_handle = INVALID_HANDLE;
   }
   Comment("");
}

void OnTick()
{
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick))
      return;

   PushTick(tick);
   GetATR(g_atr);
   CalculateSignalMetrics();
   LogSignalIfChanged();

   // Exit and protection management is never blocked by the entry spread filter.
   ManageAdaptiveTrailing();
   ManageMomentumExit();
   CancelOppositePendings();

   if(g_tick_count >= MathMax(InpMinimumTicksForSignal, InpFastTickWindow + InpSlowTickWindow + 1) && g_atr > 0.0)
      EnsureEntryStructure();

   UpdateChartStatus();
}

void OnTimer()
{
   ReconcileHistory();
   if(TimeCurrent() - g_last_status_time >= 1)
   {
      g_last_status_time = TimeCurrent();
      UpdateChartStatus();
   }
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && trans.deal > 0)
      ProcessDeal(trans.deal, "TRADE_TRANSACTION");
   else if(trans.type == TRADE_TRANSACTION_ORDER_ADD ||
           trans.type == TRADE_TRANSACTION_ORDER_UPDATE ||
           trans.type == TRADE_TRANSACTION_ORDER_DELETE)
   {
      if(trans.symbol == "" || trans.symbol == g_symbol)
      {
         Log(StringFormat("ORDER EVENT type=%s order=%I64u", EnumToString(trans.type), trans.order));
         CsvWrite("ORDER_EVENT", StringFormat("type=%s;order=%I64u", EnumToString(trans.type), trans.order));
      }
   }
}
//+------------------------------------------------------------------+
