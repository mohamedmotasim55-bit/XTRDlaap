//+------------------------------------------------------------------+
//| XTRD OMIGA - GOLD HUNTER v1.24                                   |
//| v1.24: broader tick opportunity engine + lighter entry throttles |
//| Responsive tick-driven Dual Stop Gold Hunter Expert Advisor     |
//| Independent rebuild based on v1.02 source review.                 |
//| IMPORTANT: Live execution selectable; defaults are Strategy Tester oriented. Compile and test in MT5 first. |
//+------------------------------------------------------------------+
#property strict
#property version   "1.24"
#property description "Responsive tick-and-candle hunter: micro/impulse/expansion entries, dual stops, OCO, cash-capped SL, adaptive trailing."

//------------------------------- INPUTS -----------------------------
input group "01. General / Safety"
input string InpTradeSymbol                 = "";          // Empty = chart symbol
input ulong  InpMagicNumber                 = 26112410;
input bool   InpResearchMode                = false;        // true = no trade requests are sent
input bool   InpEnableTrading                = true;      // Strategy Tester auto-trades; explicitly enable for demo/live
input bool   InpSignalOnlyMode               = false;        // true = signals/logging only
input bool   InpRequireHedgingAccount        = true;        // Required for independent stacked positions
input int    InpDeviationPoints              = 30;
input int    InpAbsoluteMaxPositions         = 16;          // Hard maximum, not the starting target
input int    InpStartingMaxPositions         = 2;           // Starts with capacity for two open positions
input double InpBalanceStepForExtraPosition  = 5.0;         // Each +$5 balance adds one position slot, up to absolute max
input int    InpMaxPendingOrders             = 2;           // Initial dual-stop bracket
input double InpFreeMarginReservePercent     = 10.0;        // Broker/account margin reserve only
input int    InpExecutionPauseSeconds        = 10;
input int    InpPauseAfterNoMoneySeconds      = 120;
input int    InpPauseAfterMarketClosedSeconds = 300;

input group "02. Volume Scaling"
input double InpInitialLot                  = 0.01;
input double InpMaximumLotPerPosition       = 0.09;
input double InpLotIncrement                = 0.01;
input double InpBalanceStepForLotIncrease   = 10.0;       // Gradual +0.01 lot per each +$10 balance, still subject to cash-risk sizing
input double InpReferenceBalance            = 10.0;        // Balance at which initial lot/position capacity applies

input group "03. Tick Signal Engine"
input bool   InpEnableMovementScanner       = true;
input bool   InpEnableMicroHunter           = true;
input bool   InpEnableMomentumEngine        = true;
input int    InpFastTickWindow              = 4;
input int    InpSlowTickWindow              = 12;          // Shorter baseline for earlier response to gold impulses
input int    InpMinimumTicksForSignal       = 17;          // Fast + slow + one tick
input double InpMinimumDirectionalRatio     = 0.50;
input double InpMinimumFastMovePoints       = 0.8;
input double InpMinimumFastSpeedPointsSec   = 0.12;
input double InpMinimumSignalScore          = 36.0;        // More responsive; tick movement remains the primary evidence
input double InpMinimumEfficiency           = 0.03;        // Soft quality input, not a stand-alone hard gate
input bool   InpUseM1ContextAsScore         = true;        // Primary chart context; soft score only
input int    InpM1FastEMA                   = 5;
input int    InpM1SlowEMA                   = 13;
input int    InpATRPeriod                   = 14;
input ENUM_TIMEFRAMES InpATRTimeframe       = PERIOD_M1;
input bool   InpUseM5ContextAsScore         = true;        // Secondary context; soft score only
input int    InpM5FastEMA                   = 21;
input int    InpM5SlowEMA                   = 50;

input group "04. Spread Intelligence"
input int    InpHardMaxSpreadPoints         = 120;         // Absolute ceiling; set 0 to disable only this ceiling
input double InpSpreadSpikeMultiplier       = 3.5;         // Current spread must not spike above EMA * multiplier
input double InpSpreadToATRMaximum          = 1.00;        // Spread / ATR ceiling; set 0 to disable
input double InpSpreadEmaAlpha              = 0.08;
input int    InpSpreadWarmupSamples         = 20;

input group "05. Entry / Pending Orders"
input bool   InpEnableDualStop              = true;
input bool   InpEnableOCO                   = true;
input bool   InpEnableStacking              = true;
input bool   InpRequireContinuationSignal   = true;
input int    InpRearmCooldownSeconds        = 2;
input double InpMinimumAdvanceBetweenAddsATR= 0.05;        // Avoid duplicate stacking at nearly the same price
input double InpMinimumEntryDistancePoints  = 5.0;
input double InpEntryATRMultiplier          = 0.06;
input double InpMaximumEntryDistancePoints  = 300.0;
input double InpPendingRepricePoints        = 10.0;
input int    InpMinimumSecondsBetweenReprice= 1;
input int    InpPendingExpiryMinutes        = 3;           // 0 = use GTC if broker allows
input bool   InpCancelPendingWhenSignalDies = false;       // Expiry remains the normal stale-order control

input group "06. Open-Ended Profit / Cash Risk Protection"
input double InpMaxLossPerPositionUSD       = 0.50;        // Maximum modelled initial SL loss per position
input double InpInitialSLATRMultiplier      = 0.20;        // ATR component; spread/broker-safe minimum is also enforced
input bool   InpEnableAdaptiveTrailing       = true;
input double InpTrailActivationATR          = 0.10;        // Start trailing after a small favorable move
input double InpTrailDistanceATR            = 0.25;
input double InpTrailDistanceSpreadMultiple = 1.6;
input double InpTrailMinimumDistancePoints  = 20.0;
input int    InpTrailMinimumStepPoints      = 4;
input int    InpTrailModifyCooldownSeconds  = 1;
input bool   InpEnableMomentumExit           = false;       // Disabled: no fixed profit target; trailing manages exits
input double InpMomentumExitMinimumProfit   = 0.05;
input double InpEstimatedRoundTurnFeePerLot= 0.0;
input double InpMaxEquityDrawdownPercent    = 0.0;         // Disabled by default: avoid soft-guard deadlock; hard initial-equity floor remains active
input int    InpEquityGuardCooldownMinutes  = 10;          // Minimum wait before recovery can re-arm entries
input double InpHardEquityLossPercent       = 50.0;        // Permanent entry halt if equity falls this far below initial equity; 0 disables

input group "07. Research / Diagnostics"
input bool   InpWriteCSVLog                  = true;
input bool   InpVerboseJournal               = true;
input bool   InpShowChartStatus              = true;
input int    InpHistoryReconcileSeconds     = 30;


