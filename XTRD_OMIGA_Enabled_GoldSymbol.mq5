//+------------------------------------------------------------------+
//| XTRD_OMIGA.mq5                                        |
//|                                                                  |
//| OMEGA MICROSTRUCTURE ENGINE                                     |
//|                                                                  |
//| Architecture:                                                   |
//|  Fixed-memory tick engine                                       |
//|  Tick-step velocity / acceleration                              |
//|  Tick-intensity regime detection                                |
//|  Persistence + pressure proxy                                   |
//|  Micro-displacement reversion                                   |
//|  Velocity-burst momentum                                        |
//|  Exhaustion reversion                                           |
//|  Hybrid market/limit execution                                  |
//|  Async order dispatcher                                         |
//|  Adaptive spread/slippage/latency protection                    |
//|  Dynamic risk + constrained Kelly + empirical CVaR exposure control    |
//|  Concurrent thesis isolation                                    |
//|  Dynamic ATR exits + micro BE + velocity trailing               |
//|  Time invalidation                                               |
//|  Session router + rollover shield                               |
//|  Request telemetry + state reconciliation                       |
//|                                                                  |
//| IMPORTANT: This is a research/execution framework.              |
//| No mathematical model guarantees profit or 800 trades/day.      |
//| Validate with real-tick backtests and forward demo execution.    |
//+------------------------------------------------------------------+
#property strict
#property version   "2.31"
#property description "XTRD OMIGA - spread-aware gold microstructure engine (JustMarkets standard profile)"

#define OMEGA_TICK_CAPACITY       1024
#define OMEGA_REQ_CAPACITY        512
#define OMEGA_SAMPLE_CAPACITY     128
#define OMEGA_SIGNAL_CAPACITY     64
#define OMEGA_PENDING_CTRL_CAP     64
#define OMEGA_POS_CTRL_CAP         64
#define OMEGA_EVENT_CAP            128
#define OMEGA_MAGIC_RANGE         16
#define OMEGA_MS_PER_SEC           1000.0
#define OMEGA_EPS                  1e-12
#define OMEGA_STAT_CAP             512

// Signal rejection codes, so the loop can measure which gate blocks trading
// instead of guessing from a zero trade count.
#define REJ_SESSION                0
#define REJ_WARMUP                 1
#define REJ_ATR                    2
#define REJ_VOLFLOOR               3
#define REJ_INTENSITY              4
#define REJ_DISPLACEMENT           5
#define REJ_PERSISTENCE            6
#define REJ_ACCELERATION           7
#define REJ_REGIME                 8
#define REJ_PROBABILITY            9
#define REJ_EDGE                  10
#define REJ_SPREAD                11
#define REJ_NOT_CONNECTED         12
#define REJ_MQL_DISABLED          13
#define REJ_ACCT_DISABLED         14
#define REJ_ROLLOVER              15
#define REJ_DD_HARD               16
#define REJ_DAILY_DD              17
#define REJ_MAXPOS                18
#define REJ_SAMEDIR               19
#define REJ_LOTS_CAP              20
#define REJ_DELTA_CAP             21
#define REJ_MARGIN_CAP            22
#define REJ_PORTFOLIO_RISK        23
#define REJ_COOLDOWN              24
#define REJ_LOT_ZERO              25
#define REJ_SEND_CANNOT           26
#define REJ_SEND_MARGIN           27
#define REJ_SEND_STOPS            28
#define REJ_SEND_SLOT             29
#define REJ_SEND_VALIDATE         30
#define REJ_SEND_TOKEN            31
#define REJ_SEND_ORDER            32
#define REJ_COUNT                 33

//----------------------------- Enums -------------------------------//
enum ENUM_OMEGA_STRATEGY
{
   STRAT_MICRO_REVERSION = 1,
   STRAT_MOMENTUM        = 2,
   STRAT_EXHAUSTION      = 3
};

enum ENUM_OMEGA_REGIME
{
   REGIME_UNKNOWN   = 0,
   REGIME_RANGE     = 1,
   REGIME_MOMENTUM  = 2,
   REGIME_CHAOS     = 3,
   REGIME_QUIET     = 4,
   REGIME_EXHAUSTION= 5,
   REGIME_PULLBACK  = 6
};

enum ENUM_OMEGA_SESSION
{
   SESSION_OFF      = 0,
   SESSION_ASIA     = 1,
   SESSION_LONDON   = 2,
   SESSION_OVERLAP  = 3,
   SESSION_US_LATE  = 4,
   SESSION_ROLLOVER = 5
};

//----------------------------- Structures --------------------------//
struct TickNode
{
   double bid;
   double ask;
   double mid;
   double spread_pts;
   double volume;
   long   time_msc;
};

struct SignalInfo
{
   int      strategy;
   int      direction;
   int      regime;
   int      session;
   double   probability;
   double   edge_pts;
   double   sl_pts;
   double   tp_pts;
   double   confidence;
   double   displacement_pts;
   double   velocity;
   double   acceleration;
   double   pressure;
   double   intensity;
   double   persistence;
   double   spread_pts;
   ulong    signal_id;
   long     created_msc;
};

struct RequestTrack
{
   bool     active;
   ulong    request_id;
   ulong    local_id;
   long     sent_us;
   long     sent_msc;
   int      strategy;
   int      direction;
   ENUM_ORDER_TYPE order_type;
   double   requested_price;
   double   volume;
   double   sl;
   double   tp;
   ulong    order_ticket;
   ulong    position_ticket;
   ulong    signal_id;
};

struct DealSample
{
   double slippage_pts;
   double net_profit;
   double volume;
   long   latency_ms;
   int    direction;
   int    strategy;
   bool   win;
};

struct ThesisState
{
   ulong    last_signal_id;
   long     last_signal_msc;
   long     last_trade_msc;
   int      trades_open;
};

struct PendingControl
{
   bool   active;
   ulong  ticket;
   int    reprice_count;
   long   last_action_ms;
};

struct PositionControl
{
   bool   active;
   ulong  ticket;
   double last_sent_sl;
   double last_sent_tp;
   long   last_modify_ms;
   bool   close_pending;
   bool   partial_done;
   double mfe_pts;
   double mae_pts;
   long   entry_msc;
   double entry_price;
   double sl_pts;
   double tp_pts;
   double entry_spread_pts;
   int    strategy;
};

// Rolling distribution of a market metric. Absolute thresholds cannot be
// calibrated once for every broker/volatility regime, so the gates compare
// against the live percentile instead of a constant.
struct RollingStat
{
   double v[OMEGA_STAT_CAP];
   int    idx;
   int    cnt;
   double p50;
   double p60;
   double p70;
   double p85;
   double p90;
};

struct TelemetryEvent
{
   bool   active;
   string event_name;
   ulong  ticket;
   int    direction;
   double volume;
   double price;
   double slippage_pts;
   long   latency_ms;
   double profit;
   int    strategy;
};


//----------------------------- Inputs ------------------------------//
input group "NEWS FILTER / PROTECTION"
input bool   InpEnableNewsFilter           = true;
input int    InpNewsPreHaltMin             = 3;
input int    InpNewsPostResumeMin          = 2;

input group "CORE"
input ulong  InpBaseMagic                  = 1300001;
input bool   InpEnableTrading              = true;
input bool   InpOnlySymbol                 = true;
input string InpRequiredSymbol             = "XAUUSD";
input bool   InpAllowSuffixSymbols         = true;
input bool   InpAllowMultipleStrategies   = true;

input group "TICK ENGINE"
input int    InpFastTicks                  = 20;
input int    InpSignalTicks                = 50;
input int    InpContextTicks               = 100;
input int    InpMinTicksBeforeSignal       = 120;
input double InpMinEffectiveDtMs           = 0.10;
input double InpMaxVelocityPtsSec          = 500000.0;
input double InpMaxAccelerationPtsSec2     = 5000000.0;
input int    InpIntensityLookback          = 100;
input double InpIntensityBurst             = 3.0;
input double InpIntensityExtreme           = 5.0;
input int    InpPersistenceTicks           = 50;
input int    InpPressureTicks              = 50;
input double InpPressureDecayMs            = 250.0;
input double InpMicroPriceEpsilonPts       = 0.05;

input group "REGIME ENGINE"
input double InpMomentumVelocityMin       = 40.0;
input double InpMomentumAccelerationMin    = 2.0;
input double InpMomentumPersistenceMin     = 0.80;
input double InpChaosATRMultiple            = 3.50;
input double InpQuietIntensityMax           = 0.65;
input double InpRangePersistenceMax         = 0.60;

input group "ALPHA - MICRO DISPLACEMENT"
input bool   InpEnableMicroReversion       = true;
input double InpMicroIntensityMin          = 2.5;
input double InpMicroDeviationMinPts       = 90.0; // Must exceed ~3x the 25-35 pt standard spread
input double InpMicroPressureMax           = 12.0;
input double InpMicroProbabilityMin        = 0.56;

input group "ALPHA - VELOCITY BURST"
input bool   InpEnableMomentum             = true;
input double InpMomentumIntensityMin       = 2.0;
input double InpMomentumProbabilityMin     = 0.60;
input double InpMomentumMaxSpreadFactor    = 1.00;

input group "ALPHA - EXHAUSTION"
input bool   InpEnableExhaustion           = true;
input double InpExhaustionATRMultiple      = 2.50;
input double InpExhaustionVelocityRatio    = 0.25;
input double InpExhaustionPressureRatio    = 0.10;
input double InpExhaustionProbabilityMin   = 0.56;
input double InpExhaustionIntensityMin     = 2.0;

input group "BAYESIAN / CONDITIONAL GATES"
input double InpBayesPrior                 = 0.50;
input double InpBayesWeightVelocity        = 0.28;
input double InpBayesWeightAcceleration     = 0.18;
input double InpBayesWeightPressure        = 0.18;
input double InpBayesWeightPersistence     = 0.16;
input double InpBayesWeightIntensity       = 0.10;
input double InpBayesWeightDisplacement    = 0.10;
input double InpMinEdgePts                 = 25.0; // Expected capture (pts) that must be left after costs
input double InpEdgeToSpreadMin            = 1.15; // Edge must beat the round-trip cost by 15%

input group "SPREAD / EXECUTION"
input double InpMaxSpreadPts               = 45.0; // Hard spread ceiling for a 25-35 pt standard account
input double InpBaselineSpreadPts          = 25.0;
input double InpSpreadExpansionMaxPts      = 15.0; // Allowed expansion above baseline (rejects spread > baseline+15)
input double InpSpreadEdgeFraction         = 0.95;
input int    InpMaxRequestsPerSecond       = 5;
input double InpTokenRefillPerSecond      = 5.0;
input double InpMaxSlippagePts             = 15.0;
input double InpBadSlippagePts             = 12.0;
input int    InpExecutionLatencyMs         = 50;
input int    InpTelemetryWindow            = 16;
input bool   InpAdaptiveExecution           = true;
input int    InpMarketRetryMs              = 250;
input int    InpLimitExpirySec             = 5;
input int    InpMaxPendingOrders            = 8;
input int    InpLimitDistancePts            = 12;
input double InpLimitRepriceTriggerPts     = 3.0;
input int    InpMaxRepricesPerOrder        = 3;
input int    InpRepriceCooldownMs           = 250;
input int    InpPositionModifyCooldownMs    = 150;
input bool   InpUseOrderCheck              = true;
input bool   InpUseExecutionStateMachine   = true;

input group "RISK / COMPOUNDING"
input double InpInitialRiskPct             = 1.50;
input double InpMaxAccountRiskPct          = 3.00;
input double InpHardDrawdownPct            = 15.0;
input double InpDrawdownSoftZonePct        = 0.70;
input double InpMarginUtilizationMax       = 0.50;
input double InpFreeMarginFloorPct         = 30.0;
input double InpPortfolioRiskCapPct        = 6.0;
input double InpLotCap                     = 1.00;
input double InpMinLotOverride             = 0.01;
input double InpVolatilityReferenceATR     = 100.0;
input double InpVolatilityDragFloor        = 0.20;
input double InpVolatilityDragCeiling      = 1.00;
input bool   InpUseFractionalKellyBoost    = false;
input double InpKellyFraction              = 0.25;
input double InpKellyBoostCap              = 1.25;
input bool   InpEnableAdaptiveAggression   = true;
input double InpAggressionMin              = 0.35;
input double InpAggressionMax              = 1.25;
input double InpDailyLossLimitPct          = 5.0;
input int    InpStatsWarmupDeals           = 50;
input bool   InpUseEmpiricalCVaR            = true;
input double InpCVaRAlpha                   = 0.10;
input double InpCVaRSoftPct                = 4.0;
input double InpCVaRHardPct                = 8.0;

input group "PORTFOLIO / THESIS ISOLATION"
input int    InpMaxConcurrentPositions     = 4;
input int    InpMaxSameDirectionPositions  = 2;
input double InpMaxPortfolioLots           = 0.05;
input double InpMaxPortfolioDeltaLots      = 0.06;
input bool   InpAllowMomentumAndReversion  = true;
input bool   InpRejectDuplicatePending     = true;
input int    InpDuplicateWindowMs          = 150;
input int    InpStrategyCooldownMs         = 20;

input group "GATE CALIBRATION (percentile based)"
input double InpIntensityGateAbs           = 1.10; // Absolute floor for the tick-intensity gate
input double InpMinPersistenceFloor        = 0.55; // Floor for the persistence gate
input double InpMinAccelerationFloor       = 0.30; // Floor for the acceleration gate
input double InpMicroDisplacementATR       = 0.15; // Displacement gate floor in ATR units
input double InpRateEWMAAlpha              = 0.02; // Tick-rate baseline decay (1/s, ~50 s memory)

input group "STOPS / POSITION MANAGEMENT"
input ENUM_TIMEFRAMES InpATRTimeframe      = PERIOD_M5; // ATR/geometry timeframe (M1 ATR is smaller than the spread)
input double InpSL_ATR_Multiplier           = 0.55;
input double InpTP_ATR_Multiplier           = 1.10;
input double InpSLSpreadMultiple            = 6.0;  // SL floor = 6x live spread
input double InpTPSpreadMultiple            = 9.0;  // TP floor = 9x live spread
input double InpMinATRSpreadMultiple        = 3.0;  // Skip entries when ATR < 3x spread
input double InpMinSLPts                   = 150.0;
input double InpMaxSLPts                   = 900.0;
input double InpBEExtraPts                 = 2.0;
input bool   InpUseMicroBreakEven           = true;
input double InpBEStage1TriggerPts          = 60.0; // Stage 1 trigger floor (2.2x spread)
input double InpBEStage1LockPts             = 18.0; // Stage 1 lock floor (0.6x spread)
input double InpBEStage2TriggerPts          = 120.0; // Stage 2 trigger floor (4x spread)
input double InpBEStage2LockPts             = 55.0; // Stage 2 lock floor (1.8x spread)
input double InpBEStage1StopFraction        = 0.50; // Stage 1 trigger as a fraction of the stop
input double InpBEStage2StopFraction        = 0.75; // Stage 2 trigger as a fraction of the stop
input bool   InpUseSpreadMomentumGate       = true; // Rejects entries if spread is actively expanding
input double InpSpreadMomentumThresholdPts  = 3.0;
input bool   InpUseVelocityTrailing         = true;
input double InpTrailVelocityStrong         = 100.0;
input double InpTrailVelocityWeak           = 20.0;
input double InpTrailStrongATR              = 1.00;
input double InpTrailWeakATR                = 0.60;
input int    InpMaxTradeAgeSec              = 600;
input double InpStallVelocityPtsSec         = 3.0;
input double InpStallProfitFloorPts         = -30.0; // Only cut stalls that are worse than -1 spread
input bool   InpCloseStalledTrades          = true;
input bool   InpEnablePartialClose           = false;
input double InpPartialCloseTrigger          = 0.50;
input double InpPartialClosePercent          = 0.60;
input bool   InpEnableMFE_MAE                = true;

input group "SESSION ROUTER - GMT"
input bool   InpUseSessionEngine             = true;
input int    InpAsiaStartGMT                = 0;
input int    InpAsiaEndGMT                  = 7;
input int    InpLondonStartGMT              = 7;
input int    InpLondonEndGMT                = 12;
input int    InpOverlapStartGMT             = 12;
input int    InpOverlapEndGMT               = 16;
input int    InpUSLateStartGMT              = 16;
input int    InpUSLateEndGMT                = 21;
input int    InpRolloverStartHourGMT       = 21;
input int    InpRolloverStartMinuteGMT     = 55;
input int    InpRolloverEndHourGMT         = 22;
input int    InpRolloverEndMinuteGMT       = 15;
input bool   InpDisableSignalsOffSession    = false;
input bool   InpAsiaEnableMomentum          = false;
input bool   InpAsiaEnableReversion         = true;
input bool   InpAsiaEnableExhaustion        = true;
input bool   InpLondonEnableMomentum        = true;
input bool   InpLondonEnableReversion       = true;
input bool   InpLondonEnableExhaustion      = true;
input bool   InpOverlapEnableMomentum       = true;
input bool   InpOverlapEnableReversion      = true;
input bool   InpOverlapEnableExhaustion     = true;
input bool   InpLateEnableMomentum          = true;
input bool   InpLateEnableReversion         = true;
input bool   InpLateEnableExhaustion        = true;
input bool   InpCancelPendingRollover       = true;