input group "08. Two-Layer Scout / Gatekeeper (v1.25)"
input bool   InpEnableScoutGate            = true;        // Master switch: Layer 1 (scout) + Layer 2 (gatekeeper)
input int    InpScoutScanSeconds           = 1;           // Scout scan throttle (seconds)
input double InpScoutImpulseATR            = 0.25;        // Impulse size required to emit a candidate (x ATR)
input double InpScoutMinScore              = 55.0;        // Minimum raw signal score to emit a candidate
input double InpGateMinQuality             = 65.0;        // Layer-2 admission threshold (0-100)
input double InpGateMinATRSpreadMultiple   = 3.0;         // Reject when ATR is below this multiple of spread
input bool   InpGateRequireM5Align         = true;        // Reject candidates against the M5 bias
input double InpGateMaxExtensionATR        = 1.2;         // Reject over-extended (chasing) impulses
input int    InpGateMaxTradesPerHour       = 40;          // Hourly admission cap
input double InpGateRollingWRFloor         = 35.0;        // Pause entries when rolling win rate is below this
input int    InpGateRollingWindow          = 20;          // Rolling sample size
input int    InpGateAdmitTTLSeconds        = 25;          // Lifetime of an admitted entry directive
input bool   InpUsePullbackLimitEntry      = true;        // Enter on pullback (limit) instead of chasing breakouts
input double InpPullbackATR                = 0.35;        // Pullback depth (x ATR)
input int    InpTimeStopSeconds            = 12;          // Close dead trades after this many seconds
input double InpTimeStopMinProfit          = 0.02;        // Time stop applies only when profit is at or below this
input double InpBreakEvenAtPoints          = 30.0;        // Move SL to break-even after this favourable move
input double InpBreakEvenPadPoints         = 4.0;         // Break-even padding beyond the live spread
input double InpWideTrailActivationATR     = 1.0;         // Wide trail activation (x ATR) when gate mode is on
input double InpWideTrailDistanceATR       = 1.5;         // Wide trail distance (x ATR) when gate mode is on
input double InpEquityLockPercent          = 25.0;        // Day-scoped equity high-water lock (0 disables)

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
datetime g_last_trailing_update_time = 0;
datetime g_last_delete_attempt_time = 0;
datetime g_last_research_log_time = 0;
datetime g_last_close_attempt = 0;
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
double   g_peak_equity = 0.0;
double   g_initial_equity = 0.0;
datetime g_entry_halt_until = 0;
bool     g_entry_halt = false;
bool     g_hard_entry_halt = false;
bool     g_spread_blocked = false;
double   g_score_up = 0.0;
double   g_score_down = 0.0;
int      g_m1_bias = 0;
int      g_m5_bias = 0;
bool     g_signal_up = false;
bool     g_signal_down = false;
string   g_equity_state_key = "";

// ---- Two-layer engine state (v1.25) ----
#define GH_SCOUT_QUEUE 32
#define GH_ROLLING_MAX 64

struct GHScoutCandidate
{
   datetime t;
   int      dir;
   double   price;
   double   score;
   double   atr;
   double   spread;
   double   extension;
};

GHScoutCandidate g_scout_q[GH_SCOUT_QUEUE];
int      g_scout_head = 0;
int      g_scout_count = 0;
ulong    g_scout_emitted = 0;
ulong    g_scout_admitted = 0;
ulong    g_scout_rejected = 0;
ulong    g_rej_vol = 0;
ulong    g_rej_trend = 0;
ulong    g_rej_ext = 0;
ulong    g_rej_quality = 0;
ulong    g_rej_rate = 0;
ulong    g_rej_regime = 0;
ulong    g_rej_daylock = 0;
datetime g_last_scout_scan = 0;
datetime g_last_trade_hour_ts = 0;
int      g_trades_this_hour = 0;
int      g_admit_dir = 0;
datetime g_admit_until = 0;
int      g_roll_results[GH_ROLLING_MAX];
int      g_roll_idx = 0;
int      g_roll_n = 0;
double   g_roll_wr = 50.0;
double   g_equity_day_hwm = 0.0;
datetime g_equity_lock_until = 0;
datetime g_day_stamp = 0;



// Persist the account high-water mark outside the Strategy Tester.
// Tester runs intentionally start from their own initial equity to keep
// separate optimization/backtest passes independent.
string EquityStateKey()
{
   string sym = g_symbol;
   StringReplace(sym, ".", "_");
   StringReplace(sym, "#", "_");
   return StringFormat("XTRD124_%I64d_%I64u_%s",
                       AccountInfoInteger(ACCOUNT_LOGIN), InpMagicNumber, sym);
}

void SaveEquityGuardState()
{
   if((bool)MQLInfoInteger(MQL_TESTER) || g_equity_state_key == "")
      return;
   GlobalVariableSet(g_equity_state_key + "_I", g_initial_equity);
   GlobalVariableSet(g_equity_state_key + "_P", g_peak_equity);
   GlobalVariableSet(g_equity_state_key + "_H", g_hard_entry_halt ? 1.0 : 0.0);
   GlobalVariableSet(g_equity_state_key + "_S", g_entry_halt ? 1.0 : 0.0);
   GlobalVariableSet(g_equity_state_key + "_U", (double)g_entry_halt_until);
}

void LoadEquityGuardState()
{
   if((bool)MQLInfoInteger(MQL_TESTER) || g_equity_state_key == "")
      return;
   if(GlobalVariableCheck(g_equity_state_key + "_I") &&
      GlobalVariableCheck(g_equity_state_key + "_P"))
   {
      double saved_initial = GlobalVariableGet(g_equity_state_key + "_I");
      double saved_peak = GlobalVariableGet(g_equity_state_key + "_P");
      if(saved_initial > 0.0 && saved_peak >= saved_initial)
      {
         g_initial_equity = saved_initial;
         g_peak_equity = saved_peak;
      }
   }
   if(GlobalVariableCheck(g_equity_state_key + "_H"))
      g_hard_entry_halt = (GlobalVariableGet(g_equity_state_key + "_H") > 0.5);
   if(GlobalVariableCheck(g_equity_state_key + "_S"))
      g_entry_halt = (GlobalVariableGet(g_equity_state_key + "_S") > 0.5);
   if(GlobalVariableCheck(g_equity_state_key + "_U"))
      g_entry_halt_until = (datetime)GlobalVariableGet(g_equity_state_key + "_U");
}