input group "RESILIENCE / STATE"
input bool   InpReconcileOnInit             = true;
input bool   InpCloseUnknownPositions       = false;
input bool   InpRepairMissingStops          = true;
input bool   InpPersistState                = true;
input bool   InpPersistTelemetry            = true;
input string InpStateFile                   = "X13_Omega_State.csv";
input string InpTelemetryFile               = "X13_Omega_Telemetry.csv";
input string InpLedgerFile                  = "X13_Omega_Ledger.csv";
input int    InpStateSaveIntervalSec        = 30;
input int    InpTelemetryFlushIntervalMs    = 1000;
input bool   InpUseLiveTickRecovery         = true;
input bool   InpRequireHedgingAccount        = true;
input string InpCommentPrefix               = "XTRD";

//----------------------------- Globals -----------------------------//
TickNode g_ticks[OMEGA_TICK_CAPACITY];
RequestTrack g_requests[OMEGA_REQ_CAPACITY];
DealSample g_samples[OMEGA_SAMPLE_CAPACITY];
ThesisState g_thesis[4];

int g_head=-1;
int g_count=0;
int g_sample_count=0;
int g_sample_head=0;
int g_atr_handle=INVALID_HANDLE;

ulong g_signal_counter=0;
ulong g_local_request_counter=0;
long g_last_tick_msc=0;
long g_last_signal_msc[4]={0,0,0,0};
long g_last_strategy_trade_msc[4]={0,0,0,0};
long g_last_signal_fingerprint[4]={0,0,0,0};

// token bucket
 double g_tokens=0.0;
 long g_last_token_us=0;

// execution statistics
 double g_avg_spread_pts=0.0;
 double g_avg_slippage_pts=0.0;
 double g_avg_latency_ms=0.0;
 double g_total_wins=0.0;
 double g_total_losses=0.0;
 double g_total_profit=0.0;
 double g_total_loss=0.0;
 int g_total_deals=0;

// rolling market state
 double g_last_velocity=0.0;
 double g_last_velocity_context=0.0;
 double g_last_acceleration=0.0;
 double g_last_pressure=0.0;
 double g_last_intensity=0.0;
 double g_last_persistence=0.0;
 double g_last_displacement=0.0;
 double g_last_dir_persistence_buy=0.0;
 double g_last_dir_persistence_sell=0.0;
 double g_last_atr_pts=0.0;
 double g_last_spread_pts=0.0;
 double g_last_regime_score=0.0;
 int g_last_regime=REGIME_UNKNOWN;
RollingStat g_rs_intensity;
RollingStat g_rs_persist;
RollingStat g_rs_absvel;
RollingStat g_rs_absacc;
RollingStat g_rs_absdisp;
RollingStat g_rs_confidence;
long g_stats_last_msc=0;
long g_stats_pct_msc=0;
long g_rate_sec_msc=0;
int g_rate_sec_ticks=0;
double g_rate_current=0.0;
double g_rate_ewma=0.0;
double g_intensity_max=0.0;
double g_last_confidence=0.0;
double g_intensity_min=DBL_MAX;
long g_rej[REJ_COUNT];
int  g_gate_code=REJ_SESSION;
int  g_last_check_retcode=0;
int  g_check_log_count=0;
long g_check_advisory_override=0;
string g_rej_names[REJ_COUNT]=
{
   "session","warmup","atr","volfloor","intensity","displacement","persistence",
   "acceleration","regime","probability","edge","spread","not_connected",
   "mql_disabled","acct_disabled","rollover","dd_hard","daily_dd","maxpos",
   "samedir","lots_cap","delta_cap","margin_cap","portfolio_risk","cooldown",
   "lot_zero","send_cannot","send_margin","send_stops","send_slot",
   "send_validate","send_token","send_order"
};
 int g_last_session=SESSION_OFF;

 double g_peak_equity=0.0;
 bool g_execution_degraded=false;
 bool g_state_dirty=false;
 long g_last_state_save_ms=0;
 long g_last_telemetry_flush_ms=0;
 long g_last_processed_tick_msc=0;
 MqlTick g_last_processed_tick;
 bool g_have_last_processed_tick=false;
 PendingControl g_pending_ctrl[OMEGA_PENDING_CTRL_CAP];
 PositionControl g_pos_ctrl[OMEGA_POS_CTRL_CAP];
 TelemetryEvent g_event_queue[OMEGA_EVENT_CAP];
 int g_event_head=0;
 int g_event_count=0;
 long g_last_market_send_us=0;
long g_day_key=0;
double g_day_start_equity=0.0;

//----------------------------- Utilities ---------------------------//
double ClampD(const double x,const double lo,const double hi)
{
   return MathMax(lo,MathMin(hi,x));
}

int ClampI(const int x,const int lo,const int hi)
{
   return MathMax(lo,MathMin(hi,x));
}

double PointValue()
{
   return SymbolInfoDouble(_Symbol,SYMBOL_POINT);
}

double TickSize()
{
   return SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
}

double NormalizePrice(const double price)
{
   const double tick=TickSize();
   if(tick<=0.0) return NormalizeDouble(price,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
   return NormalizeDouble(MathRound(price/tick)*tick,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
}

double CurrentSpreadPts()
{
   MqlTick t;
   const double p=PointValue();
   if(!SymbolInfoTick(_Symbol,t) || p<=0.0) return DBL_MAX;
   return MathMax(0.0,(t.ask-t.bid)/p);
}

long NowMicroseconds()
{
   return (long)GetMicrosecondCount();
}

long NowMilliseconds()
{
   return (long)GetTickCount64();
}

string AccountScopedFile(const string base)
{
   const long login=(long)AccountInfoInteger(ACCOUNT_LOGIN);
   return IntegerToString(login)+"_"+base;
}

long DayKeyGMT()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(),dt);
   return (long)dt.year*10000L+(long)dt.mon*100L+(long)dt.day;
}

void RefreshDailyState()
{
   const long key=DayKeyGMT();
   if(g_day_key==key && g_day_start_equity>0.0) return;
   g_day_key=key;
   g_day_start_equity=AccountInfoDouble(ACCOUNT_EQUITY);
   g_state_dirty=true;
}

double DailyDrawdownPct()
{
   RefreshDailyState();
   const double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_day_start_equity<=0.0 || eq>=g_day_start_equity) return 0.0;
   return (g_day_start_equity-eq)/g_day_start_equity*100.0;
}

int GMT_Hour()
{
   MqlDateTime dt;
   datetime t = (MQLInfoInteger(MQL_TESTER) ? TimeCurrent() - 2 * 3600 : TimeGMT());
   TimeToStruct(t,dt);
   return dt.hour;
}

int GMT_MinuteOfDay()
{
   MqlDateTime dt;
   datetime t = (MQLInfoInteger(MQL_TESTER) ? TimeCurrent() - 2 * 3600 : TimeGMT());
   TimeToStruct(t,dt);
   return dt.hour*60+dt.min;
}

bool InHourRange(const int h,const int start_h,const int end_h)
{
   if(start_h==end_h) return true;
   if(start_h<end_h) return (h>=start_h && h<end_h);
   return (h>=start_h || h<end_h);
}

bool InMinuteRange(const int minute_of_day,const int start_min,const int end_min)
{
   if(start_min==end_min) return true;
   if(start_min<end_min) return (minute_of_day>=start_min && minute_of_day<end_min);
   return (minute_of_day>=start_min || minute_of_day<end_min);
}

bool InRolloverWindow()
{
   const int start=InpRolloverStartHourGMT*60+InpRolloverStartMinuteGMT;
   const int end=InpRolloverEndHourGMT*60+InpRolloverEndMinuteGMT;
   return InMinuteRange(GMT_MinuteOfDay(),start,end);
}

int CurrentSession()
{
   if(!InpUseSessionEngine) return SESSION_OVERLAP;
   const int h=GMT_Hour();
   if(InRolloverWindow()) return SESSION_ROLLOVER;
   if(InHourRange(h,InpAsiaStartGMT,InpAsiaEndGMT)) return SESSION_ASIA;
   if(InHourRange(h,InpLondonStartGMT,InpLondonEndGMT)) return SESSION_LONDON;
   if(InHourRange(h,InpOverlapStartGMT,InpOverlapEndGMT)) return SESSION_OVERLAP;
   if(InHourRange(h,InpUSLateStartGMT,InpUSLateEndGMT)) return SESSION_US_LATE;
   return SESSION_OFF;
}

bool IsRollover()
{
   return (CurrentSession()==SESSION_ROLLOVER);
}

bool SymbolAllowed()
{
   if(!InpOnlySymbol) return true;

   // Accept broker-specific XAUUSD symbols such as XAUUSD, XAUUSD.m,
   // XAUUSDm, and symbols with a broker prefix/suffix.
   string symbol_upper = _Symbol;
   StringToUpper(symbol_upper);

   // XAUUSD is the canonical instrument identifier. Matching the token
   // anywhere supports both prefixes and suffixes without changing the
   // actual chart symbol used for quotes and order requests.
   if(StringFind(symbol_upper, "XAUUSD", 0) >= 0) return true;

   // Retain the configured required-symbol match for custom broker names.
   string required_upper = InpRequiredSymbol;
   StringToUpper(required_upper);
   if(required_upper != "" && StringFind(symbol_upper, required_upper, 0) >= 0)
      return true;

   return false;
}

//----------------------------- Ring Buffer -------------------------//
void PushTick(const MqlTick &t)
{
   g_head=(g_head+1)%OMEGA_TICK_CAPACITY;
   const double p=PointValue();
   const double vol=(t.volume_real>0.0 ? t.volume_real : (t.volume>0 ? (double)t.volume : 1.0));
   g_ticks[g_head].bid=t.bid;
   g_ticks[g_head].ask=t.ask;
   g_ticks[g_head].mid=(t.bid+t.ask)*0.5;
   g_ticks[g_head].spread_pts=(p>0.0 ? (t.ask-t.bid)/p : 0.0);
   g_ticks[g_head].volume=MathMax(vol,1.0);
   g_ticks[g_head].time_msc=(long)t.time_msc;
   if(g_count<OMEGA_TICK_CAPACITY) g_count++;
   AccountTickRate((long)t.time_msc);
}

// Tick intensity is the current tick rate over a slow EWMA of it. Comparing a
// window against a baseline built from the same window has no variance at all
// (the ratio stays near 1.0), which silently disables every burst gate.
void AccountTickRate(const long now_msc)
{
   if(g_rate_sec_msc==0)
   {
      g_rate_sec_msc=now_msc;
      g_rate_sec_ticks=0;
      return;
   }
   const long elapsed=now_msc-g_rate_sec_msc;
   if(elapsed<1000)
   {
      g_rate_sec_ticks++;
      return;
   }
   const double rate=(double)g_rate_sec_ticks/((double)elapsed/OMEGA_MS_PER_SEC);
   g_rate_current=rate;
   g_rate_ewma=(g_rate_ewma<=0.0 ? rate : g_rate_ewma*(1.0-InpRateEWMAAlpha)+rate*InpRateEWMAAlpha);
   g_rate_sec_ticks=1;
   g_rate_sec_msc=now_msc;
}

bool GetBackTick(const int back,TickNode &out)
{
   if(back<0 || back>=g_count || g_head<0) return false;
   int idx=g_head-back;
   if(idx<0) idx+=OMEGA_TICK_CAPACITY*((-idx/OMEGA_TICK_CAPACITY)+1);
   idx%=OMEGA_TICK_CAPACITY;
   out=g_ticks[idx];
   return true;
}

double EffectiveDtMs(const long newer,const long older)
{
   const double raw=(double)(newer-older);
   return MathMax(InpMinEffectiveDtMs,raw);
}

double VelocityTicks(const int n)
{
   if(n<1 || g_count<=n) return 0.0;
   TickNode now,past;
   if(!GetBackTick(0,now) || !GetBackTick(n,past)) return 0.0;
   const double p=PointValue();
   if(p<=0.0) return 0.0;
   const double dt=EffectiveDtMs(now.time_msc,past.time_msc)/OMEGA_MS_PER_SEC;
   if(dt<=0.0) return 0.0;
   return ClampD(((now.mid-past.mid)/p)/dt,-InpMaxVelocityPtsSec,InpMaxVelocityPtsSec);
}

double AccelerationTicks(const int fast_n,const int context_n)
{
   if(fast_n<1 || context_n<1 || g_count<=fast_n+context_n) return 0.0;
   TickNode a,b,c;
   if(!GetBackTick(0,a) || !GetBackTick(fast_n,b) || !GetBackTick(fast_n+context_n,c)) return 0.0;
   const double p=PointValue();
   if(p<=0.0) return 0.0;
   const double dt1=EffectiveDtMs(a.time_msc,b.time_msc)/OMEGA_MS_PER_SEC;
   const double dt2=EffectiveDtMs(b.time_msc,c.time_msc)/OMEGA_MS_PER_SEC;
   if(dt1<=0.0 || dt2<=0.0) return 0.0;
   const double v1=((a.mid-b.mid)/p)/dt1;
   const double v2=((b.mid-c.mid)/p)/dt2;
   const double dt=MathMax(InpMinEffectiveDtMs/OMEGA_MS_PER_SEC,(dt1+dt2)*0.5);
   return ClampD((v1-v2)/dt,-InpMaxAccelerationPtsSec2,InpMaxAccelerationPtsSec2);
}

double TickIntensity()
{
   if(g_rate_ewma<=0.0 || g_rate_current<=0.0) return 0.0;
   return ClampD(g_rate_current/g_rate_ewma,0.0,50.0);
}

double Persistence(const int n)
{
   if(n<2 || g_count<=n) return 0.0;
   int up=0,down=0;
   TickNode a,b;
   for(int i=n-1;i>=0;i--)
   {
      if(!GetBackTick(i,a) || !GetBackTick(i+1,b)) continue;
      const double d=a.mid-b.mid;
      if(d>InpMicroPriceEpsilonPts*PointValue()) up++;
      else if(d<-InpMicroPriceEpsilonPts*PointValue()) down++;
   }
   const int total=up+down;
   if(total<=0) return 0.5;
   return (double)MathMax(up,down)/(double)total;
}

double DirectionalPersistence(const int n,const int direction)
{
   if(n<2 || g_count<=n) return 0.0;
   int favorable=0,total=0;
   TickNode a,b;
   for(int i=n-1;i>=0;i--)
   {
      if(!GetBackTick(i,a) || !GetBackTick(i+1,b)) continue;
      const double d=a.mid-b.mid;
      if(MathAbs(d)<=InpMicroPriceEpsilonPts*PointValue()) continue;
      total++;
      if((direction>0 && d>0.0) || (direction<0 && d<0.0)) favorable++;
   }
   return (total>0 ? (double)favorable/total : 0.0);
}

double PressureWeighted(const int n)
{
   if(n<2 || g_count<=n) return 0.0;
   const double p=PointValue();
   if(p<=0.0) return 0.0;
   TickNode newer,older;
   double numerator=0.0,denominator=0.0;
   long now_msc=0;
   if(!GetBackTick(0,newer)) return 0.0;
   now_msc=newer.time_msc;

   const double decay=MathMax(1.0,InpPressureDecayMs);
   for(int i=0;i<n;i++)
   {
      if(!GetBackTick(i,newer) || !GetBackTick(i+1,older)) continue;
      const double dp=(newer.mid-older.mid)/p;
      const double vol=MathMax(1.0,newer.volume);
      const double age=(double)MathMax((long)0,now_msc-newer.time_msc);
      const double w=MathExp(-age/decay);
      numerator+=w*dp*vol;
      denominator+=w*vol;
   }
   if(denominator<=0.0) return 0.0;
   return numerator/denominator;
}

double DisplacementPts(const int n)
{
   TickNode now,past;
   const double p=PointValue();
   if(n<1 || p<=0.0 || !GetBackTick(0,now) || !GetBackTick(n,past)) return 0.0;
   return (now.mid-past.mid)/p;
}

double SpreadMomentumPts(const int n)
{
   if(n<2 || g_count<=n) return 0.0;
   TickNode a,b;
   if(!GetBackTick(0,a) || !GetBackTick(n,b)) return 0.0;
   return a.spread_pts-b.spread_pts;
}

//----------------------------- ATR --------------------------------//
double ATRPoints()
{
   if(g_atr_handle==INVALID_HANDLE) return 0.0;
   double buf[1];
   if(CopyBuffer(g_atr_handle,0,0,1,buf)!=1) return 0.0;
   const double p=PointValue();
   if(p<=0.0) return 0.0;
   return MathMax(0.0,buf[0]/p);
}

//----------------------------- Regime ------------------------------//
int DetectRegime(const double velocity,const double acceleration,const double persistence,
                 const double intensity,const double atr,const double displacement)
{
   if(atr<=0.0) return REGIME_UNKNOWN;
   if(intensity<InpQuietIntensityMax) return REGIME_QUIET;
   if(MathAbs(displacement)>atr*InpChaosATRMultiple && intensity>InpIntensityExtreme)
      return REGIME_CHAOS;
   if(MathAbs(velocity)>=InpMomentumVelocityMin &&
      MathAbs(acceleration)>=InpMomentumAccelerationMin &&
      persistence>=InpMomentumPersistenceMin)
      return REGIME_MOMENTUM;
   if(MathAbs(displacement)>=atr*0.80 && MathAbs(velocity)<=MathMax(1.0,InpMomentumVelocityMin*0.40) && intensity>=1.5)
      return REGIME_EXHAUSTION;
   if(MathAbs(displacement)>=atr*0.30 && persistence>=0.60 && MathAbs(velocity)<InpMomentumVelocityMin)
      return REGIME_PULLBACK;
   if(persistence<=InpRangePersistenceMax) return REGIME_RANGE;
   return REGIME_RANGE;
}

//----------------------------- Conditional Alpha ------------------//
double Logistic(const double x)
{
   const double z=ClampD(x,-30.0,30.0);
   return 1.0/(1.0+MathExp(-z));
}

double NormalizeFeature(const double x,const double scale)
{
   if(scale<=0.0) return 0.0;
   return ClampD(x/scale,-3.0,3.0);
}

double ConditionalScore(const int direction,
                        const double velocity,
                        const double acceleration,
                        const double pressure,
                        const double directional_persistence,
                        const double intensity,
                        const double displacement,
                        const double atr)
{
   const double sign=(direction>0 ? 1.0 : -1.0);
   const double fV=NormalizeFeature(sign*velocity,MathMax(1.0,InpMomentumVelocityMin));
   const double fA=NormalizeFeature(sign*acceleration,MathMax(1.0,InpMomentumAccelerationMin*10.0));
   const double fP=NormalizeFeature(sign*pressure,MathMax(1.0,atr*0.20));
   const double fPers=directional_persistence;
   const double fI=NormalizeFeature(intensity-1.0,2.0);
   const double fD=NormalizeFeature(sign*displacement,MathMax(1.0,atr));

   // Conditional product gate: every feature contributes, but none can
   // independently force an entry. Prior is kept explicit for calibration.
   double z=MathLog(ClampD(InpBayesPrior,0.01,0.99)/(1.0-ClampD(InpBayesPrior,0.01,0.99)));
   z += InpBayesWeightVelocity*fV;
   z += InpBayesWeightAcceleration*fA;
   z += InpBayesWeightPressure*fP;
   z += InpBayesWeightPersistence*((fPers-0.5)*2.0);
   z += InpBayesWeightIntensity*fI;
   z += InpBayesWeightDisplacement*fD;
   return Logistic(z);
}

bool SessionAllowsStrategy(const int strategy,const int session)
{
   if(!InpUseSessionEngine) return true;
   if(session==SESSION_ROLLOVER) return false;
   if(session==SESSION_OFF) return !InpDisableSignalsOffSession;
   if(session==SESSION_ASIA)
   {
      if(strategy==STRAT_MOMENTUM) return InpAsiaEnableMomentum;
      if(strategy==STRAT_MICRO_REVERSION) return InpAsiaEnableReversion;
      return InpAsiaEnableExhaustion;
   }
   if(session==SESSION_LONDON)
   {
      if(strategy==STRAT_MOMENTUM) return InpLondonEnableMomentum;
      if(strategy==STRAT_MICRO_REVERSION) return InpLondonEnableReversion;
      return InpLondonEnableExhaustion;
   }
   if(session==SESSION_OVERLAP)
   {
      if(strategy==STRAT_MOMENTUM) return InpOverlapEnableMomentum;
      if(strategy==STRAT_MICRO_REVERSION) return InpOverlapEnableReversion;
      return InpOverlapEnableExhaustion;
   }
   if(session==SESSION_US_LATE)
   {
      if(strategy==STRAT_MOMENTUM) return InpLateEnableMomentum;
      if(strategy==STRAT_MICRO_REVERSION) return InpLateEnableReversion;
      return InpLateEnableExhaustion;
   }
   return false;
}

bool SpreadGate(const double edge_pts,const double spread_pts)
{
   if(spread_pts==DBL_MAX || spread_pts<=0.0) return false;
   if(spread_pts>InpMaxSpreadPts) return false;
   // Spread-Expansion Shield: the cap is relative to the account baseline, so a
   // 25-35 pt standard account is not blocked by a fixed absolute threshold.
   if(spread_pts>InpBaselineSpreadPts+InpSpreadExpansionMaxPts) return false;
   // Spread-Momentum Gate: reject entry if spread is actively widening
   if(InpUseSpreadMomentumGate && SpreadMomentumPts(5)>InpSpreadMomentumThresholdPts) return false;
   if(edge_pts<=0.0) return false;
   // On a 25-35 pt standard spread the expected capture must clearly dominate cost.
   if(edge_pts<spread_pts*InpEdgeToSpreadMin) return false;
   return true;
}


//----------------------------- Rolling Distribution -------------//
void RS_Reset(RollingStat &s)
{
   s.idx=0;
   s.cnt=0;
   s.p50=0.0; s.p60=0.0; s.p70=0.0; s.p85=0.0; s.p90=0.0;
   ArrayInitialize(s.v,0.0);
}

void RS_Push(RollingStat &s,const double x)
{
   if(!MathIsValidNumber(x)) return;
   s.v[s.idx]=x;
   s.idx=(s.idx+1)%OMEGA_STAT_CAP;
   if(s.cnt<OMEGA_STAT_CAP) s.cnt++;
}

double RS_Quantile(const RollingStat &s,const double q)
{
   if(s.cnt<=0) return 0.0;
   double tmp[];
   ArrayResize(tmp,s.cnt);
   for(int i=0;i<s.cnt;i++) tmp[i]=s.v[i];
   ArraySort(tmp);
   const int idx=ClampI((int)MathFloor(q*(s.cnt-1)+0.5),0,s.cnt-1);
   return tmp[idx];
}

void RS_UpdatePercentiles(RollingStat &s)
{
   if(s.cnt<=0) return;
   // One sort feeds all five quantiles.
   double tmp[];
   ArrayResize(tmp,s.cnt);
   for(int i=0;i<s.cnt;i++) tmp[i]=s.v[i];
   ArraySort(tmp);
   const int last=s.cnt-1;
   s.p50=tmp[ClampI((int)MathFloor(0.50*last+0.5),0,last)];
   s.p60=tmp[ClampI((int)MathFloor(0.60*last+0.5),0,last)];
   s.p70=tmp[ClampI((int)MathFloor(0.70*last+0.5),0,last)];
   s.p85=tmp[ClampI((int)MathFloor(0.85*last+0.5),0,last)];
   s.p90=tmp[ClampI((int)MathFloor(0.90*last+0.5),0,last)];
}

void SampleMarketStats(const long now_msc)
{
   if(now_msc-g_stats_last_msc<1000) return;
   g_stats_last_msc=now_msc;
   if(g_last_confidence>0.0) RS_Push(g_rs_confidence,g_last_confidence);
   g_intensity_max=MathMax(g_intensity_max,g_last_intensity);
   if(g_last_intensity>0.0) g_intensity_min=MathMin(g_intensity_min,g_last_intensity);
   RS_Push(g_rs_intensity,g_last_intensity);
   RS_Push(g_rs_persist,g_last_persistence);
   RS_Push(g_rs_absvel,MathAbs(g_last_velocity));
   RS_Push(g_rs_absacc,MathAbs(g_last_acceleration));
   RS_Push(g_rs_absdisp,MathAbs(g_last_displacement));
   // Sorting 5 windows every second dominates the tester runtime on a
   // 45 day real-tick run, and a minute of staleness is irrelevant to the
   // gates, so the quantiles are refreshed on a slower clock.
   if(now_msc-g_stats_pct_msc<60000) return;
   g_stats_pct_msc=now_msc;
   RS_UpdatePercentiles(g_rs_intensity);
   RS_UpdatePercentiles(g_rs_persist);
   RS_UpdatePercentiles(g_rs_absvel);
   RS_UpdatePercentiles(g_rs_absacc);
   RS_UpdatePercentiles(g_rs_absdisp);
   RS_UpdatePercentiles(g_rs_confidence);
}

// Percentile gates fall back to the absolute inputs until the sample is deep
// enough to describe the instrument.
bool StatsReady(const RollingStat &s) { return s.cnt>=60; }

double GateIntensity()
{
   const double abs_gate=MathMax(1.0,InpIntensityGateAbs);
   if(!StatsReady(g_rs_intensity)) return abs_gate;
   return MathMax(abs_gate,g_rs_intensity.p60);
}

double GatePersistence()
{
   if(!StatsReady(g_rs_persist)) return InpMomentumPersistenceMin;
   return MathMax(InpMinPersistenceFloor,g_rs_persist.p70);
}

double GateAcceleration()
{
   if(!StatsReady(g_rs_absacc)) return InpMomentumAccelerationMin;
   return MathMax(InpMinAccelerationFloor,g_rs_absacc.p50);
}

double GateDisplacement(const double atr)
{
   double gate=MathMax(InpMicroDeviationMinPts,atr*InpMicroDisplacementATR);
   if(StatsReady(g_rs_absdisp)) gate=MathMax(gate,g_rs_absdisp.p60);
   return gate;
}

// Every gate reports why it blocked, so the next iteration is data driven.
bool RejectSignal(const int code)
{
   if(code>=0 && code<REJ_COUNT) g_rej[code]++;
   return false;
}

//----------------------------- Signal Builder ---------------------//
// Trade geometry is expressed in multiples of the *live* spread, because on a
// standard 25-35 pt gold account the spread is the dominant cost term: a target
// of 45 pts against a 30 pt spread needs an ~80% hit rate to break even.
double GeometrySpreadPts(const double live_spread)
{
   if(live_spread==DBL_MAX || live_spread<=0.0) return MathMax(1.0,InpBaselineSpreadPts);
   return MathMax(live_spread,MathMax(1.0,InpBaselineSpreadPts*0.8));
}

// The smallest tradable volume must stay inside the account risk cap. On a
// 100 USD account a 356 pt stop at 0.01 lot risks 3.56%, above the 3% cap, so
// the stop is clipped to what the account can actually carry.
double MaxAffordableStopPts()
{
   const double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   const double per_point=LossPerLot(1.0);
   const double minv=MathMax(InpMinLotOverride,MathMax(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),0.01));
   if(equity<=0.0 || per_point<=0.0 || minv<=0.0) return InpMaxSLPts;
   const double cap=equity*InpMaxAccountRiskPct/100.0;
   return MathMax(InpMinSLPts,cap/(per_point*minv));
}

double StopLossPts(const double atr,const double spread)
{
   const double s=GeometrySpreadPts(spread);
   const double raw=ClampD(MathMax(atr*InpSL_ATR_Multiplier,s*InpSLSpreadMultiple),InpMinSLPts,InpMaxSLPts);
   return MathMin(raw,MaxAffordableStopPts());
}

double TakeProfitPts(const double atr,const double sl_pts,const double spread)
{
   const double s=GeometrySpreadPts(spread);
   const double tp=MathMax(atr*InpTP_ATR_Multiplier,s*InpTPSpreadMultiple);
   return ClampD(MathMax(tp,sl_pts*1.25),InpMinSLPts,InpMaxSLPts*2.0);
}

// The fixed confidence floors were calibrated on a different probability
// model: in iteration 5 about 1.3M signals reached this gate and almost none
// cleared 0.56, which capped the whole system at 5 trades in 45 days. The
// floor now tracks the instrument's own confidence distribution, keeping the
// absolute value as a hard minimum.
double ProbabilityFloor(const double abs_floor)
{
   if(!StatsReady(g_rs_confidence)) return 0.42;
   // Deliberately allowed to fall below the legacy constant: on this
   // instrument the model's own confidence tops out near 0.55, so a fixed
   // 0.56 floor would be an unreachable wall rather than a filter.
   return ClampD(g_rs_confidence.p60,0.42,0.95);
}

bool BuildSignal(const int strategy,SignalInfo &s)
{
   ZeroMemory(s);
   const int session=CurrentSession();
   if(!SessionAllowsStrategy(strategy,session)) return RejectSignal(REJ_SESSION);
   if(g_count<InpMinTicksBeforeSignal) return RejectSignal(REJ_WARMUP);

   const double atr=ATRPoints();
   const double spread=CurrentSpreadPts();
   if(atr<=0.0 || spread==DBL_MAX) return RejectSignal(REJ_ATR);

   // Volatility floor: in a dead market the target cannot clear the spread.
   if(atr<GeometrySpreadPts(spread)*InpMinATRSpreadMultiple) return RejectSignal(REJ_VOLFLOOR);

   const double v=g_last_velocity;
   const double vc=g_last_velocity_context;
   const double a=g_last_acceleration;

   // Institutional Flash-Crash Chaos Shield: halt new entries during unphysical velocity spikes
   if(MathAbs(v)>500.0) return RejectSignal(REJ_ACCELERATION);
   const double pr=g_last_pressure;
   const double pers=g_last_persistence;
   const double intensity=g_last_intensity;
   const double disp=g_last_displacement;
   const int regime=g_last_regime;

   // Gates compare against the live distribution of this instrument, not against
   // constants calibrated for another broker's tick stream.
   const double inten_gate=GateIntensity();
   const double pers_gate=GatePersistence();
   const double acc_gate=GateAcceleration();
   const double disp_gate=GateDisplacement(atr);

   double pbuy=ConditionalScore(1,v,a,pr,g_last_dir_persistence_buy,intensity,disp,atr);
   double psell=ConditionalScore(-1,v,a,pr,g_last_dir_persistence_sell,intensity,disp,atr);

   s.strategy=strategy;
   s.session=session;
   s.regime=regime;
   s.created_msc=NowMilliseconds();
   s.signal_id=++g_signal_counter;
   s.velocity=v;
   s.acceleration=a;
   s.pressure=pr;
   s.intensity=intensity;
   s.persistence=pers;
   s.displacement_pts=disp;
   s.spread_pts=spread;
   s.sl_pts=StopLossPts(atr,spread);
   s.tp_pts=TakeProfitPts(atr,s.sl_pts,spread);

   double probability=0.0;

   // 1) Micro displacement reversion
   if(strategy==STRAT_MICRO_REVERSION && InpEnableMicroReversion)
   {
      if(intensity<inten_gate) return RejectSignal(REJ_INTENSITY);
      if(MathAbs(disp)<disp_gate) return RejectSignal(REJ_DISPLACEMENT);
      // Reversion only pays when the spread is at or below its own baseline.
      if(spread>InpBaselineSpreadPts*1.20) return RejectSignal(REJ_SPREAD);
      if(MathAbs(pr)>InpMicroPressureMax) return RejectSignal(REJ_DISPLACEMENT);

      const double pfloor=ProbabilityFloor(InpMicroProbabilityMin);
      if(disp>0.0 && psell>=pfloor)
      {
         s.direction=-1;
         probability=psell;
      }
      else if(disp<0.0 && pbuy>=pfloor)
      {
         s.direction=1;
         probability=pbuy;
      }
      else return RejectSignal(REJ_PROBABILITY);

      // Do not fade a move that is still accelerating.
      if(MathAbs(v)>MathMax(InpMomentumVelocityMin,atr*1.5) && MathAbs(a)>acc_gate)
         return RejectSignal(REJ_ACCELERATION);
   }
   // 2) Momentum continuation
   else if(strategy==STRAT_MOMENTUM && InpEnableMomentum)
   {
      if(intensity<inten_gate) return RejectSignal(REJ_INTENSITY);
      if(pers<pers_gate) return RejectSignal(REJ_PERSISTENCE);
      if(MathAbs(a)<acc_gate) return RejectSignal(REJ_ACCELERATION);
      if(regime==REGIME_QUIET) return RejectSignal(REJ_REGIME);

      const double pfloor=ProbabilityFloor(InpMomentumProbabilityMin);
      if(v>0.0 && pbuy>=pfloor)
      {
         s.direction=1;
         probability=pbuy;
      }
      else if(v<0.0 && psell>=pfloor)
      {
         s.direction=-1;
         probability=psell;
      }
      else return RejectSignal(REJ_PROBABILITY);

      // Context velocity must not violently oppose the fast stream.
      if(s.direction>0 && vc< -MathMax(1.0,InpMomentumVelocityMin*0.50)) return RejectSignal(REJ_ACCELERATION);
      if(s.direction<0 && vc>  MathMax(1.0,InpMomentumVelocityMin*0.50)) return RejectSignal(REJ_ACCELERATION);
   }
   // 3) Exhaustion reversion
   else if(strategy==STRAT_EXHAUSTION && InpEnableExhaustion)
   {
      if(intensity<inten_gate) return RejectSignal(REJ_INTENSITY);
      if(MathAbs(disp)<MathMax(atr*InpExhaustionATRMultiple,disp_gate)) return RejectSignal(REJ_DISPLACEMENT);
      if(MathAbs(v)>MathMax(1.0,atr)*InpExhaustionVelocityRatio) return RejectSignal(REJ_PERSISTENCE);
      if(MathAbs(pr)>MathMax(1.0,atr)*InpExhaustionPressureRatio) return RejectSignal(REJ_DISPLACEMENT);

      const double pfloor=ProbabilityFloor(InpExhaustionProbabilityMin);
      if(disp>0.0 && psell>=pfloor)
      {
         s.direction=-1;
         probability=psell;
      }
      else if(disp<0.0 && pbuy>=pfloor)
      {
         s.direction=1;
         probability=pbuy;
      }
      else return RejectSignal(REJ_PROBABILITY);
   }
   else return RejectSignal(REJ_REGIME);

   // Edge is the probability-weighted share of the *actual* target, in points.
   s.probability=probability;
   g_last_confidence=probability;
   const double edge=(probability-0.5)*2.0*s.tp_pts;
   if(edge<InpMinEdgePts) return RejectSignal(REJ_EDGE);
   if(!SpreadGate(edge,spread)) return RejectSignal(REJ_SPREAD);

   s.edge_pts=edge;
   s.confidence=ClampD((s.probability-0.5)*2.0,0.0,1.0);
   return true;
}