//------------------------------- UTILITIES --------------------------
void Log(const string message)
{
   if(InpVerboseJournal)
      Print("[XTRD_GH123] ", message);
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
   int seconds = InpExecutionPauseSeconds;
   if(retcode == TRADE_RETCODE_MARKET_CLOSED)
      seconds = InpPauseAfterMarketClosedSeconds;
   else if(retcode == TRADE_RETCODE_NO_MONEY)
      seconds = InpPauseAfterNoMoneySeconds;
   else if(retcode == TRADE_RETCODE_INVALID_STOPS || retcode == TRADE_RETCODE_INVALID_PRICE)
      seconds = MathMax(seconds, 30);
   g_consecutive_send_errors++;
   if(g_consecutive_send_errors >= 3)
      seconds = MathMax(seconds, 60);
   if(g_consecutive_send_errors >= 5)
      seconds = MathMax(seconds, 120);
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
   string file_name = StringFormat("XTRD_GH123_%s_%I64u.csv", safe_symbol, InpMagicNumber);
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
   bool candle_support_up = (g_m1_candle_bias > 0 || g_m1_bias > 0 || g_m5_candle_bias > 0 || g_m5_bias > 0);
   bool candle_support_down = (g_m1_candle_bias < 0 || g_m1_bias < 0 || g_m5_candle_bias < 0 || g_m5_bias < 0);
   bool enough_activity = (moves >= (int)MathMax(2, InpFastTickWindow / 3));
   bool enough_move = (abs_move >= MathMax(0.6, InpMinimumFastMovePoints * 0.50) ||
                       (g_m1_candle_strength >= 0.58 && abs_move >= 0.30));
   bool enough_speed = (g_fast_speed >= InpMinimumFastSpeedPointsSec * 0.45 ||
                        abs_move >= MathMax(3.0, (g_atr / point) * 0.08));
   bool enough_direction = (g_directional_ratio >= MathMax(0.50, InpMinimumDirectionalRatio - 0.06) ||
                            (fast_delta > 0.0 && candle_support_up) ||
                            (fast_delta < 0.0 && candle_support_down));
   bool enough_efficiency = (g_efficiency >= MathMax(0.025, InpMinimumEfficiency * 0.50) ||
                             g_m1_candle_strength >= 0.65 || g_m5_candle_strength >= 0.70);
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
                         (g_score_up >= InpMinimumSignalScore - 5.0 || expansion_move));
      bool impulse_down = (InpEnableMomentumEngine && fast_delta < 0.0 &&
                           (g_acceleration_ratio >= 0.90 || expansion_move) &&
                           (g_score_down >= InpMinimumSignalScore - 5.0 || expansion_move));
      g_signal_up = (micro_up || impulse_up);
      g_signal_down = (micro_down || impulse_down);
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
      g_pause_until = TimeCurrent() + MathMax(5, InpExecutionPauseSeconds);
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
      g_pause_until = TimeCurrent() + MathMax(10, InpPauseAfterNoMoneySeconds);
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
         g_pause_until = TimeCurrent() + MathMax(10, InpPauseAfterNoMoneySeconds);
      else
         g_pause_until = TimeCurrent() + MathMax(5, InpExecutionPauseSeconds);
      return false;
   }
   // OrderCheck supplies the projected free margin after this exact request.
   // Keep the configured reserve based on the result, not only the isolated OrderCalcMargin estimate.
   if(check.margin_free < minimum_reserve)
   {
      Log(StringFormat("ORDERCHECK RESERVE SKIP: projected free margin %.2f below reserve %.2f",
                       check.margin_free, minimum_reserve));
      CsvWrite("ORDERCHECK_RESERVE_SKIP", StringFormat("projected_free=%.2f;reserve=%.2f",
                                                        check.margin_free, minimum_reserve));
      g_pause_until = TimeCurrent() + MathMax(10, InpPauseAfterNoMoneySeconds);
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
   ENUM_ORDER_TYPE profit_type = ((type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_LIMIT) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
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
   if(!TradingPermitted() || TimeCurrent() < g_pause_until || !PositionSelectByTicket(ticket))
      return false;
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

   ulong ticket; double price, sl, tp; datetime setup;
   ENUM_ORDER_TYPE unwanted = (have_buy ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP);
   while(FindPending(unwanted, ticket, price, sl, tp, setup))
   {
      if(!DeletePending(ticket)) break;
      // Repeat only while a matching order is still visible; avoids stale duplicate OCO tickets.
      if(!OrderSelect(ticket)) break;
   }
   ENUM_ORDER_TYPE unwanted_limit = (have_buy ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_BUY_LIMIT);
   while(FindPending(unwanted_limit, ticket, price, sl, tp, setup))
   {
      if(!DeletePending(ticket)) break;
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
                                     MathMax(spread_points * 1.5 * point, BrokerMinimumDistancePrice())));
   if(InpMaximumEntryDistancePoints > 0.0)
      distance = MathMin(distance, InpMaximumEntryDistancePoints * point);
   distance = MathMax(distance, BrokerMinimumDistancePrice());
   return distance;
}

double EstimateInitialStopLoss(const double volume, const double entry_price,
                               const double distance, const int direction)
{
   double stop_price = (direction > 0 ? entry_price - distance : entry_price + distance);
   stop_price = (direction > 0 ? NormalizePriceDown(stop_price) : NormalizePriceUp(stop_price));
   double profit = 0.0;
   ENUM_ORDER_TYPE calc_type = (direction > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcProfit(calc_type, g_symbol, volume, entry_price, stop_price, profit))
      return -1.0;
   return MathAbs(profit);
}