//----------------------------- Drawdown / Risk --------------------//
double CurrentDrawdownPct()
{
   const double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity<=0.0) return 100.0;
   if(g_peak_equity<=0.0) g_peak_equity=equity;
   if(equity>g_peak_equity) g_peak_equity=equity;
   return MathMax(0.0,(g_peak_equity-equity)/g_peak_equity*100.0);
}

double DrawdownMultiplier()
{
   if(InpHardDrawdownPct<=0.0) return 0.0;
   const double dd=CurrentDrawdownPct();
   if(dd>=InpHardDrawdownPct) return 0.0;
   return ClampD(1.0-dd/InpHardDrawdownPct,0.0,1.0);
}

double MarginUtilization()
{
   const double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   const double margin=AccountInfoDouble(ACCOUNT_MARGIN);
   if(equity<=0.0) return 1.0;
   return MathMax(0.0,margin/equity);
}

double VolatilityDrag()
{
   const double atr=ATRPoints();
   if(atr<=0.0) return InpVolatilityDragFloor;
   return ClampD(InpVolatilityReferenceATR/atr,InpVolatilityDragFloor,InpVolatilityDragCeiling);
}

double ExecutionCostFactor()
{
   const double spread=CurrentSpreadPts();
   if(spread==DBL_MAX || spread<=0.0) return 0.0;
   const double baseline=MathMax(1.0,InpBaselineSpreadPts);
   const double f=baseline/spread;
   if(g_execution_degraded) return ClampD(f*0.75,0.10,1.0);
   return ClampD(f,0.10,1.00);
}

double AdaptiveAggressionFactor(const SignalInfo &s)
{
   if(!InpEnableAdaptiveAggression) return 1.0;
   double f=1.0;
   const double dd=CurrentDrawdownPct();
   const double daily=DailyDrawdownPct();
   f*=ClampD(1.0-dd/MathMax(1.0,InpHardDrawdownPct),0.25,1.0);
   if(InpDailyLossLimitPct>0.0) f*=ClampD(1.0-daily/InpDailyLossLimitPct,0.20,1.0);
   f*=ClampD(s.confidence,0.40,1.0);
   if(g_execution_degraded) f*=0.65;
   if(g_last_regime==REGIME_MOMENTUM && s.strategy==STRAT_MOMENTUM) f*=1.10;
   if(g_last_regime==REGIME_EXHAUSTION && s.strategy==STRAT_EXHAUSTION) f*=1.08;
   if(g_last_regime==REGIME_CHAOS) f*=0.75;
   return ClampD(f,InpAggressionMin,InpAggressionMax);
}

double EmpiricalKellyBoost()
{
   if(!InpUseFractionalKellyBoost || g_total_deals<InpStatsWarmupDeals) return 1.0;
   const double wins=MathMax(1.0,g_total_wins);
   const double losses=MathMax(1.0,g_total_losses);
   const double p=wins/(wins+losses);
   const double avgwin=wins>0.0 ? g_total_profit/wins : 0.0;
   const double avgloss=losses>0.0 ? MathAbs(g_total_loss/losses) : 0.0;
   if(avgwin<=0.0 || avgloss<=0.0) return 1.0;
   const double b=avgwin/avgloss;
   const double k=MathMax(0.0,(p-(1.0-p)/b));
   return ClampD(1.0+k*InpKellyFraction,1.0,InpKellyBoostCap);
}

double NormalizeVolume(double volume)
{
   const double broker_min=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   const double broker_max=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   const double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   const double minv=MathMax(InpMinLotOverride,broker_min>0.0?broker_min:0.01);
   const double maxv=MathMin(InpLotCap,broker_max>0.0?broker_max:InpLotCap);
   const double vol_step=(step>0.0?step:minv);
   if(volume<minv-OMEGA_EPS) return 0.0;
   volume=MathMin(volume,maxv);
   const double steps=MathFloor((volume-minv+1e-10)/vol_step);
   volume=minv+MathMax(0.0,steps)*vol_step;
   int digits=2;
   if(vol_step<0.01) digits=4;
   else if(vol_step<0.1) digits=3;
   volume=NormalizeDouble(volume,digits);
   if(volume<minv-OMEGA_EPS) return 0.0;
   return MathMin(volume,maxv);
}

double LossPerLotForType(const ENUM_ORDER_TYPE type,const double sl_pts,const double entry_price)
{
   const double point=PointValue();
   if(point<=0.0 || sl_pts<=0.0 || entry_price<=0.0) return 0.0;
   const double sl=(type==ORDER_TYPE_BUY ? entry_price-sl_pts*point : entry_price+sl_pts*point);
   double profit=0.0;
   if(!OrderCalcProfit(type,_Symbol,1.0,entry_price,NormalizePrice(sl),profit)) return 0.0;
   return MathAbs(profit);
}

double LossPerLot(const double sl_pts)
{
   MqlTick t;
   if(!SymbolInfoTick(_Symbol,t)) return 0.0;
   const double buy=LossPerLotForType(ORDER_TYPE_BUY,sl_pts,t.ask);
   const double sell=LossPerLotForType(ORDER_TYPE_SELL,sl_pts,t.bid);
   if(buy<=0.0) return sell;
   if(sell<=0.0) return buy;
   return MathMax(buy,sell);
}

double PositionRiskMoney(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return 0.0;
   const double sl=PositionGetDouble(POSITION_SL);
   if(sl<=0.0) return 0.0;
   const double open=PositionGetDouble(POSITION_PRICE_OPEN);
   const double vol=PositionGetDouble(POSITION_VOLUME);
   const long type=PositionGetInteger(POSITION_TYPE);
   const ENUM_ORDER_TYPE ot=(type==POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double profit=0.0;
   if(!OrderCalcProfit(ot,_Symbol,vol,open,sl,profit)) return 0.0;
   return MathAbs(profit);
}

double OpenRiskMoney()
{
   double risk=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      const ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      const long magic=PositionGetInteger(POSITION_MAGIC);
      if(magic<(long)InpBaseMagic || magic>(long)InpBaseMagic+OMEGA_MAGIC_RANGE) continue;
      risk+=PositionRiskMoney(ticket);
   }
   return MathMax(0.0,risk);
}

double PendingRiskMoney()
{
   double risk=0.0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      const ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      const long magic=OrderGetInteger(ORDER_MAGIC);
      if(magic<(long)InpBaseMagic || magic>(long)InpBaseMagic+OMEGA_MAGIC_RANGE) continue;
      const ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      const double price=OrderGetDouble(ORDER_PRICE_OPEN);
      const double sl=OrderGetDouble(ORDER_SL);
      const double vol=OrderGetDouble(ORDER_VOLUME_CURRENT);
      if(sl<=0.0 || price<=0.0 || vol<=0.0) continue;
      double profit=0.0;
      const ENUM_ORDER_TYPE ot=(type==ORDER_TYPE_BUY_LIMIT || type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_BUY_STOP_LIMIT ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      if(OrderCalcProfit(ot,_Symbol,vol,price,sl,profit)) risk+=MathAbs(profit);
   }
   return MathMax(0.0,risk);
}

double EmpiricalCVaRFrac()
{
   if(!InpUseEmpiricalCVaR || g_sample_count<MathMax(20,InpStatsWarmupDeals)) return 0.0;
   double losses[OMEGA_SAMPLE_CAPACITY];
   int n=0;
   for(int i=0;i<g_sample_count;i++)
   {
      if(g_samples[i].net_profit<0.0) losses[n++]=g_samples[i].net_profit;
   }
   if(n<5) return 0.0;
   ArraySort(losses);
   const int tail=MathMax(1,(int)MathCeil(n*ClampD(InpCVaRAlpha,0.01,0.50)));
   double sum=0.0;
   for(int i=0;i<tail;i++) sum+=MathAbs(losses[i]);
   const double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   return (eq>0.0 ? (sum/tail)/eq*100.0 : 0.0);
}

double CVaRMultiplier()
{
   const double c=EmpiricalCVaRFrac();
   if(c<=0.0 || InpCVaRSoftPct<=0.0) return 1.0;
   if(c>=InpCVaRHardPct) return 0.35;
   if(c<=InpCVaRSoftPct) return 1.0;
   return ClampD(1.0-(c-InpCVaRSoftPct)/MathMax(0.01,InpCVaRHardPct-InpCVaRSoftPct)*0.65,0.35,1.0);
}

double RiskLot(const SignalInfo &s)
{
   const double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   const double free_margin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return 0.0;
   const double entry=(s.direction>0 ? tick.ask : tick.bid);
   const ENUM_ORDER_TYPE ot=(s.direction>0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   const double loss_lot=LossPerLotForType(ot,s.sl_pts,entry);
   if(equity<=0.0 || free_margin<=0.0 || loss_lot<=0.0) return 0.0;

   double risk_pct=MathMin(InpInitialRiskPct,InpMaxAccountRiskPct);
   const double ddm=DrawdownMultiplier();
   const double quality=ClampD(s.confidence,0.20,1.0);
   risk_pct*=ddm;
   risk_pct*=quality;
   risk_pct*=ClampD(ExecutionCostFactor(),0.10,1.0);
   risk_pct*=VolatilityDrag();
   risk_pct*=AdaptiveAggressionFactor(s);
   risk_pct*=CVaRMultiplier();
   risk_pct*=EmpiricalKellyBoost();

   // Convert account risk budget to a volume. Portfolio risk is checked again
   // after this calculation, so this is only the local thesis budget.
   const double cash=equity*risk_pct/100.0;
   double lot=cash/loss_lot;
   // Small-account floor: with a 180 pt stop the 0.01 minimum lot risks ~1.8% of a
   // 100 USD account. Take the floor only while it stays inside the risk cap,
   // otherwise the EA would silently never trade a small account.
   const double minv=MathMax(InpMinLotOverride,MathMax(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),0.01));
   if(lot<minv && free_margin>=1.0)
   {
      const double floor_risk=loss_lot*minv/MathMax(equity,OMEGA_EPS)*100.0;
      if(floor_risk<=MathMax(InpMaxAccountRiskPct,InpInitialRiskPct*2.0)) lot=minv;
   }
   return NormalizeVolume(lot);
}

//----------------------------- Portfolio ---------------------------//
int CountOurPositions()
{
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      const ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      const long magic=PositionGetInteger(POSITION_MAGIC);
      if(magic>=(long)InpBaseMagic && magic<=(long)InpBaseMagic+OMEGA_MAGIC_RANGE) count++;
   }
   return count;
}

int CountOurPositionsDirection(const int direction)
{
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      const ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      const long magic=PositionGetInteger(POSITION_MAGIC);
      if(magic<(long)InpBaseMagic || magic>(long)InpBaseMagic+OMEGA_MAGIC_RANGE) continue;
      const long type=PositionGetInteger(POSITION_TYPE);
      if((direction>0 && type==POSITION_TYPE_BUY)||(direction<0 && type==POSITION_TYPE_SELL)) count++;
   }
   return count;
}

double OurLots()
{
   double lots=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      const ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      const long magic=PositionGetInteger(POSITION_MAGIC);
      if(magic<(long)InpBaseMagic || magic>(long)InpBaseMagic+OMEGA_MAGIC_RANGE) continue;
      lots+=PositionGetDouble(POSITION_VOLUME);
   }
   return lots;
}

double OurDeltaLots()
{
   double delta=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      const ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      const long magic=PositionGetInteger(POSITION_MAGIC);
      if(magic<(long)InpBaseMagic || magic>(long)InpBaseMagic+OMEGA_MAGIC_RANGE) continue;
      const long type=PositionGetInteger(POSITION_TYPE);
      const double vol=PositionGetDouble(POSITION_VOLUME);
      delta+=(type==POSITION_TYPE_BUY?vol:-vol);
   }
   return delta;
}

int CountOurPending()
{
   int count=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      const ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      const long magic=OrderGetInteger(ORDER_MAGIC);
      if(magic>=(long)InpBaseMagic && magic<=(long)InpBaseMagic+OMEGA_MAGIC_RANGE) count++;
   }
   return count;
}

long SignalFingerprint(const SignalInfo &s)
{
   // Coarse market-state fingerprint: prevents 20ms copies of the same wave
   // while allowing a genuinely new state to re-enter.
   const long v=(long)MathRound(s.velocity/5.0);
   const long a=(long)MathRound(s.acceleration/5.0);
   const long d=(long)MathRound(s.displacement_pts/3.0);
   const long p=(long)MathRound(s.pressure*10.0);
   const long i=(long)MathRound(s.intensity*10.0);
   long h=(long)s.direction*1000003L+(long)s.regime*10007L+v*97L+a*53L+d*31L+p*17L+i*7L;
   if(h<0) h=-h;
   return h;
}

bool DuplicateThesisBlocked(const SignalInfo &s)
{
   const int idx=ClampI(s.strategy,1,3);
   const long now=s.created_msc;
   const long fp=SignalFingerprint(s);
   if(now-g_last_strategy_trade_msc[idx]<InpStrategyCooldownMs && g_last_signal_fingerprint[idx]==fp) return true;

   if(InpRejectDuplicatePending)
   {
      for(int i=OrdersTotal()-1;i>=0;i--)
      {
         const ulong ticket=OrderGetTicket(i);
         if(ticket==0 || !OrderSelect(ticket)) continue;
         if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
         const long magic=OrderGetInteger(ORDER_MAGIC);
         if(magic!=(long)(InpBaseMagic+idx)) continue;
         const long type=OrderGetInteger(ORDER_TYPE);
         const bool same_dir=(s.direction>0 ?
                              (type==ORDER_TYPE_BUY_LIMIT || type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_BUY_STOP_LIMIT) :
                              (type==ORDER_TYPE_SELL_LIMIT || type==ORDER_TYPE_SELL_STOP || type==ORDER_TYPE_SELL_STOP_LIMIT));
         if(same_dir) return true;
      }
   }
   return false;
}

double OutstandingRequestRiskMoney()
{
   double risk=0.0;
   for(int i=0;i<OMEGA_REQ_CAPACITY;i++)
   {
      if(!g_requests[i].active || g_requests[i].volume<=0.0 || g_requests[i].sl<=0.0) continue;
      const ENUM_ORDER_TYPE ot=(g_requests[i].direction>0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      double p=0.0;
      if(OrderCalcProfit(ot,_Symbol,g_requests[i].volume,g_requests[i].requested_price,g_requests[i].sl,p))
         risk+=MathAbs(p);
   }
   return MathMax(0.0,risk);
}

double OutstandingRequestMargin()
{
   double margin=0.0;
   for(int i=0;i<OMEGA_REQ_CAPACITY;i++)
   {
      if(!g_requests[i].active || g_requests[i].volume<=0.0 || g_requests[i].requested_price<=0.0) continue;
      const ENUM_ORDER_TYPE ot=(g_requests[i].direction>0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      double m=0.0;
      if(OrderCalcMargin(ot,_Symbol,g_requests[i].volume,g_requests[i].requested_price,m)) margin+=MathMax(0.0,m);
   }
   return margin;
}

bool PortfolioRiskGate(const SignalInfo &s,const double lot)
{
   if(lot<=0.0) { g_gate_code=REJ_LOT_ZERO; return false; }
   const double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   const double margin=AccountInfoDouble(ACCOUNT_MARGIN);
   const double free_margin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(equity<=0.0 || free_margin<=0.0) return false;

   // Dynamic Small-Account Concurrency Ladder:
   // Capital USD 10 - USD 20: 2 positions, +1 position per +USD 20 equity, capped at 15 positions.
   int max_allowed_pos = InpMaxConcurrentPositions;
   if(equity<=300.0)
   {
      max_allowed_pos = MathMin(15, 2 + (int)MathFloor(MathMax(0.0, equity - 20.0) / 20.0));
   }
   if(CountOurPositions()>=max_allowed_pos) { g_gate_code=REJ_MAXPOS; return false; }
   if(CountOurPositionsDirection(s.direction)>=InpMaxSameDirectionPositions) { g_gate_code=REJ_SAMEDIR; return false; }
   if(OurLots()+lot>InpMaxPortfolioLots) { g_gate_code=REJ_LOTS_CAP; return false; }

   const double delta=OurDeltaLots();
   if(MathAbs(delta+s.direction*lot)>InpMaxPortfolioDeltaLots) { g_gate_code=REJ_DELTA_CAP; return false; }
   if(equity<=0.0 || free_margin<=0.0) return false;
   const double reserved_margin=OutstandingRequestMargin();
   if((margin+reserved_margin)/equity>=InpMarginUtilizationMax) { g_gate_code=REJ_MARGIN_CAP; return false; }

   // Portfolio risk cap using actual SL distance.
   const double new_risk=LossPerLot(s.sl_pts)*lot;
   const double existing=OpenRiskMoney()+PendingRiskMoney()+OutstandingRequestRiskMoney();
   const double cap=equity*InpPortfolioRiskCapPct/100.0;
   if(existing+new_risk>cap) { g_gate_code=REJ_PORTFOLIO_RISK; return false; }

   return true;
}

//----------------------------- Token Bucket -----------------------//
void RefillTokens()
{
   const long now=NowMicroseconds();
   if(g_last_token_us<=0)
   {
      g_last_token_us=now;
      g_tokens=(double)InpMaxRequestsPerSecond;
      return;
   }
   const double elapsed=(double)(now-g_last_token_us)/1000000.0;
   if(elapsed<=0.0) return;
   g_tokens=MathMin((double)InpMaxRequestsPerSecond,g_tokens+elapsed*MathMax(0.1,InpTokenRefillPerSecond));
   g_last_token_us=now;
}

bool ConsumeToken()
{
   RefillTokens();
   if(g_tokens<1.0) return false;
   g_tokens-=1.0;
   return true;
}

//----------------------------- Request Tracking ------------------//
int FindFreeRequestSlot()
{
   for(int i=0;i<OMEGA_REQ_CAPACITY;i++) if(!g_requests[i].active) return i;
   return -1;
}

int FindRequestById(const ulong request_id)
{
   if(request_id==0) return -1;
   for(int i=0;i<OMEGA_REQ_CAPACITY;i++)
      if(g_requests[i].active && g_requests[i].request_id==request_id) return i;
   return -1;
}

int FindRequestByLocalId(const ulong local_id)
{
   if(local_id==0) return -1;
   for(int i=0;i<OMEGA_REQ_CAPACITY;i++)
      if(g_requests[i].active && g_requests[i].local_id==local_id) return i;
   return -1;
}

int TrackRequest(const MqlTradeRequest &req,const ulong local_id,const long sent_us,const int strategy=0,const ulong signal_id=0)
{
   const int slot=FindFreeRequestSlot();
   if(slot<0) return -1;
   g_requests[slot].active=true;
   g_requests[slot].request_id=0;
   g_requests[slot].local_id=local_id;
   g_requests[slot].sent_us=sent_us;
   g_requests[slot].sent_msc=sent_us/1000;
   g_requests[slot].strategy=strategy;
   g_requests[slot].direction=(req.type==ORDER_TYPE_BUY || req.type==ORDER_TYPE_BUY_LIMIT ? 1:-1);
   g_requests[slot].order_type=req.type;
   g_requests[slot].requested_price=req.price;
   g_requests[slot].volume=req.volume;
   g_requests[slot].sl=req.sl;
   g_requests[slot].tp=req.tp;
   g_requests[slot].signal_id=signal_id;
   return slot;
}

void BindRequestId(const int slot,const ulong request_id)
{
   if(slot>=0 && slot<OMEGA_REQ_CAPACITY) { g_requests[slot].request_id=request_id; g_state_dirty=true; }
}

void ClearRequest(const int slot)
{
   if(slot<0 || slot>=OMEGA_REQ_CAPACITY) return;
   ZeroMemory(g_requests[slot]);
}

void PurgeOldRequests()
{
   const long now=NowMicroseconds();
   for(int i=0;i<OMEGA_REQ_CAPACITY;i++)
   {
      if(g_requests[i].active && (now-g_requests[i].sent_us)>120000000)
         ClearRequest(i);
   }
}

//----------------------------- Filling Mode -----------------------//
ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
   const long mode=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   const ENUM_SYMBOL_TRADE_EXECUTION exec=(ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_EXEMODE);
   if(exec==SYMBOL_TRADE_EXECUTION_MARKET)
   {
      if((mode & SYMBOL_FILLING_IOC)!=0) return ORDER_FILLING_IOC;
      if((mode & SYMBOL_FILLING_FOK)!=0) return ORDER_FILLING_FOK;
      // No legal market filling policy exposed by the symbol. The request will be rejected by OrderCheck.
      return ORDER_FILLING_FOK;
   }
   if((mode & SYMBOL_FILLING_FOK)!=0) return ORDER_FILLING_FOK;
   if((mode & SYMBOL_FILLING_IOC)!=0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

bool IsTradeEnvironmentReady()
{
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) { g_gate_code=REJ_NOT_CONNECTED; return false; }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) { g_gate_code=REJ_MQL_DISABLED; return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) { g_gate_code=REJ_ACCT_DISABLED; return false; }
   return true;
}

//----------------------------- Adaptive Execution -----------------//
double AdaptiveDeviationPts()
{
   double d=(double)InpMaxSlippagePts;
   if(!InpAdaptiveExecution) return d;
   if(g_avg_slippage_pts>InpBadSlippagePts) d*=0.65;
   if(g_avg_latency_ms>InpExecutionLatencyMs) d*=0.75;
   if(CurrentSpreadPts()>InpBaselineSpreadPts*1.5) d*=0.50;
   return ClampD(d,1.0,(double)InpMaxSlippagePts);
}

bool CanSendOrder()
{
   return IsTradeEnvironmentReady();
}

bool CheckMarginForOrder(const ENUM_ORDER_TYPE type,const double lot,const double price)
{
   double margin=0.0;
   if(!OrderCalcMargin(type,_Symbol,lot,price,margin)) return false;
   const double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   const double free=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(equity<=0.0 || free<=0.0) return false;
   const double current_margin=AccountInfoDouble(ACCOUNT_MARGIN);
   const double projected_util=(current_margin+margin)/equity;
   if(projected_util>=InpMarginUtilizationMax) return false;
   if(free-margin < equity*(InpFreeMarginFloorPct/100.0)) return false;
   return true;
}

ulong MakeMagic(const int strategy)
{
   return InpBaseMagic+(ulong)ClampI(strategy,1,3);
}

string StrategyName(const int strategy)
{
   if(strategy==STRAT_MICRO_REVERSION) return "MICRO_REV";
   if(strategy==STRAT_MOMENTUM) return "MOMENTUM";
   if(strategy==STRAT_EXHAUSTION) return "EXHAUST";
   return "UNKNOWN";
}

//----------------------------- Order Construction -----------------//
double MinStopDistancePts()
{
   const long stops=(long)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   const long freeze=(long)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)MathMax(stops,freeze);
}

bool StopDistancesValid(const double sl_pts,const double tp_pts)
{
   const double min_stop=MinStopDistancePts();
   return sl_pts>=min_stop && tp_pts>=min_stop;
}

bool ValidateTradeRequest(MqlTradeRequest &req)
{
   if(!InpUseOrderCheck) return true;
   MqlTradeCheckResult chk={};
   ResetLastError();
   const bool ok=OrderCheck(req,chk);
   g_last_check_retcode=(int)chk.retcode;
   if(ok && (chk.retcode==TRADE_RETCODE_DONE || chk.retcode==TRADE_RETCODE_PLACED ||
             chk.retcode==TRADE_RETCODE_DONE_PARTIAL))
      return true;

   if(g_check_log_count<8)
   {
      g_check_log_count++;
      PrintFormat("X13 Omega: OrderCheck %s retcode=%d comment=%s vol=%.2f price=%.3f sl=%.3f tp=%.3f margin=%.2f free=%.2f",
                  (ok?"failed":"returned false"),chk.retcode,chk.comment,req.volume,
                  req.price,req.sl,req.tp,chk.margin,chk.margin_free);
   }

   // OrderCheck is a pre-flight advisory and is unreliable in the strategy
   // tester. Keep the hard account-side blockers, let OrderSend decide the
   // rest, and record the retcode so the funnel stays measurable.
   switch((int)chk.retcode)
   {
      case TRADE_RETCODE_NO_MONEY:
      case TRADE_RETCODE_INVALID_VOLUME:
      case TRADE_RETCODE_INVALID_STOPS:
      case TRADE_RETCODE_INVALID_FILL:
      case TRADE_RETCODE_INVALID_PRICE:
      case TRADE_RETCODE_MARKET_CLOSED:
      case TRADE_RETCODE_TRADE_DISABLED:
         return false;
   }
   g_check_advisory_override++;
   return true;
}