double CalculateProtectedSLDistance(const double volume, const double entry_price, const int direction)
{
   double point = PointSize();
   MqlTick tick;
   if(point <= 0.0 || volume <= 0.0 || entry_price <= 0.0 || InpMaxLossPerPositionUSD <= 0.0 ||
      !SymbolInfoTick(g_symbol, tick))
      return 0.0;

   // A BUY is opened at Ask but its SL is triggered against Bid; SELL is the inverse.
   // The minimum stop distance must cover the live spread, broker distance and a buffer.
   double spread = MathMax(0.0, tick.ask - tick.bid);
   double broker_distance = BrokerMinimumDistancePrice();
   double safety_buffer = MathMax(2.0 * point, spread * 0.10);
   double spread_safe_distance = spread + broker_distance + safety_buffer;
   double minimum_distance = NormalizeDistanceUp(MathMax(spread_safe_distance, InpTrailMinimumDistancePoints * point));
   double desired_distance = NormalizeDistanceUp(MathMax(minimum_distance, g_atr * InpInitialSLATRMultiplier));

   // First verify the minimum mechanically safe stop is affordable. If not, do not place the entry.
   double minimum_loss = EstimateInitialStopLoss(volume, entry_price, minimum_distance, direction);
   if(minimum_loss < 0.0)
   {
      Log("RISK SKIP: OrderCalcProfit failed for spread-aware initial stop.");
      CsvWrite("RISK_CALC_FAIL", StringFormat("direction=%d;volume=%.2f;distance_points=%.1f", direction, volume, minimum_distance / point));
      return 0.0;
   }
   if(minimum_loss > InpMaxLossPerPositionUSD + 0.000001)
   {
      Log(StringFormat("RISK SKIP: minimum spread/broker-safe SL risk %.2f exceeds per-position cap %.2f", minimum_loss, InpMaxLossPerPositionUSD));
      CsvWrite("RISK_SKIP", StringFormat("risk=%.4f;cap=%.4f;distance_points=%.1f;spread_points=%.1f;broker_points=%.1f",
                                            minimum_loss, InpMaxLossPerPositionUSD, minimum_distance / point,
                                            spread / point, broker_distance / point));
      return 0.0;
   }

   // Prefer the ATR-sized breathing room, but compress it to the cash cap when possible.
   // This keeps large-volatility entries available without ever intentionally exceeding $0.50.
   double desired_loss = EstimateInitialStopLoss(volume, entry_price, desired_distance, direction);
   double chosen_distance = desired_distance;
   if(desired_loss < 0.0)
      return 0.0;
   if(desired_loss > InpMaxLossPerPositionUSD + 0.000001)
   {
      double low = minimum_distance;
      double high = desired_distance;
      double tick_size = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tick_size <= 0.0) tick_size = point;
      for(int iteration = 0; iteration < 24; iteration++)
      {
         double middle = (low + high) * 0.5;
         double test_distance = NormalizeDistanceUp(middle);
         double test_loss = EstimateInitialStopLoss(volume, entry_price, test_distance, direction);
         if(test_loss >= 0.0 && test_loss <= InpMaxLossPerPositionUSD)
            low = middle;
         else
            high = middle;
      }
      chosen_distance = NormalizeDistanceUp(MathMax(minimum_distance, MathFloor(low / tick_size + 1e-9) * tick_size));
      // A final exact cash check after price/tick alignment.
      double final_loss = EstimateInitialStopLoss(volume, entry_price, chosen_distance, direction);
      while(final_loss > InpMaxLossPerPositionUSD + 0.000001 && chosen_distance - tick_size >= minimum_distance - 1e-9)
      {
         chosen_distance = NormalizeDistanceUp(chosen_distance - tick_size);
         final_loss = EstimateInitialStopLoss(volume, entry_price, chosen_distance, direction);
      }
      if(final_loss < 0.0 || final_loss > InpMaxLossPerPositionUSD + 0.000001)
      {
         CsvWrite("RISK_SKIP", StringFormat("cap_fit_failed;min_loss=%.4f;cap=%.4f", minimum_loss, InpMaxLossPerPositionUSD));
         return 0.0;
      }
   }

   double estimated_loss = EstimateInitialStopLoss(volume, entry_price, chosen_distance, direction);
   CsvWrite("SL_GEOMETRY", StringFormat("direction=%d;distance_points=%.1f;spread_points=%.1f;broker_points=%.1f;estimated_loss=%.4f;cap=%.2f",
                                        direction, chosen_distance / point, spread / point, broker_distance / point,
                                        estimated_loss, InpMaxLossPerPositionUSD));
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
   double new_tp = 0.0;
   new_sl = (type == ORDER_TYPE_BUY_STOP ? NormalizePriceDown(new_sl) : NormalizePriceUp(new_sl));
   new_tp = NormalizePrice(new_tp);

   if(!PendingPriceIsSafe(type, desired_price))
      return;

   if(!exists)
   {
      if(CountOurPendingOrders() >= InpMaxPendingOrders)
         return;
      SendPending(type, volume, desired_price, new_sl, new_tp, comment);
      return;
   }

   double threshold = MathMax(1.0, InpPendingRepricePoints) * PointSize();
   bool price_changed = (MathAbs(old_price - desired_price) >= threshold &&
                         TimeCurrent() - g_last_reprice_time >= InpMinimumSecondsBetweenReprice);
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

   if((price_changed || sl_widened) && TimeCurrent() - g_last_reprice_time >= InpMinimumSecondsBetweenReprice)
   {
      // Avoid modifying an order inside the broker's freeze zone.
      double freeze_distance = SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL) * PointSize();
      MqlTick tick;
      if(!SymbolInfoTick(g_symbol, tick)) return;
      if(type == ORDER_TYPE_BUY_STOP && MathAbs(old_price - tick.ask) <= freeze_distance) return;
      if(type == ORDER_TYPE_SELL_STOP && MathAbs(old_price - tick.bid) <= freeze_distance) return;
      double target_price = (price_changed ? desired_price : old_price);
      double target_sl = (price_changed ? new_sl : sl_for_old_price);
      ModifyPending(ticket, type, target_price, target_sl, new_tp);
   }
}

void EnsureEntryStructure()
{
   if(!InpEnableDualStop || !InpEnableMovementScanner)
      return;
   // Spread safety is checked even when the tick signal fades, so an old pending
   // bracket cannot remain armed through a sudden spread blowout.
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
   double lot = DynamicPositionLot();
   double distance = CalculateEntryDistance();
   if(point <= 0.0 || distance <= 0.0 || lot <= 0.0)
   {
      Log("Entry geometry/volume unavailable; check symbol specification and broker minimum lot.");
      CsvWrite("ENTRY_GEOMETRY_SKIP", StringFormat("lot=%.3f;distance=%.5f", lot, distance));
      return;
   }
   double buy_price = NormalizePrice(tick.ask + distance);
   double sell_price = NormalizePrice(tick.bid - distance);
   double buy_sl_distance = CalculateProtectedSLDistance(lot, buy_price, 1);
   double sell_sl_distance = CalculateProtectedSLDistance(lot, sell_price, -1);


   // Flat state: arm a two-sided breakout bracket. Once one side fills, OCO removes the other.
   if(positions == 0)
   {
      if(buy_sl_distance > 0.0)
         MaintainOrPlacePending(ORDER_TYPE_BUY_STOP, buy_price, lot, buy_sl_distance, 0.0, "GH124_BRACKET_BUY");
      else
         CancelPendingType(ORDER_TYPE_BUY_STOP);
      if(sell_sl_distance > 0.0)
         MaintainOrPlacePending(ORDER_TYPE_SELL_STOP, sell_price, lot, sell_sl_distance, 0.0, "GH124_BRACKET_SELL");
      else
         CancelPendingType(ORDER_TYPE_SELL_STOP);
      return;
   }

   // With an open position, only arm a continuation stop in the held direction.
   if(have_buy)
   {
      ulong opposite; double op, osl, otp; datetime ost;
      if(FindPending(ORDER_TYPE_SELL_STOP, opposite, op, osl, otp, ost)) DeletePending(opposite);
      if(buy_sl_distance > 0.0)
         MaintainOrPlacePending(ORDER_TYPE_BUY_STOP, buy_price, lot, buy_sl_distance, 0.0, "GH124_ADD_BUY");
      else
         CancelPendingType(ORDER_TYPE_BUY_STOP);
   }
   else if(have_sell)
   {
      ulong opposite; double op, osl, otp; datetime ost;
      if(FindPending(ORDER_TYPE_BUY_STOP, opposite, op, osl, otp, ost)) DeletePending(opposite);
      if(sell_sl_distance > 0.0)
         MaintainOrPlacePending(ORDER_TYPE_SELL_STOP, sell_price, lot, sell_sl_distance, 0.0, "GH124_ADD_SELL");
      else
         CancelPendingType(ORDER_TYPE_SELL_STOP);
   }
}