bool SendMarket(const SignalInfo &s,const double lot)
{
   if(lot<=0.0) { g_gate_code=REJ_LOT_ZERO; return false; }
   if(!CanSendOrder()) { g_gate_code=REJ_SEND_CANNOT; return false; }
   MqlTick t;
   if(!SymbolInfoTick(_Symbol,t)) { g_gate_code=REJ_SEND_CANNOT; return false; }
   const ENUM_ORDER_TYPE type=(s.direction>0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   const double price=(s.direction>0 ? t.ask : t.bid);
   if(!CheckMarginForOrder(type,lot,price)) { g_gate_code=REJ_SEND_MARGIN; return false; }

   const double point=PointValue();
   if(point<=0.0 || !StopDistancesValid(s.sl_pts,s.tp_pts)) { g_gate_code=REJ_SEND_STOPS; return false; }
   const double sl=NormalizePrice(s.direction>0 ? price-s.sl_pts*point : price+s.sl_pts*point);
   const double tp=NormalizePrice(s.direction>0 ? price+s.tp_pts*point : price-s.tp_pts*point);

   MqlTradeRequest req={};
   MqlTradeResult res={};
   req.action=TRADE_ACTION_DEAL;
   req.symbol=_Symbol;
   req.magic=MakeMagic(s.strategy);
   req.volume=lot;
   req.type=type;
   req.price=price;
   req.sl=sl;
   req.tp=tp;
   req.deviation=(ulong)AdaptiveDeviationPts();
   req.type_filling=GetFillingMode();
   req.comment=InpCommentPrefix+"|"+StrategyName(s.strategy)+"|"+IntegerToString((int)(s.signal_id%1000000));

   const ulong local_id=++g_local_request_counter;
   const long sent_us=NowMicroseconds();
   const int slot=TrackRequest(req,local_id,sent_us,s.strategy,s.signal_id);
   if(slot<0) { g_gate_code=REJ_SEND_SLOT; return false; }

   if(!ValidateTradeRequest(req))
   {
      g_gate_code=REJ_SEND_VALIDATE;
      ClearRequest(slot);
      return false;
   }
   if(!ConsumeToken())
   {
      g_gate_code=REJ_SEND_TOKEN;
      ClearRequest(slot);
      return false;
   }
   ResetLastError();
   if(!OrderSendAsync(req,res))
   {
      g_gate_code=REJ_SEND_ORDER;
      ClearRequest(slot);
      return false;
   }
   BindRequestId(slot,res.request_id);
   g_last_market_send_us=sent_us;
   g_last_strategy_trade_msc[s.strategy]=NowMilliseconds();
   g_thesis[s.strategy].last_trade_msc=g_last_strategy_trade_msc[s.strategy];
   return true;
}

bool SendLimit(const SignalInfo &s,const double lot)
{
   if(lot<=0.0) { g_gate_code=REJ_LOT_ZERO; return false; }
   if(!CanSendOrder()) { g_gate_code=REJ_SEND_CANNOT; return false; }
   if(CountOurPending()>=InpMaxPendingOrders) { g_gate_code=REJ_MAXPOS; return false; }
   MqlTick t;
   if(!SymbolInfoTick(_Symbol,t)) { g_gate_code=REJ_SEND_CANNOT; return false; }
   const double point=PointValue();
   if(point<=0.0) { g_gate_code=REJ_SEND_STOPS; return false; }

   // Passive reversion: buy limit below bid, sell limit above ask.
   double price=(s.direction>0 ? t.bid-InpLimitDistancePts*point : t.ask+InpLimitDistancePts*point);
   price=NormalizePrice(price);
   const ENUM_ORDER_TYPE type=(s.direction>0 ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT);
   if(!CheckMarginForOrder(type,lot,price)) { g_gate_code=REJ_SEND_MARGIN; return false; }

   const double sl=NormalizePrice(s.direction>0 ? price-s.sl_pts*point : price+s.sl_pts*point);
   const double tp=NormalizePrice(s.direction>0 ? price+s.tp_pts*point : price-s.tp_pts*point);

   MqlTradeRequest req={};
   MqlTradeResult res={};
   req.action=TRADE_ACTION_PENDING;
   req.symbol=_Symbol;
   req.magic=MakeMagic(s.strategy);
   req.volume=lot;
   req.type=type;
   req.price=price;
   req.sl=sl;
   req.tp=tp;
   req.type_time=ORDER_TIME_SPECIFIED;
   req.expiration=TimeCurrent()+InpLimitExpirySec;
   req.type_filling=ORDER_FILLING_RETURN;
   req.comment=InpCommentPrefix+"|LIMIT|"+StrategyName(s.strategy)+"|"+IntegerToString((int)(s.signal_id%1000000));

   const ulong local_id=++g_local_request_counter;
   const long sent_us=NowMicroseconds();
   const int slot=TrackRequest(req,local_id,sent_us,s.strategy,s.signal_id);
   if(slot<0) { g_gate_code=REJ_SEND_SLOT; return false; }
   if(!ValidateTradeRequest(req))
   {
      g_gate_code=REJ_SEND_VALIDATE;
      ClearRequest(slot);
      return false;
   }
   if(!ConsumeToken())
   {
      g_gate_code=REJ_SEND_TOKEN;
      ClearRequest(slot);
      return false;
   }
   ResetLastError();
   if(!OrderSendAsync(req,res))
   {
      g_gate_code=REJ_SEND_ORDER;
      ClearRequest(slot);
      return false;
   }
   BindRequestId(slot,res.request_id);
   g_last_strategy_trade_msc[s.strategy]=NowMilliseconds();
   return true;
}

//----------------------------- Position Modification --------------//
bool ModifyPositionSLTP(const ulong ticket,const double sl,const double tp)
{
   if(!PositionSelectByTicket(ticket)) return false;
   const double nsl=NormalizePrice(sl);
   const double ntp=NormalizePrice(tp);
   const int idx=EnsurePositionControl(ticket);
   if(idx<0) return false;
   const long now_ms=NowMilliseconds();
   if(g_pos_ctrl[idx].last_modify_ms>0 && now_ms-g_pos_ctrl[idx].last_modify_ms<InpPositionModifyCooldownMs) return false;
   if(g_pos_ctrl[idx].last_sent_sl==nsl && g_pos_ctrl[idx].last_sent_tp==ntp) return false;

   MqlTradeRequest req={};
   MqlTradeResult res={};
   req.action=TRADE_ACTION_SLTP;
   req.position=ticket;
   req.symbol=PositionGetString(POSITION_SYMBOL);
   req.sl=nsl;
   req.tp=ntp;
   req.magic=(ulong)PositionGetInteger(POSITION_MAGIC);
   if(!ValidateTradeRequest(req) || !ConsumeToken()) return false;
   ResetLastError();
   if(!OrderSendAsync(req,res)) return false;
   g_pos_ctrl[idx].last_sent_sl=nsl;
   g_pos_ctrl[idx].last_sent_tp=ntp;
   g_pos_ctrl[idx].last_modify_ms=now_ms;
   return true;
}

bool ClosePosition(const ulong ticket,const string reason)
{
   if(!PositionSelectByTicket(ticket)) return false;
   const int pidx=EnsurePositionControl(ticket);
   if(pidx<0 || g_pos_ctrl[pidx].close_pending) return false;
   MqlTick t;
   if(!SymbolInfoTick(_Symbol,t)) return false;
   const long ptype=PositionGetInteger(POSITION_TYPE);
   const double volume=PositionGetDouble(POSITION_VOLUME);
   const ENUM_ORDER_TYPE type=(ptype==POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
   const double price=(type==ORDER_TYPE_BUY ? t.ask : t.bid);

   MqlTradeRequest req={};
   MqlTradeResult res={};
   req.action=TRADE_ACTION_DEAL;
   req.position=ticket;
   req.symbol=_Symbol;
   req.magic=(ulong)PositionGetInteger(POSITION_MAGIC);
   req.volume=volume;
   req.type=type;
   req.price=price;
   req.deviation=(ulong)AdaptiveDeviationPts();
   req.type_filling=GetFillingMode();
   req.comment=InpCommentPrefix+"|CLOSE|"+reason;
   const ulong local_id=++g_local_request_counter;
   const long sent_us=NowMicroseconds();
   const int slot=TrackRequest(req,local_id,sent_us,(int)((long)PositionGetInteger(POSITION_MAGIC)-(long)InpBaseMagic),0);
   if(slot<0) return false;
   if(!ValidateTradeRequest(req)) { ClearRequest(slot); return false; }
   if(!ConsumeToken()) { ClearRequest(slot); return false; }
   if(!OrderSendAsync(req,res)) { ClearRequest(slot); return false; }
   BindRequestId(slot,res.request_id);
   g_pos_ctrl[pidx].close_pending=true;
   return true;
}

bool ClosePartialPosition(const ulong ticket,const double volume,const string reason)
{
   if(!PositionSelectByTicket(ticket) || volume<=0.0) return false;
   const int pidx=EnsurePositionControl(ticket);
   if(pidx<0 || g_pos_ctrl[pidx].close_pending) return false;
   MqlTick t;
   if(!SymbolInfoTick(_Symbol,t)) return false;
   const long ptype=PositionGetInteger(POSITION_TYPE);
   const ENUM_ORDER_TYPE type=(ptype==POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
   const double price=(type==ORDER_TYPE_BUY ? t.ask : t.bid);
   MqlTradeRequest req={};
   MqlTradeResult res={};
   req.action=TRADE_ACTION_DEAL;
   req.position=ticket;
   req.symbol=_Symbol;
   req.magic=(ulong)PositionGetInteger(POSITION_MAGIC);
   req.volume=volume;
   req.type=type;
   req.price=price;
   req.deviation=(ulong)AdaptiveDeviationPts();
   req.type_filling=GetFillingMode();
   req.comment=InpCommentPrefix+"|CLOSE|"+reason;
   const ulong local_id=++g_local_request_counter;
   const long sent_us=NowMicroseconds();
   const int slot=TrackRequest(req,local_id,sent_us,(int)((long)PositionGetInteger(POSITION_MAGIC)-(long)InpBaseMagic),0);
   if(slot<0 || !ValidateTradeRequest(req) || !ConsumeToken()) { if(slot>=0) ClearRequest(slot); return false; }
   if(!OrderSendAsync(req,res)) { ClearRequest(slot); return false; }
   BindRequestId(slot,res.request_id);
   return true;
}


//----------------------------- Deal Sync --------------------------//
// OnTradeTransaction is not reliably delivered for async requests in the
// tester, which left the ledger and telemetry empty even with live trades.
// The deal history is reconciled on a timer instead.
ulong g_deal_seen[64];
int   g_deal_seen_idx=0;
long  g_deal_sync_msc=0;

bool DealAlreadyProcessed(const ulong ticket)
{
   if(ticket==0) return true;
   for(int i=0;i<64;i++) if(g_deal_seen[i]==ticket) return true;
   return false;
}

void MarkDealProcessed(const ulong ticket)
{
   g_deal_seen[g_deal_seen_idx]=ticket;
   g_deal_seen_idx=(g_deal_seen_idx+1)%64;
}

void ProcessDealTicket(const ulong deal)
{
   if(DealAlreadyProcessed(deal)) return;
   MarkDealProcessed(deal);
   if(HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol) return;
   const long magic=HistoryDealGetInteger(deal,DEAL_MAGIC);
   if(magic<(long)InpBaseMagic || magic>(long)InpBaseMagic+OMEGA_MAGIC_RANGE) return;

   const long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
   const double profit=HistoryDealGetDouble(deal,DEAL_PROFIT)+
                       HistoryDealGetDouble(deal,DEAL_SWAP)+
                       HistoryDealGetDouble(deal,DEAL_COMMISSION);
   const double volume=HistoryDealGetDouble(deal,DEAL_VOLUME);
   const double price=HistoryDealGetDouble(deal,DEAL_PRICE);
   const int strategy=ClampI((int)(magic-(long)InpBaseMagic),1,3);
   const int direction=(HistoryDealGetInteger(deal,DEAL_TYPE)==DEAL_TYPE_BUY ? 1 : -1);

   QueueTelemetry(entry==DEAL_ENTRY_IN ? "ENTRY" : "EXIT",deal,direction,volume,price,
                  0.0,0,profit,strategy);
   if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY || entry==DEAL_ENTRY_INOUT)
      AddDealSample(0.0,profit,volume,0,direction,strategy);
}

void SyncDeals(const bool force=false)
{
   const long now=NowMilliseconds();
   if(!force && now-g_deal_sync_msc<30000) return;
   g_deal_sync_msc=now;
   if(!HistorySelect(TimeCurrent()-30*86400,TimeCurrent()+3600)) return;
   const int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
   {
      const ulong t=HistoryDealGetTicket(i);
      if(t!=0) ProcessDealTicket(t);
   }
}

//----------------------------- Position Management ----------------//
void ManagePositions()
{
   const double atr=ATRPoints();
   const double point=PointValue();
   if(atr<=0.0 || point<=0.0) return;
   MqlTick t;
   if(!SymbolInfoTick(_Symbol,t)) return;

   const double sfloor=GeometrySpreadPts((t.ask-t.bid)/MathMax(point,OMEGA_EPS));
   // Iteration 4 measured the defect: 3 winners closed at +12 pts against a
   // 296 pt stop, because stage 1 moved the stop to break-even after only 19%
   // of the stop distance. The ladder is now scaled to the stop distance, and
   // every lock is above the round-trip cost so a "protected" exit is not a
   // disguised loss.
   const double sl_ref=StopLossPts(atr,sfloor);
   const double be1_trig=MathMax(InpBEStage1TriggerPts,sl_ref*InpBEStage1StopFraction);
   const double be1_lock=MathMax(InpBEStage1LockPts,sfloor*1.20);
   const double be2_trig=MathMax(InpBEStage2TriggerPts,sl_ref*InpBEStage2StopFraction);
   const double be2_lock=MathMax(InpBEStage2LockPts,sl_ref*0.30);

   const double velocity=MathAbs(g_last_velocity);
   double trail_pts=atr*InpTrailWeakATR;
   if(velocity>=InpTrailVelocityStrong)
      trail_pts=atr*InpTrailStrongATR;
   else if(velocity>InpTrailVelocityWeak)
   {
      const double q=ClampD((velocity-InpTrailVelocityWeak)/MathMax(1.0,InpTrailVelocityStrong-InpTrailVelocityWeak),0.0,1.0);
      trail_pts=atr*(InpTrailWeakATR+q*(InpTrailStrongATR-InpTrailWeakATR));
   }
   trail_pts=MathMax(trail_pts,sfloor*2.0);

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      const ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      const long magic=PositionGetInteger(POSITION_MAGIC);
      if(magic<(long)InpBaseMagic || magic>(long)InpBaseMagic+OMEGA_MAGIC_RANGE) continue;

      const long type=PositionGetInteger(POSITION_TYPE);
      const double open=PositionGetDouble(POSITION_PRICE_OPEN);
      const double sl=PositionGetDouble(POSITION_SL);
      const double tp=PositionGetDouble(POSITION_TP);
      const double price=(type==POSITION_TYPE_BUY ? t.bid : t.ask);
      const double profit_pts=(type==POSITION_TYPE_BUY ? (price-open)/point : (open-price)/point);
      const int pcidx=EnsurePositionControl(ticket);
      if(pcidx>=0 && InpEnableMFE_MAE)
      {
         g_pos_ctrl[pcidx].mfe_pts=MathMax(g_pos_ctrl[pcidx].mfe_pts,profit_pts);
         g_pos_ctrl[pcidx].mae_pts=MathMin(g_pos_ctrl[pcidx].mae_pts,profit_pts);
      }

      // Partial profit extraction: lock part of a validated move while leaving a runner.
      if(pcidx>=0 && InpEnablePartialClose && !g_pos_ctrl[pcidx].partial_done &&
         InpPartialCloseTrigger>0.0 && profit_pts>=MathMax(InpMinSLPts,InpTP_ATR_Multiplier*atr)*InpPartialCloseTrigger)
      {
         const double current_vol=PositionGetDouble(POSITION_VOLUME);
         const double broker_min=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
         double close_vol=NormalizeVolume(current_vol*InpPartialClosePercent);
         if(close_vol>0.0 && close_vol<current_vol && (current_vol-close_vol)>=MathMax(broker_min,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)))
         {
            if(ClosePartialPosition(ticket,close_vol,"PARTIAL")) g_pos_ctrl[pcidx].partial_done=true;
         }
      }
      const datetime open_time=(datetime)PositionGetInteger(POSITION_TIME);
      const int age=(int)(TimeCurrent()-open_time);

      // Time invalidation: a high-frequency thesis that does not move is stale.
      if(InpCloseStalledTrades && age>=InpMaxTradeAgeSec &&
         profit_pts<InpStallProfitFloorPts && MathAbs(g_last_velocity)<=InpStallVelocityPtsSec)
      {
         ClosePosition(ticket,"STALL");
         continue;
      }

      // Time invalidation only when position is stalling with adverse momentum
      if(age>=InpMaxTradeAgeSec && profit_pts< -InpBEExtraPts && MathAbs(g_last_velocity)<=InpStallVelocityPtsSec)
      {
         ClosePosition(ticket,"TIME");
         continue;
      }

      // Dual-Stage Micro-BE, both stages quoted in spread multiples
      if(InpUseMicroBreakEven)
      {
         if(profit_pts>=be2_trig)
         {
            const double be2=(type==POSITION_TYPE_BUY ? open+be2_lock*point : open-be2_lock*point);
            const bool improve2=(type==POSITION_TYPE_BUY ? (sl==0.0 || be2>sl) : (sl==0.0 || be2<sl));
            if(improve2) ModifyPositionSLTP(ticket,be2,tp);
         }
         else if(profit_pts>=be1_trig)
         {
            const double be1=(type==POSITION_TYPE_BUY ? open+be1_lock*point : open-be1_lock*point);
            const bool improve1=(type==POSITION_TYPE_BUY ? (sl==0.0 || be1>sl) : (sl==0.0 || be1<sl));
            if(improve1) ModifyPositionSLTP(ticket,be1,tp);
         }
      }

      // Momentum-decay trailing.
      if(InpUseVelocityTrailing && profit_pts>0.0)
      {
         double new_sl=sl;
         if(type==POSITION_TYPE_BUY)
         {
            new_sl=price-trail_pts*point;
            if(new_sl>open && (sl==0.0 || new_sl>sl)) ModifyPositionSLTP(ticket,new_sl,tp);
         }
         else
         {
            new_sl=price+trail_pts*point;
            if(new_sl<open && (sl==0.0 || new_sl<sl)) ModifyPositionSLTP(ticket,new_sl,tp);
         }
      }
   }
}

//----------------------------- Pending Maintenance ----------------//
int FindPendingControl(const ulong ticket)
{
   for(int i=0;i<OMEGA_PENDING_CTRL_CAP;i++) if(g_pending_ctrl[i].active && g_pending_ctrl[i].ticket==ticket) return i;
   return -1;
}

int EnsurePendingControl(const ulong ticket)
{
   int idx=FindPendingControl(ticket);
   if(idx>=0) return idx;
   for(int i=0;i<OMEGA_PENDING_CTRL_CAP;i++)
   {
      if(!g_pending_ctrl[i].active)
      {
         g_pending_ctrl[i].active=true;
         g_pending_ctrl[i].ticket=ticket;
         g_pending_ctrl[i].reprice_count=0;
         g_pending_ctrl[i].last_action_ms=0;
         return i;
      }
   }
   return -1;
}

int FindPositionControl(const ulong ticket)
{
   for(int i=0;i<OMEGA_POS_CTRL_CAP;i++) if(g_pos_ctrl[i].active && g_pos_ctrl[i].ticket==ticket) return i;
   return -1;
}

int EnsurePositionControl(const ulong ticket)
{
   int idx=FindPositionControl(ticket);
   if(idx>=0) return idx;
   for(int i=0;i<OMEGA_POS_CTRL_CAP;i++)
   {
      if(!g_pos_ctrl[i].active)
      {
         g_pos_ctrl[i].active=true;
         g_pos_ctrl[i].ticket=ticket;
         g_pos_ctrl[i].last_sent_sl=0.0;
         g_pos_ctrl[i].last_sent_tp=0.0;
         g_pos_ctrl[i].last_modify_ms=0;
         g_pos_ctrl[i].close_pending=false;
         g_pos_ctrl[i].partial_done=false;
         g_pos_ctrl[i].mfe_pts=0.0;
         g_pos_ctrl[i].mae_pts=0.0;
         g_pos_ctrl[i].entry_msc=NowMilliseconds();
         g_pos_ctrl[i].entry_price=0.0;
         g_pos_ctrl[i].sl_pts=0.0;
         g_pos_ctrl[i].tp_pts=0.0;
         g_pos_ctrl[i].entry_spread_pts=CurrentSpreadPts();
         if(g_pos_ctrl[i].entry_spread_pts==DBL_MAX) g_pos_ctrl[i].entry_spread_pts=0.0;
         g_pos_ctrl[i].strategy=0;
         if(PositionSelectByTicket(ticket))
         {
            const double point=PointValue();
            const double open=PositionGetDouble(POSITION_PRICE_OPEN);
            const double sl=PositionGetDouble(POSITION_SL);
            const double tp=PositionGetDouble(POSITION_TP);
            g_pos_ctrl[i].entry_price=open;
            g_pos_ctrl[i].strategy=ClampI((int)(PositionGetInteger(POSITION_MAGIC)-(long)InpBaseMagic),1,3);
            if(point>0.0 && open>0.0)
            {
               if(sl>0.0) g_pos_ctrl[i].sl_pts=MathAbs(open-sl)/point;
               if(tp>0.0) g_pos_ctrl[i].tp_pts=MathAbs(tp-open)/point;
            }
         }
         return i;
      }
   }
   return -1;
}

void PurgePositionControls()
{
   for(int i=0;i<OMEGA_POS_CTRL_CAP;i++)
   {
      if(!g_pos_ctrl[i].active) continue;
      if(!PositionSelectByTicket(g_pos_ctrl[i].ticket)) ZeroMemory(g_pos_ctrl[i]);
   }
}

void CancelOurPending()
{
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      const ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      const long magic=OrderGetInteger(ORDER_MAGIC);
      if(magic<(long)InpBaseMagic || magic>(long)InpBaseMagic+OMEGA_MAGIC_RANGE) continue;
      if(!ConsumeToken()) break;
      MqlTradeRequest req={};
      MqlTradeResult res={};
      req.action=TRADE_ACTION_REMOVE;
      req.order=ticket;
      req.symbol=_Symbol;
      req.magic=(ulong)magic;
      req.comment=InpCommentPrefix+"|ROLLOVER_REMOVE";
      if(!OrderSendAsync(req,res))
         PrintFormat("X13 Omega: rollover remove failed for #%I64u (retcode %d)",ticket,res.retcode);
   }
}

void RepriceLimits()
{
   if(IsRollover()) return;
   MqlTick t;
   if(!SymbolInfoTick(_Symbol,t)) return;
   const double point=PointValue();
   if(point<=0.0) return;
   const long now_ms=NowMilliseconds();

   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      const ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      const long magic=OrderGetInteger(ORDER_MAGIC);
      if(magic<(long)InpBaseMagic || magic>(long)InpBaseMagic+OMEGA_MAGIC_RANGE) continue;
      const ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type!=ORDER_TYPE_BUY_LIMIT && type!=ORDER_TYPE_SELL_LIMIT) continue;

      const int idx=EnsurePendingControl(ticket);
      if(idx<0) continue;
      if(g_pending_ctrl[idx].reprice_count>=InpMaxRepricesPerOrder) continue;
      if(g_pending_ctrl[idx].last_action_ms>0 && now_ms-g_pending_ctrl[idx].last_action_ms<InpRepriceCooldownMs) continue;

      const double old_price=OrderGetDouble(ORDER_PRICE_OPEN);
      const double target=(type==ORDER_TYPE_BUY_LIMIT ? t.bid-InpLimitDistancePts*point : t.ask+InpLimitDistancePts*point);
      const double new_price=NormalizePrice(target);
      if(MathAbs(new_price-old_price)/point<InpLimitRepriceTriggerPts) continue;

      if(!ConsumeToken()) break;
      MqlTradeRequest req={};
      MqlTradeResult res={};
      req.action=TRADE_ACTION_MODIFY;
      req.order=ticket;
      req.symbol=_Symbol;
      req.price=new_price;
      req.sl=OrderGetDouble(ORDER_SL);
      req.tp=OrderGetDouble(ORDER_TP);
      req.type_time=ORDER_TIME_SPECIFIED;
      req.expiration=(datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      req.magic=(ulong)magic;
      req.comment=InpCommentPrefix+"|REPRICE";
      if(OrderSendAsync(req,res))
      {
         g_pending_ctrl[idx].reprice_count++;
         g_pending_ctrl[idx].last_action_ms=now_ms;
      }
   }
}

//----------------------------- Signal Routing ---------------------//
bool IsNewsHaltActive()
{
   if(!InpEnableNewsFilter) return false;
   // Typical high-impact US Gold news releases in GMT (CPI, NFP, Retail Sales at 12:30/13:30, FOMC at 18:00/19:00)
   const int min_of_day = GMT_MinuteOfDay();
   // 12:30 GMT (750m) +/- window
   if(min_of_day >= 750 - InpNewsPreHaltMin && min_of_day <= 750 + InpNewsPostResumeMin) return true;
   // 13:30 GMT (810m) +/- window
   if(min_of_day >= 810 - InpNewsPreHaltMin && min_of_day <= 810 + InpNewsPostResumeMin) return true;
   // 18:00 GMT (1080m) +/- window
   if(min_of_day >= 1080 - InpNewsPreHaltMin && min_of_day <= 1080 + InpNewsPostResumeMin) return true;
   // 19:00 GMT (1140m) +/- window
   if(min_of_day >= 1140 - InpNewsPreHaltMin && min_of_day <= 1140 + InpNewsPostResumeMin) return true;
   return false;
}