//------------------------------- POSITION MANAGEMENT ----------------
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
   double active_trail_atr = (InpEnableScoutGate ? InpWideTrailDistanceATR : InpTrailDistanceATR);
   double trail_distance = MathMax(InpTrailMinimumDistancePoints * point,
                                   MathMax(g_atr * active_trail_atr,
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
      double tp = 0.0;
      double favorable_move = (type == POSITION_TYPE_BUY ? tick.bid - open_price : open_price - tick.ask);
      double active_activation_atr = (InpEnableScoutGate ? InpWideTrailActivationATR : InpTrailActivationATR);
      double activation = MathMax(g_atr * active_activation_atr, InpTrailMinimumDistancePoints * point);
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
      if(improve && TimeCurrent() - g_last_trailing_update_time >= MathMax(0, InpTrailModifyCooldownSeconds))
      {
         if(ModifyPositionStops(ticket, candidate, tp))
            g_last_trailing_update_time = TimeCurrent();
      } // Never widens an existing stop.
   }
}


//================= TWO-LAYER ENGINE (LAYER 1 + LAYER 2) =============
void RecordDealOutcome(const ulong deal_ticket)
{
   if(deal_ticket == 0) return;
   if(!HistoryDealSelect(deal_ticket)) return;
   if(HistoryDealGetString(deal_ticket, DEAL_SYMBOL) != g_symbol) return;
   if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) return;
   double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT)
                 + HistoryDealGetDouble(deal_ticket, DEAL_SWAP)
                 + HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);
   g_roll_results[g_roll_idx] = (profit > 0.0 ? 1 : 0);
   g_roll_idx = (g_roll_idx + 1) % GH_ROLLING_MAX;
   if(g_roll_n < GH_ROLLING_MAX) g_roll_n++;
   int wins = 0;
   for(int i = 0; i < g_roll_n; i++) wins += g_roll_results[i];
   g_roll_wr = (g_roll_n > 0 ? 100.0 * (double)wins / (double)g_roll_n : 50.0);
}

bool RateGateOpen()
{
   datetime hour_stamp = (datetime)((long)TimeCurrent() - (long)TimeCurrent() % 3600);
   if(hour_stamp != g_last_trade_hour_ts)
   {
      g_last_trade_hour_ts = hour_stamp;
      g_trades_this_hour = 0;
   }
   return (InpGateMaxTradesPerHour <= 0 || g_trades_this_hour < InpGateMaxTradesPerHour);
}

bool RegimeGateOpen()
{
   if(InpGateRollingWRFloor <= 0.0) return true;
   if(g_roll_n < MathMin(InpGateRollingWindow, 10)) return true;
   return (g_roll_wr >= InpGateRollingWRFloor);
}

// LAYER 1: sprays candidate opportunities. Never sends an order.
void ScoutScan()
{
   if(!InpEnableScoutGate) return;
   if(TimeCurrent() - g_last_scout_scan < MathMax(0, InpScoutScanSeconds)) return;
   g_last_scout_scan = TimeCurrent();
   if(g_atr <= 0.0) return;
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick)) return;
   double point = PointSize();
   if(point <= 0.0) return;

   double impulse = MathAbs(g_fast_move_points) * point;
   if(impulse < InpScoutImpulseATR * g_atr) return;

   int dir = (g_fast_move_points > 0.0 ? 1 : -1);
   double score = (dir > 0 ? g_score_up : g_score_down);
   if(score < InpScoutMinScore) return;

   double atr_points = g_atr / point;
   double extension = (atr_points > 0.0 ? (impulse / point) / atr_points : 0.0);

   GHScoutCandidate c;
   c.t = TimeCurrent();
   c.dir = dir;
   c.price = (tick.ask + tick.bid) * 0.5;
   c.score = score;
   c.atr = g_atr;
   c.spread = MathMax(0.0, tick.ask - tick.bid);
   c.extension = extension;

   g_scout_q[g_scout_head] = c;
   g_scout_head = (g_scout_head + 1) % GH_SCOUT_QUEUE;
   if(g_scout_count < GH_SCOUT_QUEUE) g_scout_count++;
   g_scout_emitted++;
}

double GateQuality(const GHScoutCandidate &c)
{
   double point = PointSize();
   double atr_points = (point > 0.0 ? c.atr / point : 0.0);
   double spread_points = MathMax(1.0, c.spread / point);
   double vol_ratio = atr_points / spread_points;

   double q_score = MathMin(35.0, MathMax(0.0, (c.score - 50.0) * 1.4));
   double q_vol   = MathMin(25.0, MathMax(0.0, (vol_ratio - 1.5) * 6.0));
   int bias = (c.dir > 0 ? g_m5_bias : -g_m5_bias);
   double q_trend = (bias > 0 ? 20.0 : 0.0);
   double q_time  = MathMax(0.0, 20.0 - c.extension * 12.0);
   return q_score + q_vol + q_trend + q_time;
}

// LAYER 2: receives candidates, admits only the qualified ones.
void Gatekeeper()
{
   if(!InpEnableScoutGate) return;
   if(g_admit_dir != 0) return;
   if(g_scout_count <= 0) return;

   int idx = (g_scout_head - 1 + GH_SCOUT_QUEUE) % GH_SCOUT_QUEUE;
   GHScoutCandidate c = g_scout_q[idx];
   if(TimeCurrent() - c.t > MathMax(3, InpScoutScanSeconds * 3)) return;

   double point = PointSize();
   double atr_points = (point > 0.0 ? c.atr / point : 0.0);
   double spread_points = MathMax(1.0, c.spread / point);
   double vol_ratio = atr_points / spread_points;

   string reason = "";
   if(g_equity_lock_until > TimeCurrent())                     { reason = "DAYLOCK"; g_rej_daylock++; }
   else if(vol_ratio < InpGateMinATRSpreadMultiple)             { reason = "VOL";     g_rej_vol++; }
   else if(InpGateRequireM5Align && (c.dir > 0 ? g_m5_bias : -g_m5_bias) <= 0) { reason = "TREND"; g_rej_trend++; }
   else if(c.extension > InpGateMaxExtensionATR)                { reason = "EXT";     g_rej_ext++; }
   else if(!RateGateOpen())                                     { reason = "RATE";    g_rej_rate++; }
   else if(!RegimeGateOpen())                                   { reason = "REGIME";  g_rej_regime++; }

   double q = 0.0;
   if(reason == "")
   {
      q = GateQuality(c);
      if(q < InpGateMinQuality) { reason = "QUALITY"; g_rej_quality++; }
   }

   if(reason != "")
   {
      g_scout_rejected++;
      CsvWrite("GATE_REJECT", StringFormat("reason=%s;dir=%d;score=%.1f;vol_ratio=%.2f;ext=%.2f;q=%.1f",
                                           reason, c.dir, c.score, vol_ratio, c.extension, q));
      return;
   }

   g_admit_dir = c.dir;
   g_admit_until = TimeCurrent() + MathMax(5, InpGateAdmitTTLSeconds);
   g_scout_admitted++;
   Log(StringFormat("GATE ADMIT dir=%d q=%.1f score=%.1f vol_ratio=%.2f ext=%.2f",
                    c.dir, q, c.score, vol_ratio, c.extension));
   CsvWrite("GATE_ADMIT", StringFormat("dir=%d;q=%.1f;score=%.1f;vol_ratio=%.2f;ext=%.2f",
                                       c.dir, q, c.score, vol_ratio, c.extension));
}

// Execution: only an admitted directive may place an order.
void ExecuteAdmittedEntry()
{
   if(!InpEnableScoutGate) return;
   if(g_admit_dir == 0) return;
   if(TimeCurrent() > g_admit_until) { g_admit_dir = 0; return; }
   if(CountOurPositions() >= DynamicPositionLimit()) { g_admit_dir = 0; return; }
   if(CountOurPendingOrders() > 0) { g_admit_dir = 0; return; }

   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick)) return;
   double point = PointSize();
   double lot = DynamicPositionLot();
   if(point <= 0.0 || lot <= 0.0) { g_admit_dir = 0; return; }

   double min_dist = BrokerMinimumDistancePrice();
   ENUM_ORDER_TYPE type = ORDER_TYPE_BUY_STOP;
   double price = 0.0;

   if(InpUsePullbackLimitEntry)
   {
      double pull = MathMax(InpPullbackATR * g_atr, min_dist);
      if(g_admit_dir > 0)
      {
         type = ORDER_TYPE_BUY_LIMIT;
         price = NormalizePrice(tick.bid - pull);
         if(tick.ask - price < min_dist) { g_admit_dir = 0; return; }
      }
      else
      {
         type = ORDER_TYPE_SELL_LIMIT;
         price = NormalizePrice(tick.ask + pull);
         if(price - tick.bid < min_dist) { g_admit_dir = 0; return; }
      }
   }
   else
   {
      double dist = CalculateEntryDistance();
      if(dist <= 0.0) { g_admit_dir = 0; return; }
      if(g_admit_dir > 0)
      {
         type = ORDER_TYPE_BUY_STOP;
         price = NormalizePrice(tick.ask + dist);
         if(price < tick.ask + min_dist) { g_admit_dir = 0; return; }
      }
      else
      {
         type = ORDER_TYPE_SELL_STOP;
         price = NormalizePrice(tick.bid - dist);
         if(price > tick.bid - min_dist) { g_admit_dir = 0; return; }
      }
   }

   double sl_distance = CalculateProtectedSLDistance(lot, price, g_admit_dir);
   if(sl_distance <= 0.0) { g_admit_dir = 0; return; }
   double sl = (g_admit_dir > 0 ? NormalizePriceDown(price - sl_distance)
                                : NormalizePriceUp(price + sl_distance));

   if(SendPending(type, lot, price, sl, 0.0, "GH125_GATE_ADMIT"))
   {
      g_admit_dir = 0;
      g_trades_this_hour++;
      Log(StringFormat("GATE EXECUTED %s lot=%.2f price=%.*f sl=%.*f",
                       EnumToString(type), lot, PriceDigits(), price, PriceDigits(), sl));
   }
}

// Exit hygiene: kill dead trades, then protect the ones that work.
void ManageTimeStopAndBreakEven()
{
   double point = PointSize();
   if(point <= 0.0) return;
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick)) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);

      if(InpTimeStopSeconds > 0 && TimeCurrent() - opened >= InpTimeStopSeconds &&
         profit <= InpTimeStopMinProfit)
      {
         ClosePositionTicket(ticket, "GH125_TIME_STOP");
         continue;
      }

      if(InpBreakEvenAtPoints <= 0.0) continue;
      double be_offset = MathMax(0.0, tick.ask - tick.bid) + InpBreakEvenPadPoints * point;
      if(type == POSITION_TYPE_BUY)
      {
         double favourable = tick.bid - open_price;
         double target = NormalizePriceDown(open_price + be_offset);
         if(favourable >= InpBreakEvenAtPoints * point &&
            (sl <= 0.0 || sl < target - point))
            ModifyPositionStops(ticket, target, tp);
      }
      else
      {
         double favourable = open_price - tick.ask;
         double target = NormalizePriceUp(open_price - be_offset);
         if(favourable >= InpBreakEvenAtPoints * point &&
            (sl <= 0.0 || sl > target + point))
            ModifyPositionStops(ticket, target, tp);
      }
   }
}

// Day-scoped high-water lock: protects gains without creating a deadlock.
void ManageEquityDayLock()
{
   if(InpEquityLockPercent <= 0.0) return;
   datetime day_stamp = (datetime)((long)TimeCurrent() - (long)TimeCurrent() % 86400);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(day_stamp != g_day_stamp)
   {
      g_day_stamp = day_stamp;
      g_equity_day_hwm = equity;
      g_equity_lock_until = 0;
   }
   if(equity > g_equity_day_hwm) g_equity_day_hwm = equity;
   if(g_equity_lock_until > TimeCurrent()) return;
   if(g_equity_day_hwm <= 0.0) return;
   double lock_level = g_equity_day_hwm * (1.0 - InpEquityLockPercent / 100.0);
   if(equity <= lock_level)
   {
      g_equity_lock_until = day_stamp + 86400;
      CancelAllOurPendings();
      Log(StringFormat("EQUITY DAY LOCK equity %.2f <= %.2f (day high-water %.2f minus %.1f%%). Entries locked until next day.",
                       equity, lock_level, g_equity_day_hwm, InpEquityLockPercent));
      CsvWrite("EQUITY_DAY_LOCK", StringFormat("equity=%.2f;hwm=%.2f;level=%.2f",
                                               equity, g_equity_day_hwm, lock_level));
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
         ClosePositionTicket(ticket, "GH124_MOMENTUM_PROFIT_EXIT");
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
   double volume = HistoryDealGetDouble(deal_ticket, DEAL_VOLUME);
   double price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
   double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
   double commission = HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);
   double swap = HistoryDealGetDouble(deal_ticket, DEAL_SWAP);
   string details = StringFormat("deal=%I64u;source=%s;entry=%s;type=%s;volume=%.2f;price=%.*f;profit=%.2f;commission=%.2f;swap=%.2f",
                                 deal_ticket, source, EnumToString(entry), EnumToString(deal_type), volume,
                                 PriceDigits(), price, profit, commission, swap);
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
   Comment("XTRD OMIGA - GOLD HUNTER v1.24\n",
           "Symbol: ", g_symbol, " | Mode: ", mode, "\n",
           "Signal: ", signal, " | Scores U/D: ", DoubleToString(g_score_up, 1), "/", DoubleToString(g_score_down, 1), "\n",
           "Fast/base speed: ", DoubleToString(g_fast_speed, 2), "/", DoubleToString(g_slow_speed, 2), " pts/s\n",
           "Direction: ", DoubleToString(g_directional_ratio, 2), " | Efficiency: ", DoubleToString(g_efficiency, 2),
           " | EMA M1/M5: ", g_m1_bias, "/", g_m5_bias,
           " | Candle M1/M5: ", g_m1_candle_bias, "/", g_m5_candle_bias, "\n",
           "Spread: ", DoubleToString(spread_points, 1), " pts (EMA ", DoubleToString(g_spread_ema, 1), ") | ATR: ", DoubleToString(g_atr, PriceDigits()), "\n",
           "Positions: ", CountOurPositions(), "/", DynamicPositionLimit(), " | Pendings: ", CountOurPendingOrders(),
           " | Lot now: ", DoubleToString(DynamicPositionLot(), 2),
           " | Equity guard: ", (g_hard_entry_halt ? "HARD HALT" : (g_entry_halt ? "COOLDOWN" : "ACTIVE")), "\n",
           "Pause until: ", (g_pause_until > TimeCurrent() ? TimeToString(g_pause_until, TIME_SECONDS) : "none"));
}