bool GeneralTradingGate()
{
   if(!InpEnableTrading) { g_gate_code=REJ_MQL_DISABLED; return false; }
   if(IsNewsHaltActive()) { g_gate_code=REJ_REGIME; return false; }
   if(!SymbolAllowed()) { g_gate_code=REJ_SESSION; return false; }
   if(!IsTradeEnvironmentReady()) return false;
   if(IsRollover()) { g_gate_code=REJ_ROLLOVER; return false; }
   if(g_count<InpMinTicksBeforeSignal) { g_gate_code=REJ_WARMUP; return false; }
   if(CurrentDrawdownPct()>=InpHardDrawdownPct) { g_gate_code=REJ_DD_HARD; return false; }
   if(InpDailyLossLimitPct>0.0 && DailyDrawdownPct()>=InpDailyLossLimitPct) { g_gate_code=REJ_DAILY_DD; return false; }
   if(MarginUtilization()>=InpMarginUtilizationMax) { g_gate_code=REJ_MARGIN_CAP; return false; }
   if(CountOurPending()>=InpMaxPendingOrders && !InpAllowMultipleStrategies) { g_gate_code=REJ_MAXPOS; return false; }
   return true;
}

bool StrategyDuplicateGate(const SignalInfo &s)
{
   const int idx=ClampI(s.strategy,1,3);
   if(s.created_msc-g_last_signal_msc[idx]<InpStrategyCooldownMs) return false;
   if(DuplicateThesisBlocked(s)) return false;
   g_last_signal_msc[idx]=s.created_msc;
   g_last_signal_fingerprint[idx]=SignalFingerprint(s);
   g_thesis[idx].last_signal_id=s.signal_id;
   g_thesis[idx].last_signal_msc=s.created_msc;
   return true;
}

void RouteOneStrategy(const int strategy)
{
   SignalInfo s;
   if(!BuildSignal(strategy,s)) return;
   if(!StrategyDuplicateGate(s)) { RejectSignal(REJ_COOLDOWN); return; }

   double lot=RiskLot(s);
   if(lot<=0.0) { RejectSignal(REJ_LOT_ZERO); return; }
   if(!PortfolioRiskGate(s,lot)) { RejectSignal(g_gate_code); return; }

   // Reversion is a passive thesis: entering at market pays the spread and
   // the 15 ms drift, measured at 45 pts per fill.
   if(strategy==STRAT_EXHAUSTION || strategy==STRAT_MICRO_REVERSION)
      SendLimit(s,lot);
   else
      SendMarket(s,lot);
}

double SignalRank(const SignalInfo &s)
{
   const double execution=ExecutionCostFactor();
   const double regime_bonus=(s.regime==REGIME_MOMENTUM || s.regime==REGIME_EXHAUSTION || s.regime==REGIME_PULLBACK ? 1.05 : 1.0);
   return s.confidence*MathMax(0.1,s.edge_pts)*execution*regime_bonus;
}

void ExecuteCandidate(const SignalInfo &s)
{
   if(!StrategyDuplicateGate(s)) { RejectSignal(REJ_COOLDOWN); return; }
   double lot=RiskLot(s);
   if(lot<=0.0) { RejectSignal(REJ_LOT_ZERO); return; }
   if(!PortfolioRiskGate(s,lot)) { RejectSignal(g_gate_code); return; }
   const bool passive=(s.strategy==STRAT_EXHAUSTION || s.strategy==STRAT_MICRO_REVERSION);
   const bool sent=(passive ? SendLimit(s,lot) : SendMarket(s,lot));
   if(!sent) RejectSignal(g_gate_code);
}

void RouteSignals()
{
   if(!GeneralTradingGate()) { RejectSignal(g_gate_code); return; }

   SignalInfo candidates[3];
   bool valid[3]={false,false,false};
   for(int i=0;i<3;i++) valid[i]=BuildSignal(i+1,candidates[i]);

   // Conflict arbitration: opposite directions must compete. Same-direction
   // signals may stack when portfolio risk permits, preserving opportunity density.
   int best=-1;
   double best_rank=-1.0;
   for(int i=0;i<3;i++)
   {
      if(!valid[i]) continue;
      const double rank=SignalRank(candidates[i]);
      if(rank>best_rank) { best_rank=rank; best=i; }
   }
   if(best<0) return;

   const int winning_dir=candidates[best].direction;
   ExecuteCandidate(candidates[best]);

   for(int i=0;i<3;i++)
   {
      if(i==best || !valid[i]) continue;
      if(candidates[i].direction==winning_dir)
         ExecuteCandidate(candidates[i]);
      else if(candidates[i].confidence>=0.85 && SignalRank(candidates[i])>=best_rank*1.15)
         ExecuteCandidate(candidates[i]);
   }
}

//----------------------------- Telemetry ---------------------------//
void AddDealSample(const double slip,const double profit,const double volume,
                   const long latency,const int direction,const int strategy)
{
   const int idx=g_sample_head;
   g_samples[idx].slippage_pts=slip;
   g_samples[idx].net_profit=profit;
   g_samples[idx].volume=volume;
   g_samples[idx].latency_ms=latency;
   g_samples[idx].direction=direction;
   g_samples[idx].strategy=strategy;
   g_samples[idx].win=(profit>0.0);
   g_sample_head=(g_sample_head+1)%OMEGA_SAMPLE_CAPACITY;
   g_sample_count=MathMin(OMEGA_SAMPLE_CAPACITY,g_sample_count+1);

   if(profit>0.0)
   {
      g_total_wins++;
      g_total_profit+=profit;
   }
   else if(profit<0.0)
   {
      g_total_losses++;
      g_total_loss+=profit;
   }
   g_total_deals++;

   double slip_sum=0.0,lat_sum=0.0;
   int n=0;
   for(int i=0;i<g_sample_count;i++)
   {
      if(g_samples[i].latency_ms<0) continue;
      slip_sum+=g_samples[i].slippage_pts;
      lat_sum+=(double)g_samples[i].latency_ms;
      n++;
   }
   if(n>0)
   {
      g_avg_slippage_pts=slip_sum/n;
      g_avg_latency_ms=lat_sum/n;
   }
   g_execution_degraded=(g_avg_slippage_pts>InpBadSlippagePts || g_avg_latency_ms>InpExecutionLatencyMs);
   g_state_dirty=true;
}

double AvgSlippage()
{
   return g_avg_slippage_pts;
}

double AvgLatency()
{
   return g_avg_latency_ms;
}

void QueueTelemetry(const string event_name,const ulong ticket,const int direction,
                    const double volume,const double price,const double slip,
                    const long latency,const double profit,const int strategy=0)
{
   if(!InpPersistTelemetry) return;
   int use=0;
   if(g_event_count<OMEGA_EVENT_CAP)
   {
      use=(g_event_head+g_event_count)%OMEGA_EVENT_CAP;
      g_event_count++;
   }
   else
   {
      use=g_event_head;
      g_event_head=(g_event_head+1)%OMEGA_EVENT_CAP;
   }
   ZeroMemory(g_event_queue[use]);
   g_event_queue[use].active=true;
   g_event_queue[use].event_name=event_name;
   g_event_queue[use].ticket=ticket;
   g_event_queue[use].direction=direction;
   g_event_queue[use].volume=volume;
   g_event_queue[use].price=price;
   g_event_queue[use].slippage_pts=slip;
   g_event_queue[use].latency_ms=latency;
   g_event_queue[use].profit=profit;
   g_event_queue[use].strategy=strategy;
}

// Per-trade ledger: the HTML report cannot attribute closed deals to a strategy
// once SL/TP closes them, so the EA writes the attribution itself.
void AppendTradeLedger(const int strategy,const int direction,const double volume,
                       const double entry_price,const double exit_price,
                       const double sl_pts,const double tp_pts,const double entry_spread_pts,
                       const double profit,const double mfe_pts,const double mae_pts,
                       const long age_sec,const string exit_reason)
{
   if(!InpPersistTelemetry) return;
   int h=FileOpen(AccountScopedFile(InpLedgerFile),FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE,';');
   if(h==INVALID_HANDLE) return;
   if(FileSize(h)==0)
      FileWrite(h,"time_close","strategy","direction","volume","entry_price","exit_price",
                "sl_pts","tp_pts","spread_at_entry_pts","profit","mfe_pts","mae_pts",
                "age_sec","exit_reason","atr_pts","regime","session");
   FileSeek(h,0,SEEK_END);
   FileWrite(h,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),StrategyName(strategy),direction,
             DoubleToString(volume,4),DoubleToString(entry_price,_Digits),DoubleToString(exit_price,_Digits),
             DoubleToString(sl_pts,1),DoubleToString(tp_pts,1),DoubleToString(entry_spread_pts,1),
             DoubleToString(profit,2),DoubleToString(mfe_pts,1),DoubleToString(mae_pts,1),
             (string)age_sec,exit_reason,DoubleToString(g_last_atr_pts,1),g_last_regime,g_last_session);
   FileClose(h);
}

void FlushTelemetry()
{
   if(!InpPersistTelemetry || g_event_count<=0) return;
   int h=FileOpen(AccountScopedFile(InpTelemetryFile),FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE,';');
   if(h==INVALID_HANDLE) return;
   if(FileSize(h)==0)
      FileWrite(h,"time","event","ticket","direction","volume","price","slippage_pts","latency_ms","profit","strategy","regime","session","spread","velocity","acceleration","pressure","intensity","persistence","dd");
   FileSeek(h,0,SEEK_END);
   while(g_event_count>0)
   {
      TelemetryEvent e=g_event_queue[g_event_head];
      FileWrite(h,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),e.event_name,(string)e.ticket,e.direction,
                DoubleToString(e.volume,4),DoubleToString(e.price,_Digits),DoubleToString(e.slippage_pts,3),e.latency_ms,
                DoubleToString(e.profit,2),StrategyName(e.strategy),g_last_regime,g_last_session,DoubleToString(g_last_spread_pts,2),
                DoubleToString(g_last_velocity,2),DoubleToString(g_last_acceleration,2),
                DoubleToString(g_last_pressure,3),DoubleToString(g_last_intensity,3),
                DoubleToString(g_last_persistence,3),DoubleToString(CurrentDrawdownPct(),2));
      PrintFormat("OMEGA GATES | inten_gate=%.2f pers_gate=%.2f acc_gate=%.2f disp_gate=%.0f | rej inten=%I64d disp=%I64d pers=%I64d acc=%I64d prob=%I64d edge=%I64d spread=%I64d",
                  GateIntensity(),GatePersistence(),GateAcceleration(),GateDisplacement(g_last_atr_pts),
                  g_rej[REJ_INTENSITY],g_rej[REJ_DISPLACEMENT],g_rej[REJ_PERSISTENCE],
                  g_rej[REJ_ACCELERATION],g_rej[REJ_PROBABILITY],g_rej[REJ_EDGE],g_rej[REJ_SPREAD]);
      ZeroMemory(g_event_queue[g_event_head]);
      g_event_head=(g_event_head+1)%OMEGA_EVENT_CAP;
      g_event_count--;
   }
   FileClose(h);
}

void SaveState(const bool force=false)
{
   if(!InpPersistState) return;
   const long now=NowMilliseconds();
   if(!force && !g_state_dirty) return;
   if(!force && g_last_state_save_ms>0 && now-g_last_state_save_ms<InpStateSaveIntervalSec*1000) return;
   int h=FileOpen(AccountScopedFile(InpStateFile),FILE_WRITE|FILE_CSV|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE,';');
   if(h==INVALID_HANDLE) return;
   FileWrite(h,"X13OMEGA_STATE",2,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS));
   FileWrite(h,"peak_equity",DoubleToString(g_peak_equity,8));
   FileWrite(h,"signal_counter",(string)g_signal_counter);
   FileWrite(h,"total_deals",g_total_deals);
   FileWrite(h,"wins",DoubleToString(g_total_wins,0));
   FileWrite(h,"losses",DoubleToString(g_total_losses,0));
   FileWrite(h,"profit",DoubleToString(g_total_profit,8));
   FileWrite(h,"loss",DoubleToString(g_total_loss,8));
   FileWrite(h,"day_key",(string)g_day_key);
   FileWrite(h,"day_start_equity",DoubleToString(g_day_start_equity,8));
   FileClose(h);
   g_last_state_save_ms=NowMilliseconds();
   g_state_dirty=false;
}

void LoadState()
{
   if(!InpPersistState) return;
   int h=FileOpen(AccountScopedFile(InpStateFile),FILE_READ|FILE_CSV|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE,';');
   if(h==INVALID_HANDLE) return;
   while(!FileIsEnding(h))
   {
      const string key=FileReadString(h);
      if(key=="X13OMEGA_STATE")
      {
         FileReadString(h); FileReadString(h);
      }
      else if(key=="peak_equity") g_peak_equity=FileReadNumber(h);
      else if(key=="signal_counter") g_signal_counter=(ulong)FileReadNumber(h);
      else if(key=="total_deals") g_total_deals=(int)FileReadNumber(h);
      else if(key=="wins") g_total_wins=FileReadNumber(h);
      else if(key=="losses") g_total_losses=FileReadNumber(h);
      else if(key=="profit") g_total_profit=FileReadNumber(h);
      else if(key=="loss") g_total_loss=FileReadNumber(h);
      else if(key=="day_key") g_day_key=(long)FileReadNumber(h);
      else if(key=="day_start_equity") g_day_start_equity=FileReadNumber(h);
      else FileReadString(h);
   }
   FileClose(h);
}

//----------------------------- Reconciliation ----------------------//
void RepairPositionStops(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return;
   if(!InpRepairMissingStops) return;
   const double atr=ATRPoints();
   const double p=PointValue();
   if(atr<=0.0 || p<=0.0) return;

   const long type=PositionGetInteger(POSITION_TYPE);
   const double open=PositionGetDouble(POSITION_PRICE_OPEN);
   const double sl=PositionGetDouble(POSITION_SL);
   const double tp=PositionGetDouble(POSITION_TP);
   if(sl!=0.0 && tp!=0.0) return;

   const double slpts=StopLossPts(atr,CurrentSpreadPts());
   const double tppts=TakeProfitPts(atr,slpts,CurrentSpreadPts());
   double new_sl=sl;
   double new_tp=tp;
   if(type==POSITION_TYPE_BUY)
   {
      if(new_sl==0.0) new_sl=NormalizePrice(open-slpts*p);
      if(new_tp==0.0) new_tp=NormalizePrice(open+tppts*p);
   }
   else
   {
      if(new_sl==0.0) new_sl=NormalizePrice(open+slpts*p);
      if(new_tp==0.0) new_tp=NormalizePrice(open-tppts*p);
   }
   ModifyPositionSLTP(ticket,new_sl,new_tp);
}

void ReconcileState()
{
   int ours=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      const ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      const string sym=PositionGetString(POSITION_SYMBOL);
      const long magic=PositionGetInteger(POSITION_MAGIC);
      if(sym==_Symbol && magic>=(long)InpBaseMagic && magic<=(long)InpBaseMagic+OMEGA_MAGIC_RANGE)
      {
         ours++;
         RepairPositionStops(ticket);
      }
      else if(sym==_Symbol && InpCloseUnknownPositions && magic==0)
      {
         ClosePosition(ticket,"UNKNOWN");
      }
   }

   int pending=0;
   for(int j=OrdersTotal()-1;j>=0;j--)
   {
      const ulong ticket=OrderGetTicket(j);
      if(ticket==0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      const long magic=OrderGetInteger(ORDER_MAGIC);
      if(magic>=(long)InpBaseMagic && magic<=(long)InpBaseMagic+OMEGA_MAGIC_RANGE) pending++;
   }
   PrintFormat("X13 Omega reconciliation: positions=%d pending=%d equity=%.2f DD=%.2f%%",
               ours,pending,AccountInfoDouble(ACCOUNT_EQUITY),CurrentDrawdownPct());
}

bool SameTickBoundary(const MqlTick &a,const MqlTick &b)
{
   return a.time_msc==b.time_msc &&
          a.bid==b.bid && a.ask==b.ask &&
          a.last==b.last && a.volume==b.volume && a.volume_real==b.volume_real &&
          a.flags==b.flags;
}

void UpdateStateFromTick(const MqlTick &t)
{
   PushTick(t);
   g_last_velocity=VelocityTicks(InpFastTicks);
   g_last_velocity_context=VelocityTicks(InpContextTicks);
   g_last_acceleration=AccelerationTicks(InpFastTicks,InpSignalTicks);
   g_last_pressure=PressureWeighted(InpPressureTicks);
   g_last_intensity=TickIntensity();
   g_last_persistence=Persistence(InpPersistenceTicks);
   g_last_dir_persistence_buy=DirectionalPersistence(InpPersistenceTicks,1);
   g_last_dir_persistence_sell=DirectionalPersistence(InpPersistenceTicks,-1);
   g_last_displacement=DisplacementPts(InpSignalTicks);
   g_last_atr_pts=ATRPoints();
   g_last_spread_pts=(t.ask-t.bid)/MathMax(PointValue(),OMEGA_EPS);
   g_last_regime=DetectRegime(g_last_velocity,g_last_acceleration,g_last_persistence,
                              g_last_intensity,g_last_atr_pts,g_last_displacement);
   g_last_session=CurrentSession();
   SampleMarketStats((long)t.time_msc);
}