int OnInit()
{
   g_symbol = (InpTradeSymbol == "" ? _Symbol : InpTradeSymbol);
   if(!SymbolSelect(g_symbol, true))
   {
      Print("[XTRD_GH123] Cannot select symbol ", g_symbol);
      return INIT_FAILED;
   }
   if(g_symbol != _Symbol)
   {
      Print("[XTRD_GH123] Attach the EA to the same chart symbol selected in InpTradeSymbol. OnTick is driven by the chart symbol.");
      return INIT_FAILED;
   }

   if(InpAbsoluteMaxPositions < 1 || InpStartingMaxPositions < 1 ||
      InpStartingMaxPositions > InpAbsoluteMaxPositions || InpMaxPendingOrders < 1 ||
      InpInitialLot <= 0.0 || InpMaximumLotPerPosition < InpInitialLot ||
      InpLotIncrement <= 0.0 || InpBalanceStepForLotIncrease < 0.0 ||
      InpBalanceStepForExtraPosition < 0.0 || InpFastTickWindow < 2 ||
      InpSlowTickWindow < 2 || InpMinimumSignalScore < 0.0 || InpMinimumSignalScore > 100.0 ||
      InpSpreadEmaAlpha <= 0.0 || InpSpreadEmaAlpha > 1.0 ||
      InpMinimumDirectionalRatio < 0.5 || InpMinimumDirectionalRatio > 1.0 ||
      InpM1FastEMA < 1 || InpM1SlowEMA <= InpM1FastEMA ||
      InpM5FastEMA < 1 || InpM5SlowEMA <= InpM5FastEMA ||
      InpMaxLossPerPositionUSD <= 0.0 || InpInitialSLATRMultiplier <= 0.0 || InpTrailActivationATR < 0.0 ||
      InpMaxEquityDrawdownPercent < 0.0 || InpMaxEquityDrawdownPercent > 100.0 ||
      InpEquityGuardCooldownMinutes < 1 || InpHardEquityLossPercent < 0.0 || InpHardEquityLossPercent >= 100.0)
   {
      Print("[XTRD_GH123] Invalid input combination. Check limits, lots, balance steps and tick windows.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpRequireHedgingAccount && !IsHedgingAccount())
   {
      Print("[XTRD_GH123] Netting account detected. Independent stacked positions require a HEDGING account. Initialization stopped.");
      return INIT_FAILED;
   }

   long order_modes = SymbolInfoInteger(g_symbol, SYMBOL_ORDER_MODE);
   if((order_modes & SYMBOL_ORDER_STOP) != SYMBOL_ORDER_STOP)
   {
      Print("[XTRD_GH123] This symbol does not advertise STOP pending orders. BUY STOP / SELL STOP cannot be used.");
      return INIT_FAILED;
   }

   g_atr_handle = iATR(g_symbol, InpATRTimeframe, InpATRPeriod);
   if(g_atr_handle == INVALID_HANDLE)
   {
      Print("[XTRD_GH123] Failed to create ATR handle.");
      return INIT_FAILED;
   }

   if(InpUseM1ContextAsScore)
   {
      g_m1_fast_handle = iMA(g_symbol, PERIOD_M1, InpM1FastEMA, 0, MODE_EMA, PRICE_CLOSE);
      g_m1_slow_handle = iMA(g_symbol, PERIOD_M1, InpM1SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(g_m1_fast_handle == INVALID_HANDLE || g_m1_slow_handle == INVALID_HANDLE)
      {
         Print("[XTRD_GH123] Failed to create M1 EMA context handles.");
         return INIT_FAILED;
      }
   }
   if(InpUseM5ContextAsScore)
   {
      g_m5_fast_handle = iMA(g_symbol, PERIOD_M5, InpM5FastEMA, 0, MODE_EMA, PRICE_CLOSE);
      g_m5_slow_handle = iMA(g_symbol, PERIOD_M5, InpM5SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(g_m5_fast_handle == INVALID_HANDLE || g_m5_slow_handle == INVALID_HANDLE)
      {
         Print("[XTRD_GH123] Failed to create M5 EMA context handles.");
         return INIT_FAILED;
      }
   }

   g_initial_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_peak_equity = g_initial_equity;
   g_entry_halt_until = 0;
   g_entry_halt = false;
   g_hard_entry_halt = false;
   g_equity_state_key = EquityStateKey();
   LoadEquityGuardState();
   // Never allow a persisted high-water mark to move below current equity.
   if(AccountInfoDouble(ACCOUNT_EQUITY) > g_peak_equity)
      g_peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   SaveEquityGuardState();
   OpenResearchLog();
   EventSetTimer(1);

   Log(StringFormat("v1.24 initialized. balance=%.2f start_positions=%d absolute_max=%d initial_lot=%.2f max_lot=%.2f lot_step=%.2f lot_balance_step=%.2f position_balance_step=%.2f",
                    AccountInfoDouble(ACCOUNT_BALANCE), InpStartingMaxPositions, InpAbsoluteMaxPositions,
                    InpInitialLot, InpMaximumLotPerPosition, InpLotIncrement,
                    InpBalanceStepForLotIncrease, InpBalanceStepForExtraPosition));
   Log("Signal model: flexible fast ticks + speed/acceleration + last CLOSED M1/M5 candle strength + soft EMA context.");
   Log("Entry model: BUY STOP / SELL STOP bracket, OCO, continuation stacking; Strategy Tester auto-executes by default.");
   Log("Exit model: spread-aware cash-capped SL + open-ended adaptive trailing; no fixed TP.");
   Log(StringFormat("Equity protection: %.1f%% soft peak-DD cooldown for %d minutes; %.1f%% permanent floor from initial equity.",
                    InpMaxEquityDrawdownPercent, InpEquityGuardCooldownMinutes, InpHardEquityLossPercent));
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
   Log(StringFormat("TWO-LAYER SUMMARY emitted=%I64u admitted=%I64u rejected=%I64u [VOL=%I64u TREND=%I64u EXT=%I64u RATE=%I64u REGIME=%I64u QUALITY=%I64u DAYLOCK=%I64u] rollingWR=%.1f%% (%d)",
                    g_scout_emitted, g_scout_admitted, g_scout_rejected,
                    g_rej_vol, g_rej_trend, g_rej_ext, g_rej_rate, g_rej_regime, g_rej_quality, g_rej_daylock,
                    g_roll_wr, g_roll_n));
   CsvWrite("TWO_LAYER_SUMMARY", StringFormat("emitted=%I64u;admitted=%I64u;rejected=%I64u;vol=%I64u;trend=%I64u;ext=%I64u;rate=%I64u;regime=%I64u;quality=%I64u;daylock=%I64u;rolling_wr=%.1f;n=%d",
                                              g_scout_emitted, g_scout_admitted, g_scout_rejected,
                                              g_rej_vol, g_rej_trend, g_rej_ext, g_rej_rate, g_rej_regime, g_rej_quality, g_rej_daylock,
                                              g_roll_wr, g_roll_n));
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

void UpdateEquityDrawdownGuard()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_initial_equity <= 0.0)
      g_initial_equity = equity;

   // Monotonic high-water mark: it can rise, but it is never reset downward.
   if(equity > g_peak_equity)
      g_peak_equity = equity;

   // Permanent emergency floor remains anchored to the original baseline.
   if(!g_hard_entry_halt && InpHardEquityLossPercent > 0.0 && g_initial_equity > 0.0)
   {
      double hard_floor = g_initial_equity * (1.0 - InpHardEquityLossPercent / 100.0);
      if(equity <= hard_floor)
      {
         g_hard_entry_halt = true;
         g_entry_halt = true;
         g_entry_halt_until = 0;
         Log(StringFormat("EQUITY HARD GUARD: equity %.2f reached initial-equity floor %.2f (loss limit %.2f%%). Entries permanently halted; open positions remain managed.",
                          equity, hard_floor, InpHardEquityLossPercent));
         CsvWrite("EQUITY_HARD_HALT", StringFormat("initial_equity=%.2f;equity=%.2f;hard_floor=%.2f;loss_limit_pct=%.2f",
                                                    g_initial_equity, equity, hard_floor, InpHardEquityLossPercent));
         CancelAllOurPendings();
         SaveEquityGuardState();
         return;
      }
   }

   if(g_hard_entry_halt)
   {
      SaveEquityGuardState();
      return;
   }

   // Soft DD is always measured against the historical peak, never a local reset.
   double drawdown = 0.0;
   if(g_peak_equity > 0.0)
      drawdown = (g_peak_equity - equity) / g_peak_equity * 100.0;

   if(!g_entry_halt && InpMaxEquityDrawdownPercent > 0.0 &&
      drawdown >= InpMaxEquityDrawdownPercent)
   {
      g_entry_halt = true;
      g_entry_halt_until = TimeCurrent() + InpEquityGuardCooldownMinutes * 60;
      Log(StringFormat("EQUITY GUARD HALT: historical peak DD %.2f%% reached %.2f%%. Entries paused; cooldown is only a minimum wait, recovery is also required. Open positions remain managed.",
                       drawdown, InpMaxEquityDrawdownPercent));
      CsvWrite("EQUITY_GUARD_HALT", StringFormat("peak_equity=%.2f;equity=%.2f;drawdown_pct=%.2f;limit_pct=%.2f;cooldown_until=%s",
                                                  g_peak_equity, equity, drawdown, InpMaxEquityDrawdownPercent,
                                                  TimeToString(g_entry_halt_until, TIME_DATE|TIME_SECONDS)));
      CancelAllOurPendings();
      SaveEquityGuardState();
      return;
   }

   // Re-arm only after BOTH the minimum cooldown and a 50% recovery of the
   // allowed drawdown have occurred. Example: with a 30% guard, equity must
   // recover to at least 85% of the immutable peak before new entries resume.
   if(g_entry_halt &&
      (g_entry_halt_until == 0 || TimeCurrent() >= g_entry_halt_until) &&
      InpMaxEquityDrawdownPercent > 0.0)
   {
      double recovery_dd = InpMaxEquityDrawdownPercent * 0.5;
      double recovery_floor = g_peak_equity * (1.0 - recovery_dd / 100.0);
      if(equity >= recovery_floor)
      {
         g_entry_halt = false;
         g_entry_halt_until = 0;
         Log(StringFormat("EQUITY GUARD RE-ARMED after recovery: equity %.2f >= recovery threshold %.2f; historical peak remains %.2f.",
                          equity, recovery_floor, g_peak_equity));
         CsvWrite("EQUITY_GUARD_REARM", StringFormat("equity=%.2f;recovery_floor=%.2f;historical_peak=%.2f;initial_equity=%.2f",
                                                      equity, recovery_floor, g_peak_equity, g_initial_equity));
      }
      else
      {
         // Remain halted until recovery; do not reset the historical peak.
         // Clear the expired cooldown once, then keep checking recovery.
         if(g_entry_halt_until > 0)
         {
            g_entry_halt_until = 0;
            Log(StringFormat("EQUITY GUARD: cooldown elapsed, but equity %.2f is still below recovery threshold %.2f. Entries remain halted.",
                             equity, recovery_floor));
            CsvWrite("EQUITY_GUARD_RECOVERY_WAIT", StringFormat("equity=%.2f;recovery_floor=%.2f;historical_peak=%.2f",
                                                                  equity, recovery_floor, g_peak_equity));
         }
      }
   }

   SaveEquityGuardState();
}

void OnTick()
{
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick))
      return;

   UpdateEquityDrawdownGuard();
   ManageEquityDayLock();
   PushTick(tick);
   GetATR(g_atr);
   CalculateSignalMetrics();
   LogSignalIfChanged();

   // Exit and protection management is never blocked by the entry spread filter.
   ManageAdaptiveTrailing();
   ManageMomentumExit();
   ManageTimeStopAndBreakEven();
   CancelOppositePendings();

   if(g_tick_count >= MathMax(InpMinimumTicksForSignal, InpFastTickWindow + InpSlowTickWindow + 1) && g_atr > 0.0)
   {
      if(InpEnableScoutGate)
      {
         ScoutScan();
         Gatekeeper();
         if(!g_entry_halt)
            ExecuteAdmittedEntry();
      }
      else if(!g_entry_halt)
         EnsureEntryStructure();
   }

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
   {
      ProcessDeal(trans.deal, "TRADE_TRANSACTION");
      RecordDealOutcome(trans.deal);
   }
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