void UpdateMarketState(const MqlTick &t)
{
   if(!InpUseLiveTickRecovery || MQLInfoInteger(MQL_TESTER))
   {
      UpdateStateFromTick(t);
      g_last_processed_tick_msc=(long)t.time_msc;
      g_last_processed_tick=t;
      g_have_last_processed_tick=true;
      return;
   }

   MqlTick ticks[512];
   ulong from=(g_last_processed_tick_msc>0 ? (ulong)g_last_processed_tick_msc : (ulong)MathMax((long)0,(long)t.time_msc-1));
   const int copied=CopyTicksRange(_Symbol,ticks,COPY_TICKS_ALL,from,(ulong)t.time_msc);
   if(copied<=0)
   {
      UpdateStateFromTick(t);
      g_last_processed_tick_msc=(long)t.time_msc;
      g_last_processed_tick=t;
      g_have_last_processed_tick=true;
      return;
   }

   for(int i=0;i<copied;i++)
   {
      if(g_have_last_processed_tick && ticks[i].time_msc==g_last_processed_tick_msc && SameTickBoundary(ticks[i],g_last_processed_tick))
         continue;
      UpdateStateFromTick(ticks[i]);
      g_last_processed_tick_msc=(long)ticks[i].time_msc;
      g_last_processed_tick=ticks[i];
      g_have_last_processed_tick=true;
   }
   // Execution decisions are made from the latest currently tradable quote,
   // not from a historical recovered tick.
   if(g_last_processed_tick_msc!=(long)t.time_msc || !SameTickBoundary(g_last_processed_tick,t))
   {
      UpdateStateFromTick(t);
      g_last_processed_tick_msc=(long)t.time_msc;
      g_last_processed_tick=t;
      g_have_last_processed_tick=true;
   }
}

//----------------------------- Diagnostics -------------------------//
void PrintHeartbeat()
{
   static long last=0;
   const long now=NowMilliseconds();
   if(now-last<5000) return;
   last=now;
   PrintFormat("OMEGA | session=%d regime=%d spread=%.1f vel=%.1f acc=%.1f pressure=%.2f intensity=%.2f persist=%.2f ATR=%.1f DD=%.2f%% positions=%d lots=%.2f slip=%.2f lat=%.1f degraded=%s",
               g_last_session,g_last_regime,g_last_spread_pts,g_last_velocity,g_last_acceleration,
               g_last_pressure,g_last_intensity,g_last_persistence,g_last_atr_pts,CurrentDrawdownPct(),
               CountOurPositions(),OurLots(),g_avg_slippage_pts,g_avg_latency_ms,(g_execution_degraded?"YES":"NO"));
}

//----------------------------- Events ------------------------------//
int OnInit()
{
   if(!SymbolAllowed())
      PrintFormat("X13 Omega warning: attached symbol=%s, required=%s",_Symbol,InpRequiredSymbol);
   if(InpRequireHedgingAccount && (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("X13 Omega: hedging account required for independent thesis positions.");
      return INIT_FAILED;
   }

   g_peak_equity=AccountInfoDouble(ACCOUNT_EQUITY);
   LoadState();
   if(g_peak_equity<=0.0) g_peak_equity=AccountInfoDouble(ACCOUNT_EQUITY);
   RefreshDailyState();

   const long order_mode=SymbolInfoInteger(_Symbol,SYMBOL_ORDER_MODE);
   if((order_mode & SYMBOL_ORDER_MARKET)==0 || (order_mode & SYMBOL_ORDER_LIMIT)==0)
   {
      Print("X13 Omega: required market/limit order modes are not both available on this symbol.");
      return INIT_FAILED;
   }

   RS_Reset(g_rs_intensity);
   RS_Reset(g_rs_persist);
   RS_Reset(g_rs_absvel);
   RS_Reset(g_rs_absacc);
   RS_Reset(g_rs_absdisp);
   ArrayInitialize(g_rej,0);

   g_atr_handle=iATR(_Symbol,InpATRTimeframe,14);
   if(g_atr_handle==INVALID_HANDLE)
   {
      Print("X13 Omega: ATR handle creation failed.");
      return INIT_FAILED;
   }

   for(int i=0;i<OMEGA_REQ_CAPACITY;i++) ZeroMemory(g_requests[i]);
   for(int j=0;j<OMEGA_SAMPLE_CAPACITY;j++) ZeroMemory(g_samples[j]);
   for(int k=0;k<4;k++) ZeroMemory(g_thesis[k]);

   g_tokens=(double)InpMaxRequestsPerSecond;
   g_last_token_us=NowMicroseconds();

   if(InpReconcileOnInit) ReconcileState();

   EventSetMillisecondTimer(100);
   Print("XTRD OMIGA (Institutional Scalping Engine) initialized.");
   Print("Research principle: maximize net edge density, not raw trade count.");
   return INIT_SUCCEEDED;
}


//----------------------------- Tester Summary ---------------------//
// The HTML report is generated by the terminal and is not always written in
// headless mode, so the EA records the tester statistics itself.
void WriteTesterSummary()
{
   if(!MQLInfoInteger(MQL_TESTER)) return;
   const string fname=AccountScopedFile("X13_Omega_Summary.csv");
   int h=FileOpen(fname,FILE_WRITE|FILE_CSV|FILE_COMMON,';');
   if(h==INVALID_HANDLE)
   {
      PrintFormat("X13 Omega: cannot write %s (err %d)",fname,GetLastError());
      return;
   }
   FileWrite(h,"metric","value");
   FileWrite(h,"initial_deposit",DoubleToString(TesterStatistics(STAT_INITIAL_DEPOSIT),2));
   FileWrite(h,"profit",DoubleToString(TesterStatistics(STAT_PROFIT),2));
   FileWrite(h,"gross_profit",DoubleToString(TesterStatistics(STAT_GROSS_PROFIT),2));
   FileWrite(h,"gross_loss",DoubleToString(TesterStatistics(STAT_GROSS_LOSS),2));
   FileWrite(h,"profit_factor",DoubleToString(TesterStatistics(STAT_PROFIT_FACTOR),4));
   FileWrite(h,"expected_payoff",DoubleToString(TesterStatistics(STAT_EXPECTED_PAYOFF),4));
   FileWrite(h,"recovery_factor",DoubleToString(TesterStatistics(STAT_RECOVERY_FACTOR),4));
   FileWrite(h,"sharpe_ratio",DoubleToString(TesterStatistics(STAT_SHARPE_RATIO),4));
   FileWrite(h,"equity_dd_rel",DoubleToString(TesterStatistics(STAT_EQUITY_DDREL_PERCENT),2));
   FileWrite(h,"equity_dd_abs",DoubleToString(TesterStatistics(STAT_EQUITY_DD),2));
   FileWrite(h,"balance_dd_rel",DoubleToString(TesterStatistics(STAT_BALANCE_DDREL_PERCENT),2));
   FileWrite(h,"trades",DoubleToString(TesterStatistics(STAT_TRADES),0));
   FileWrite(h,"profit_trades",DoubleToString(TesterStatistics(STAT_PROFIT_TRADES),0));
   FileWrite(h,"loss_trades",DoubleToString(TesterStatistics(STAT_LOSS_TRADES),0));
   FileWrite(h,"short_trades",DoubleToString(TesterStatistics(STAT_SHORT_TRADES),0));
   FileWrite(h,"long_trades",DoubleToString(TesterStatistics(STAT_LONG_TRADES),0));
   FileWrite(h,"avg_profit_trade",DoubleToString(TesterStatistics(STAT_GROSS_PROFIT)/MathMax(1.0,TesterStatistics(STAT_PROFIT_TRADES)),4));
   FileWrite(h,"avg_loss_trade",DoubleToString(TesterStatistics(STAT_GROSS_LOSS)/MathMax(1.0,TesterStatistics(STAT_LOSS_TRADES)),4));
   FileWrite(h,"max_profit_trade",DoubleToString(TesterStatistics(STAT_MAX_PROFITTRADE),2));
   FileWrite(h,"max_loss_trade",DoubleToString(TesterStatistics(STAT_MAX_LOSSTRADE),2));
   for(int i=0;i<REJ_COUNT;i++)
      FileWrite(h,"rej_"+g_rej_names[i],(string)g_rej[i]);
   FileWrite(h,"equity",DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2));
   FileWrite(h,"margin",DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN),2));
   FileWrite(h,"margin_util",DoubleToString(MarginUtilization(),4));
   FileWrite(h,"volume_min",DoubleToString(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),3));
   FileWrite(h,"leverage",(string)AccountInfoInteger(ACCOUNT_LEVERAGE));
   FileWrite(h,"spread_pts_last",DoubleToString(g_last_spread_pts,1));
   FileWrite(h,"atr_pts_last",DoubleToString(g_last_atr_pts,1));
   FileWrite(h,"sl_pts",DoubleToString(StopLossPts(g_last_atr_pts,g_last_spread_pts),1));
   FileWrite(h,"tp_pts",DoubleToString(TakeProfitPts(g_last_atr_pts,StopLossPts(g_last_atr_pts,g_last_spread_pts),g_last_spread_pts),1));
   FileWrite(h,"gate_intensity",DoubleToString(GateIntensity(),3));
   FileWrite(h,"gate_persistence",DoubleToString(GatePersistence(),3));
   FileWrite(h,"gate_acceleration",DoubleToString(GateAcceleration(),3));
   FileWrite(h,"gate_displacement",DoubleToString(GateDisplacement(g_last_atr_pts),1));
   FileWrite(h,"p70_intensity",DoubleToString(g_rs_intensity.p70,3));
   FileWrite(h,"p70_persist",DoubleToString(g_rs_persist.p70,3));
   FileWrite(h,"p50_absacc",DoubleToString(g_rs_absacc.p50,3));
   FileWrite(h,"p60_absdisp",DoubleToString(g_rs_absdisp.p60,1));
   FileWrite(h,"p90_intensity",DoubleToString(g_rs_intensity.p90,3));
   FileWrite(h,"max_intensity",DoubleToString(g_intensity_max,3));
   FileWrite(h,"min_intensity",DoubleToString(g_intensity_min==DBL_MAX ? 0.0 : g_intensity_min,3));
   FileWrite(h,"rate_ewma",DoubleToString(g_rate_ewma,3));
   FileWrite(h,"last_check_retcode",(string)g_last_check_retcode);
   FileWrite(h,"check_advisory_override",(string)g_check_advisory_override);
   FileWrite(h,"max_affordable_stop",DoubleToString(MaxAffordableStopPts(),1));
   FileWrite(h,"p50_confidence",DoubleToString(g_rs_confidence.p50,4));
   FileWrite(h,"p60_confidence",DoubleToString(g_rs_confidence.p60,4));
   FileWrite(h,"p90_confidence",DoubleToString(g_rs_confidence.p90,4));
   FileWrite(h,"ticks_seen",(string)g_count);
   FileWrite(h,"ea_deals",(string)g_total_deals);
   FileClose(h);
   PrintFormat("X13 Omega: tester summary written to %s",fname);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   SyncDeals(true);
   SaveState(true);
   FlushTelemetry();
   WriteTesterSummary();
   if(g_atr_handle!=INVALID_HANDLE) IndicatorRelease(g_atr_handle);
   PrintFormat("X13 Omega stopped. deals=%d DD=%.2f%% avg_slip=%.2f avg_latency=%.1fms profit=%.2f",
               g_total_deals,CurrentDrawdownPct(),AvgSlippage(),AvgLatency(),g_total_profit+g_total_loss);
}

void OnTick()
{
   MqlTick t;
   if(!SymbolInfoTick(_Symbol,t)) return;
   if(InpOnlySymbol && !SymbolAllowed()) return;

   UpdateMarketState(t);

   if(IsRollover())
   {
      if(InpCancelPendingRollover) CancelOurPending();
      ManagePositions();
      g_last_tick_msc=(long)t.time_msc;
      return;
   }

   ManagePositions();
   SyncDeals();
   RepriceLimits();
   PurgeOldRequests();
   RouteSignals();
   PrintHeartbeat();
   g_last_tick_msc=(long)t.time_msc;
}

void OnTimer()
{
   RefillTokens();
   PurgeOldRequests();
   PurgePositionControls();
   if(IsRollover() && InpCancelPendingRollover) CancelOurPending();
   const long now=NowMilliseconds();
   if(now-g_last_telemetry_flush_ms>=InpTelemetryFlushIntervalMs)
   {
      FlushTelemetry();
      g_last_telemetry_flush_ms=now;
   }
   SaveState(false);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   // Request/order transaction telemetry is intentionally handled here because
   // OrderSendAsync() returns before the server has completed the operation.
   if(trans.type==TRADE_TRANSACTION_REQUEST)
   {
      if(result.request_id!=0)
      {
         const int slot=FindRequestById(result.request_id);
         if(slot>=0)
         {
            if(result.order!=0) g_requests[slot].order_ticket=result.order;
            if(result.deal!=0) g_requests[slot].position_ticket=result.deal;
         }
         if(slot>=0 && result.retcode!=TRADE_RETCODE_PLACED &&
            result.retcode!=TRADE_RETCODE_DONE && result.retcode!=TRADE_RETCODE_DONE_PARTIAL)
         {
            QueueTelemetry("REQUEST_REJECT",0,g_requests[slot].direction,g_requests[slot].volume,
                           g_requests[slot].requested_price,0.0,
                           (NowMicroseconds()-g_requests[slot].sent_us)/1000,0.0,
                           g_requests[slot].strategy);
            ClearRequest(slot);
         }
      }
      return;
   }

   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   const ulong deal=trans.deal;
   if(deal==0) return;
   if(HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol) return;

   const long magic=HistoryDealGetInteger(deal,DEAL_MAGIC);
   if(magic<(long)InpBaseMagic || magic>(long)InpBaseMagic+OMEGA_MAGIC_RANGE) return;

   const double price=HistoryDealGetDouble(deal,DEAL_PRICE);
   const double volume=HistoryDealGetDouble(deal,DEAL_VOLUME);
   const double profit=HistoryDealGetDouble(deal,DEAL_PROFIT)+
                       HistoryDealGetDouble(deal,DEAL_SWAP)+
                       HistoryDealGetDouble(deal,DEAL_COMMISSION);
   const long deal_type=HistoryDealGetInteger(deal,DEAL_TYPE);
   const int direction=(deal_type==DEAL_TYPE_BUY ? 1 : -1);
   const int strategy=ClampI((int)(magic-(long)InpBaseMagic),1,3);
   const double point=PointValue();

   double requested=price;
   double slip=0.0;
   long latency=0;
   int slot=-1;
   if(trans.order!=0)
   {
      for(int qi=0;qi<OMEGA_REQ_CAPACITY;qi++)
      {
         if(g_requests[qi].active && g_requests[qi].order_ticket==trans.order) { slot=qi; break; }
      }
   }
   if(slot<0 && trans.position!=0)
   {
      for(int qi=0;qi<OMEGA_REQ_CAPACITY;qi++)
      {
         if(g_requests[qi].active && g_requests[qi].position_ticket==trans.position) { slot=qi; break; }
      }
   }
   if(slot>=0)
   {
      requested=g_requests[slot].requested_price;
      latency=(NowMicroseconds()-g_requests[slot].sent_us)/1000;
      if(point>0.0 && requested>0.0)
         slip=(price-requested)/point*(direction>0?1.0:-1.0);
   }

   const long deal_entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
   const bool is_exit=(deal_entry==DEAL_ENTRY_OUT || deal_entry==DEAL_ENTRY_OUT_BY || deal_entry==DEAL_ENTRY_INOUT);
   if(is_exit)
   {
      const ulong pos_ticket=trans.position;
      const int pc=FindPositionControl(pos_ticket);
      double entry_price=0.0,sl_pts=0.0,tp_pts=0.0,entry_spread=0.0,mfe=0.0,mae=0.0;
      long age=0;
      int ctrl_strategy=strategy;
      if(pc>=0)
      {
         entry_price=g_pos_ctrl[pc].entry_price;
         sl_pts=g_pos_ctrl[pc].sl_pts;
         tp_pts=g_pos_ctrl[pc].tp_pts;
         entry_spread=g_pos_ctrl[pc].entry_spread_pts;
         mfe=g_pos_ctrl[pc].mfe_pts;
         mae=g_pos_ctrl[pc].mae_pts;
         if(g_pos_ctrl[pc].strategy>=1) ctrl_strategy=g_pos_ctrl[pc].strategy;
         if(g_pos_ctrl[pc].entry_msc>0)
            age=(long)((NowMilliseconds()-g_pos_ctrl[pc].entry_msc)/1000);
         g_pos_ctrl[pc].close_pending=false;
      }
      if(entry_price<=0.0 && slot>=0) entry_price=g_requests[slot].requested_price;
      AppendTradeLedger(ctrl_strategy,direction,volume,entry_price,price,sl_pts,tp_pts,
                         entry_spread,profit,mfe,mae,age,HistoryDealGetString(deal,DEAL_COMMENT));
      AddDealSample(MathAbs(slip),profit,volume,latency,direction,ctrl_strategy);
   }
   QueueTelemetry("DEAL",deal,direction,volume,price,slip,latency,profit,strategy);
   if(slot>=0 && is_exit)
      ClearRequest(slot);
}
//+------------------------------------------------------------------+
