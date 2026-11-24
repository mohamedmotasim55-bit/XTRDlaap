//+------------------------------------------------------------------+
//| XTRD_OMIGA_InstantMomentum_v3.00.mq5                      |
//|                                                                  |
//| INSTANT MOMENTUM ENGINE - MICRO / SHORT / EXPANSION              |
//|                                                                  |
//| Architecture:                                                   |
//|  Fixed-memory tick engine                                       |
//|  Tick-step velocity / acceleration                              |
//|  Tick-intensity regime detection                                |
//|  Persistence + pressure proxy                                   |
//|  Micro momentum capture                                        |
//|  Short momentum continuation                                    |
//|  Expansion momentum capture                                     |
//|  Market execution dispatcher                                    |
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
#property version   "3.00"
#property description "XTRD OMIGA 2 - tick-driven instant momentum scalper (M1)"
// v3.00 development branch based on the user's v2.27 file.
// Three independent momentum horizons share one tick-driven signal engine.
// Legacy strategies are removed from routing; original v2.27 is left untouched.
// Signal-only mode is ON by default. Min-lot override logic is removed entirely.
// The probability score is heuristic, not a calibrated win probability.

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
#define OMEGA_STRAT_COUNT          3
#define OMEGA_FILTER_STAGE_COUNT   17
#define OMEGA_GLOBAL_GATE_COUNT    10
#define OMEGA_REGIME_COUNT         7
#define OMEGA_SESSION_COUNT        6
#define OMEGA_POSMETA_CAP          64

//----------------------------- Enums -------------------------------//
enum ENUM_OMEGA_STRATEGY
{
   STRAT_MICRO_MOMENTUM     = 1,
   STRAT_SHORT_MOMENTUM     = 2,
   STRAT_EXPANSION_MOMENTUM = 3
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
   int      regime;
   int      session;
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
   double initial_sl_pts;
   long   entry_msc;
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
};


struct PosMeta
{
   bool   active;
   ulong  ticket;
   int    strategy;
   int    regime;
   int    session;
   double realized;
};

//----------------------------- Inputs ------------------------------//
input group "NEWS FILTER / PROTECTION"
input bool   InpEnableNewsFilter           = false; // Static clock blackouts only; NOT a live economic calendar
input int    InpNewsPreHaltMin             = 3;
input int    InpNewsPostResumeMin          = 2;

input group "CORE"
input ulong  InpBaseMagic                  = 1310001; // Separate magic range from v2.27
input bool   InpEnableTrading              = false; // Must be explicitly enabled for tester/demo order execution.
input bool   InpSignalOnlyMode              = true;  // Records candidate momentum signals without sending orders.
input int    InpSignalLogEveryN              = 20;    // Log one in N accepted signal events per engine.
input bool   InpOnlySymbol                 = true;
input string InpRequiredSymbol             = "XAUUSD";
input bool   InpAllowSuffixSymbols         = true;
input bool   InpAllowMultipleStrategies   = true;

input group "TICK ENGINE"
input int    InpFastTicks                  = 20;
input int    InpSignalTicks                = 50;
input int    InpContextTicks               = 100;
input int    InpMinTicksBeforeSignal       = 120;
input double InpMinEffectiveDtMs           = 0.10; // Retained for .set compatibility; zero-time gaps are no longer fabricated
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

input group "STRATEGY 2 - INSTANT MOMENTUM ENGINES"
input bool   InpEnableMicroMomentum          = true;
input bool   InpEnableShortMomentum          = true;
input bool   InpEnableExpansionMomentum      = true;

// Individual research switches. Disabling a switch bypasses that strategy filter only.
input bool   InpUseVelocityFilter             = true;
input bool   InpUseAccelerationFilter         = false;
input bool   InpUsePersistenceFilter          = true;
input bool   InpUseIntensityFilter            = true;
input bool   InpUseDisplacementFilter         = true;
input bool   InpUsePressureFilter             = false;
input bool   InpUseRegimeFilter               = false;
input bool   InpUseDirectionalScoreFilter     = false;
input bool   InpUseContextOppositionFilter    = true;
input bool   InpUseSpreadExpansionFilter      = true;
input bool   InpUseExpectancyGate             = false; // Heuristic score is not calibrated until out-of-sample testing
input bool   InpUseExtremeVelocityGuard       = true;  // Safety guard; independent of strategy strictness
input double InpEmergencyMaxVelocityPtsSec    = 2500.0;
input double InpAbsoluteMaxVelocityPtsSec     = 6000.0; // Always-on hard guard, even when the optional strict guard is disabled.
input double InpEmergencyMaxSpreadPts         = 150.0;  // Hard safety ceiling; not disabled by other filter switches
input double InpMomentumContextOppositionMax  = 25.0;
input double InpMinimumTargetCostMultiple     = 1.50;
input double InpMinimumExpectancyPts          = 0.0;

// Three momentum horizons: thresholds are initial research defaults, not optimized parameters.
input double InpMicroVelocityMinPtsSec        = 8.0;
input double InpMicroAccelerationMinPtsSec2   = 0.20;
input double InpMicroPersistenceMin           = 0.52;
input double InpMicroIntensityMin             = 1.05;
input double InpMicroDisplacementMinPts       = 0.50;
input double InpMicroPressureMinPts           = 0.00;
input double InpMicroScoreMin                 = 0.51;
input double InpMicroSL_ATR                   = 0.55;
input double InpMicroRewardRisk               = 1.15;
input double InpMicroTrailActivationR         = 0.40;
input double InpMicroTrailDistanceATR         = 0.30;

input double InpShortVelocityMinPtsSec        = 20.0;
input double InpShortAccelerationMinPtsSec2   = 0.50;
input double InpShortPersistenceMin           = 0.58;
input double InpShortIntensityMin             = 1.20;
input double InpShortDisplacementMinPts       = 2.00;
input double InpShortPressureMinPts           = 0.00;
input double InpShortScoreMin                 = 0.53;
input double InpShortSL_ATR                   = 0.80;
input double InpShortRewardRisk               = 1.45;
input double InpShortTrailActivationR         = 0.60;
input double InpShortTrailDistanceATR         = 0.45;

input double InpExpansionVelocityMinPtsSec    = 40.0;
input double InpExpansionAccelerationMinPtsSec2= 1.00;
input double InpExpansionPersistenceMin        = 0.65;
input double InpExpansionIntensityMin          = 1.40;
input double InpExpansionDisplacementMinPts    = 5.00;
input double InpExpansionPressureMinPts        = 0.00;
input double InpExpansionScoreMin              = 0.55;
input double InpExpansionSL_ATR                = 1.05;
input double InpExpansionRewardRisk            = 1.90;
input double InpExpansionTrailActivationR      = 0.80;
input double InpExpansionTrailDistanceATR      = 0.65;

input group "BAYESIAN / CONDITIONAL GATES"
input double InpBayesPrior                 = 0.50; // Heuristic score prior; not a calibrated win probability
input double InpBayesWeightVelocity        = 0.28;
input double InpBayesWeightAcceleration     = 0.18;
input double InpBayesWeightPressure        = 0.18;
input double InpBayesWeightPersistence     = 0.16;
input double InpBayesWeightIntensity       = 0.10;
input double InpBayesWeightDisplacement    = 0.10;
input double InpExpectedOneWaySlippagePts    = 8.0; // Initial prior; rolling measured slippage takes over when available

input group "SPREAD / EXECUTION"
input double InpMaxSpreadPts               = 100.0;
input double InpBaselineSpreadPts          = 25.0;
input double InpSpreadExpansionMaxPts      = 80.0; // Adaptive operating ceiling; broker/order checks remain active
input int    InpMaxRequestsPerSecond       = 5;
input double InpTokenRefillPerSecond      = 5.0;
input double InpMaxSlippagePts             = 40.0;
input double InpBadSlippagePts             = 25.0;
input int    InpExecutionLatencyMs         = 50;
input int    InpTelemetryWindow            = 16;
input bool   InpAdaptiveExecution           = true;
input int    InpMarketRetryMs              = 250;
input int    InpLimitExpirySec             = 5;
input int    InpMaxPendingOrders            = 8;
input int    InpLimitDistancePts            = 8;
input double InpLimitRepriceTriggerPts     = 3.0;
input int    InpMaxRepricesPerOrder        = 3;
input int    InpRepriceCooldownMs           = 250;
input int    InpPositionModifyCooldownMs    = 150;
input bool   InpUseOrderCheck              = true;
input bool   InpUseExecutionStateMachine   = true;

input group "RISK / COMPOUNDING"
input bool   InpUseHalfPercentRiskProfile   = true;  // ON: uses InpInitialRiskPct (default 0.50%). OFF: uses alternate risk below.
input double InpRiskPctWhenHalfPercentOff   = 1.00;  // Still capped by InpMaxAccountRiskPct.
input double InpInitialRiskPct             = 0.50;
input double InpMaxAccountRiskPct          = 1.00;
input double InpHardDrawdownPct            = 15.0; // Kill switch: no new entries beyond this drawdown from peak equity
input double InpDrawdownSoftZonePct        = 0.70;
input double InpMarginUtilizationMax       = 0.0;  // 0 = no arbitrary utilization ceiling; broker feasibility still checked
input double InpFreeMarginFloorPct         = 2.0;  // small operational reserve, not a strategy throttle
input double InpPortfolioRiskCapPct        = 20.0; // aggregate modeled open + pending risk ceiling
input double InpLotCap                     = 10.00;
input double InpVolatilityReferenceATR     = 100.0;
input double InpVolatilityDragFloor        = 0.20;
input double InpVolatilityDragCeiling      = 1.00;
input bool   InpUseFractionalKellyBoost    = false;
input double InpKellyFraction              = 0.25;
input double InpKellyBoostCap              = 1.25;
input bool   InpEnableAdaptiveAggression   = true;
input double InpAggressionMin              = 0.10;
input double InpAggressionMax              = 1.00;
input double InpDailyLossLimitPct          = 5.0; // No new entries after this daily equity loss (0 = off)
input int    InpStatsWarmupDeals           = 50;
input bool   InpUseEmpiricalCVaR            = true;
input double InpCVaRAlpha                   = 0.10;
input double InpCVaRSoftPct                = 4.0;
input double InpCVaRHardPct                = 8.0;

input group "PORTFOLIO / THESIS ISOLATION"
input int    InpMaxConcurrentPositions     = 6; // Dynamic equity-scaled ceiling, not a fixed target
input int    InpMaxSameDirectionPositions  = 6;
input double InpMaxPortfolioLots           = 10.00;
input double InpMaxPortfolioDeltaLots      = 10.00;
input bool   InpRejectDuplicatePending     = true;
input int    InpDuplicateWindowMs          = 150;
input int    InpStrategyCooldownMs         = 20;

input group "STOPS / POSITION MANAGEMENT"
input double InpMinSLPts                   = 32.0;
input double InpMaxSLPts                   = 1200.0;
input double InpMinTPPts                   = 32.0;
input double InpMaxTPPts                   = 2400.0;
input double InpBEExtraPts                 = 2.0;
input bool   InpUseMicroBreakEven           = true;
input double InpBEStage1TriggerPts          = 5.5;  // Actual trigger is max(this floor, expected slip x cost multiple)
input double InpBEStage1LockPts             = 1.8;
input double InpBEStage2TriggerPts          = 10.0; // Actual trigger is max(this floor, expected slip x cost multiple)
input double InpBEStage2LockPts             = 4.5;
input double InpBEStage1TriggerCostMultiple   = 2.0;
input double InpBEStage1LockCostMultiple      = 1.0;
input double InpBEStage2TriggerCostMultiple   = 3.0;
input double InpBEStage2LockCostMultiple      = 2.0;
input bool   InpUseSpreadMomentumGate       = true; // Rejects entries if spread is actively expanding
input double InpSpreadMomentumThresholdPts  = 2.0;
input bool   InpUseVelocityTrailing         = true;
input double InpTrailVelocityStrong         = 100.0;
input double InpTrailVelocityWeak           = 20.0;
input double InpTrailStrongATR              = 0.80;
input double InpTrailWeakATR                = 0.30;
input int    InpMaxTradeAgeSec              = 240;
input double InpStallVelocityPtsSec         = 3.0;
input double InpStallProfitFloorPts         = 0.0;
input bool   InpCloseStalledTrades          = true;
input bool   InpEnablePartialClose           = false; // Disabled by default; usually impossible at 0.01 lot
input double InpPartialCloseTrigger          = 0.50;
input double InpPartialClosePercent          = 0.60;
input bool   InpEnableMFE_MAE                = true;

input group "ONLINE LEARNING / LOSS-STREAK GOVERNOR"
input bool   InpAutoLearn                  = true;   // Learn edge per strategy x regime x session
input int    InpLearnMinTrades             = 25;     // Samples before a bucket can stand down
input double InpLearnPriorTrades           = 15.0;   // Shrinkage pseudo-count
input double InpLearnStrength              = 1.00;   // Influence of learned edge on size and rank
input double InpLearnDisableScore          = -0.25;  // Shrunk edge at/below this stands bucket down
input double InpLearnDailyDecay            = 0.90;   // Daily forgetting factor (1.0 = never forget)
input int    InpMaxConsecLosses            = 5;      // Losing streak that triggers cooldown
input int    InpConsecLossCooldownMin      = 20;     // Cooldown length in minutes
input int    InpMaxTradesPerDay            = 0;      // 0 = unlimited
input group "SESSION ROUTER - GMT"
input bool   InpUseSessionEngine             = true;
input bool   InpUseSessionEngineInTester       = false;
input int    InpTesterGMTOffsetHours          = 0; // Add this to tester server time to obtain GMT; set only from broker history
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
input bool   InpAsiaEnableMomentum          = true;
input bool   InpLondonEnableMomentum        = true;
input bool   InpOverlapEnableMomentum       = true;
input bool   InpLateEnableMomentum          = true;
input bool   InpCancelPendingRollover       = true;

input group "RESILIENCE / STATE"
input bool   InpReconcileOnInit             = true;
input bool   InpCloseUnknownPositions       = false;
input bool   InpRepairMissingStops          = true;
input bool   InpPersistState                = true;
input bool   InpPersistTelemetry            = true;
input string InpStateFile                   = "XTRD_OMIGA2_State.csv";
input string InpTelemetryFile               = "XTRD_OMIGA2_Telemetry.csv";
input int    InpStateSaveIntervalSec        = 30;
input int    InpTelemetryFlushIntervalMs    = 1000;
input bool   InpUseLiveTickRecovery         = true;
input bool   InpRequireHedgingAccount        = true;
input string InpCommentPrefix               = "XTRD2";

//----------------------------- Globals -----------------------------//
TickNode g_ticks[OMEGA_TICK_CAPACITY];
RequestTrack g_requests[OMEGA_REQ_CAPACITY];
DealSample g_samples[OMEGA_SAMPLE_CAPACITY];
ThesisState g_thesis[5];

int g_head=-1;
int g_count=0;
int g_sample_count=0;
int g_sample_head=0;
int g_atr_handle=INVALID_HANDLE;

ulong g_signal_counter=0;
ulong g_local_request_counter=0;
long g_last_tick_msc=0;
long g_last_signal_msc[5]={0,0,0,0,0};
long g_last_strategy_trade_msc[5]={0,0,0,0,0};
long g_last_signal_fingerprint[5]={0,0,0,0,0};

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
// online learning state (v3.00)
PosMeta g_posmeta[OMEGA_POSMETA_CAP];
double  g_bk_n[OMEGA_STRAT_COUNT][OMEGA_REGIME_COUNT][OMEGA_SESSION_COUNT];
double  g_bk_sum[OMEGA_STRAT_COUNT][OMEGA_REGIME_COUNT][OMEGA_SESSION_COUNT];
double  g_bk_abs[OMEGA_STRAT_COUNT][OMEGA_REGIME_COUNT][OMEGA_SESSION_COUNT];
int     g_consec_losses=0;
datetime g_cooldown_until=0;
int     g_trades_today=0;
long    g_learn_day_key=0;
int g_rej_stage[8]={0,0,0,0,0,0,0,0};
long g_filter_reached[OMEGA_STRAT_COUNT][OMEGA_FILTER_STAGE_COUNT];
long g_filter_passed[OMEGA_STRAT_COUNT][OMEGA_FILTER_STAGE_COUNT];
long g_filter_rejected[OMEGA_STRAT_COUNT][OMEGA_FILTER_STAGE_COUNT];
long g_signal_attempts[OMEGA_STRAT_COUNT];
long g_signal_accepted[OMEGA_STRAT_COUNT];
long g_signal_only_logged[OMEGA_STRAT_COUNT];
long g_lot_rejected[OMEGA_STRAT_COUNT];
long g_portfolio_rejected[OMEGA_STRAT_COUNT];
long g_global_gate_reached[OMEGA_GLOBAL_GATE_COUNT];
long g_global_gate_passed[OMEGA_GLOBAL_GATE_COUNT];
long g_global_gate_rejected[OMEGA_GLOBAL_GATE_COUNT];

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

datetime OmegaGMTTime()
{
   if(MQLInfoInteger(MQL_TESTER))
      return (datetime)(TimeCurrent()+(long)InpTesterGMTOffsetHours*3600L);
   return TimeGMT();
}

long DayKeyGMT()
{
   MqlDateTime dt;
   TimeToStruct(OmegaGMTTime(),dt);
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
   TimeToStruct(OmegaGMTTime(),dt);
   return dt.hour;
}

int GMT_MinuteOfDay()
{
   MqlDateTime dt;
   TimeToStruct(OmegaGMTTime(),dt);
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
   if(MQLInfoInteger(MQL_TESTER) && !InpUseSessionEngineInTester) return SESSION_OVERLAP;
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

   string required_upper = InpRequiredSymbol;
   StringToUpper(required_upper);
   if(required_upper=="") required_upper="XAUUSD";
   if(symbol_upper==required_upper) return true;
   if(InpAllowSuffixSymbols && StringFind(symbol_upper,required_upper,0)>=0) return true;
   return false;
}

//----------------------------- Ring Buffer -------------------------//
void PushTick(const MqlTick &t)
{
   g_head=(g_head+1)%OMEGA_TICK_CAPACITY;
   const double p=PointValue();
   const double vol=(t.volume_real>0.0 ? t.volume_real : 1.0);
   g_ticks[g_head].bid=t.bid;
   g_ticks[g_head].ask=t.ask;
   g_ticks[g_head].mid=(t.bid+t.ask)*0.5;
   g_ticks[g_head].spread_pts=(p>0.0 ? (t.ask-t.bid)/p : 0.0);
   g_ticks[g_head].volume=MathMax(vol,1.0);
   g_ticks[g_head].time_msc=(long)t.time_msc;
   if(g_count<OMEGA_TICK_CAPACITY) g_count++;
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
   return (raw>0.0 ? raw : 0.0);
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
   const double dt=(dt1+dt2)*0.5;
   if(dt<=0.0) return 0.0;
   return ClampD((v1-v2)/dt,-InpMaxAccelerationPtsSec2,InpMaxAccelerationPtsSec2);
}

double TickIntensity()
{
   if(g_count<10) return 0.0;
   const int n=ClampI(InpIntensityLookback,5,g_count-1);
   TickNode now,old;
   if(!GetBackTick(0,now) || !GetBackTick(n,old)) return 0.0;
   const double current_dt=EffectiveDtMs(now.time_msc,old.time_msc)/OMEGA_MS_PER_SEC;
   if(current_dt<=0.0) return 0.0;
   const double current=(double)n/current_dt;

   const int seg=MathMax(2,MathMin(20,n/2));
   double baseline_sum=0.0;
   int samples=0;
   for(int k=seg;k<=n;k+=seg)
   {
      TickNode x,y;
      if(!GetBackTick(k-seg,x) || !GetBackTick(k,y)) continue;
      const double dt=EffectiveDtMs(x.time_msc,y.time_msc)/OMEGA_MS_PER_SEC;
      if(dt>0.0)
      {
         baseline_sum+=(double)seg/dt;
         samples++;
      }
   }
   const double baseline=(samples>0 ? baseline_sum/samples : current);
   if(baseline<=OMEGA_EPS) return 0.0;
   return ClampD(current/baseline,0.0,100.0);
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

   // Weighted logistic directional score. This is a heuristic score, NOT a
   // calibrated posterior or verified win probability; calibration must be
   // performed on chronologically held-out fills before interpreting it as one.
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
   if(strategy<1 || strategy>OMEGA_STRAT_COUNT) return false;
   if(!InpUseSessionEngine) return true;
   if(session==SESSION_ROLLOVER) return false;
   if(session==SESSION_OFF) return !InpDisableSignalsOffSession;
   if(session==SESSION_ASIA) return InpAsiaEnableMomentum;
   if(session==SESSION_LONDON) return InpLondonEnableMomentum;
   if(session==SESSION_OVERLAP) return InpOverlapEnableMomentum;
   if(session==SESSION_US_LATE) return InpLateEnableMomentum;
   return false;
}

double ExpectedOneWaySlippagePts()
{
   return MathMax(MathMax(0.0,InpExpectedOneWaySlippagePts),MathMax(0.0,g_avg_slippage_pts));
}


//----------------------------- Online Learning ---------------------//
// Learns per (strategy x regime x session) bucket from realized net profit.
// Edge is scale-free: sum(profit)/sum(|profit|) in [-1,1], shrunk toward zero
// by n/(n+prior). A bucket whose shrunk edge is clearly negative after enough
// trades stands down. A daily forgetting factor lets it re-earn activity later.
bool BucketIndexOK(const int strategy,const int regime,const int session)
{
   return (strategy>=1 && strategy<=OMEGA_STRAT_COUNT &&
           regime>=0 && regime<OMEGA_REGIME_COUNT &&
           session>=0 && session<OMEGA_SESSION_COUNT);
}

double BucketShrunkEdge(const int strategy,const int regime,const int session)
{
   if(!BucketIndexOK(strategy,regime,session)) return 0.0;
   const int si=strategy-1;
   const double n=g_bk_n[si][regime][session];
   const double den=g_bk_abs[si][regime][session];
   if(n<=0.0 || den<=OMEGA_EPS) return 0.0;
   const double raw=g_bk_sum[si][regime][session]/den;
   return raw*n/(n+MathMax(1.0,InpLearnPriorTrades));
}

bool BucketDisabled(const int strategy,const int regime,const int session)
{
   if(!InpAutoLearn || !BucketIndexOK(strategy,regime,session)) return false;
   if(g_bk_n[strategy-1][regime][session]<(double)InpLearnMinTrades) return false;
   return (BucketShrunkEdge(strategy,regime,session)<=InpLearnDisableScore);
}

double BucketWeight(const int strategy,const int regime,const int session)
{
   if(!InpAutoLearn || !BucketIndexOK(strategy,regime,session)) return 1.0;
   return ClampD(1.0+InpLearnStrength*BucketShrunkEdge(strategy,regime,session),0.25,1.25);
}

void LearnFromClosedTrade(const int strategy,const int regime,const int session,const double realized)
{
   if(BucketIndexOK(strategy,regime,session))
   {
      const int si=strategy-1;
      g_bk_n[si][regime][session]+=1.0;
      g_bk_sum[si][regime][session]+=realized;
      g_bk_abs[si][regime][session]+=MathAbs(realized);
   }
   if(realized<0.0) g_consec_losses++;
   else if(realized>0.0) g_consec_losses=0;
   if(InpMaxConsecLosses>0 && g_consec_losses>=InpMaxConsecLosses)
      g_cooldown_until=(datetime)((long)TimeCurrent()+(long)MathMax(1,InpConsecLossCooldownMin)*60L);
   g_state_dirty=true;
}

// Account-protection governor: a losing streak halves size, and a long streak
// pauses new entries for a fixed time. Uses broker/tester time, not wall clock.
bool GovernorBlocked()
{
   if(g_cooldown_until<=0) return false;
   if(TimeCurrent()<g_cooldown_until) return true;
   g_cooldown_until=0;   // cooldown served: restart the streak count
   g_consec_losses=0;
   g_state_dirty=true;
   return false;
}

double GovernorRiskMultiplier()
{
   if(g_consec_losses>=3) return 0.50;
   if(g_consec_losses>=2) return 0.75;
   return 1.00;
}

bool DailyTradeCapReached()
{
   return (InpMaxTradesPerDay>0 && g_trades_today>=InpMaxTradesPerDay);
}

void MaintainLearning()
{
   const long key=DayKeyGMT();
   if(key==g_learn_day_key) return;
   g_learn_day_key=key;
   g_trades_today=0;
   if(InpAutoLearn && InpLearnDailyDecay>0.0 && InpLearnDailyDecay<1.0)
   {
      for(int s=0;s<OMEGA_STRAT_COUNT;s++)
      {
         for(int r=0;r<OMEGA_REGIME_COUNT;r++)
         {
            for(int e=0;e<OMEGA_SESSION_COUNT;e++)
            {
               g_bk_n[s][r][e]*=InpLearnDailyDecay;
               g_bk_sum[s][r][e]*=InpLearnDailyDecay;
               g_bk_abs[s][r][e]*=InpLearnDailyDecay;
            }
         }
      }
   }
   g_state_dirty=true;
}

int FindPosMeta(const ulong ticket)
{
   if(ticket==0) return -1;
   for(int i=0;i<OMEGA_POSMETA_CAP;i++)
      if(g_posmeta[i].active && g_posmeta[i].ticket==ticket) return i;
   return -1;
}

void RegisterOpenedPosition(const ulong ticket,const int strategy,const int regime,const int session)
{
   if(ticket==0 || FindPosMeta(ticket)>=0) return;
   for(int i=0;i<OMEGA_POSMETA_CAP;i++)
   {
      if(g_posmeta[i].active) continue;
      g_posmeta[i].active=true;
      g_posmeta[i].ticket=ticket;
      g_posmeta[i].strategy=strategy;
      g_posmeta[i].regime=regime;
      g_posmeta[i].session=session;
      g_posmeta[i].realized=0.0;
      return;
   }
}

void AccumulateClosedDeal(const ulong position,const double profit)
{
   const int idx=FindPosMeta(position);
   if(idx<0) return;
   g_posmeta[idx].realized+=profit;
   if(PositionSelectByTicket(position)) return;   // partial exit: trade still open
   LearnFromClosedTrade(g_posmeta[idx].strategy,g_posmeta[idx].regime,
                        g_posmeta[idx].session,g_posmeta[idx].realized);
   ZeroMemory(g_posmeta[idx]);
}

//----------------------------- Signal Builder ---------------------//
string FilterStageName(const int stage)
{
   switch(stage)
   {
      case 0:  return "SESSION";
      case 1:  return "TICK_WARMUP";
      case 2:  return "ATR_MARKET_DATA";
      case 3:  return "ENGINE_ENABLED";
      case 4:  return "EXTREME_VELOCITY";
      case 5:  return "VELOCITY";
      case 6:  return "ACCELERATION";
      case 7:  return "PERSISTENCE";
      case 8:  return "TICK_INTENSITY";
      case 9:  return "DISPLACEMENT";
      case 10: return "TICK_PRESSURE";
      case 11: return "REGIME";
      case 12: return "DIRECTIONAL_SCORE";
      case 13: return "CONTEXT_OPPOSITION";
      case 14: return "SPREAD";
      case 15: return "EXPECTANCY";
      case 16: return "TARGET_COST_FLOOR";
   }
   return "UNKNOWN";
}

bool PassSignalStage(const int strategy,const int stage,const bool passed)
{
   const int idx=strategy-1;
   if(idx<0 || idx>=OMEGA_STRAT_COUNT || stage<0 || stage>=OMEGA_FILTER_STAGE_COUNT)
      return passed;
   g_filter_reached[idx][stage]++;
   if(passed) g_filter_passed[idx][stage]++;
   else g_filter_rejected[idx][stage]++;
   return passed;
}

void ConfigureMomentumStops(const int strategy,const double atr,const double spread,SignalInfo &s)
{
   double sl_mult=InpMicroSL_ATR;
   double rr=InpMicroRewardRisk;
   if(strategy==STRAT_SHORT_MOMENTUM)
   {
      sl_mult=InpShortSL_ATR;
      rr=InpShortRewardRisk;
   }
   else if(strategy==STRAT_EXPANSION_MOMENTUM)
   {
      sl_mult=InpExpansionSL_ATR;
      rr=InpExpansionRewardRisk;
   }

   s.sl_pts=ClampD(atr*sl_mult,InpMinSLPts,InpMaxSLPts);
   const double round_trip_cost=spread+2.0*ExpectedOneWaySlippagePts();
   const double cost_floor=round_trip_cost*MathMax(1.0,InpMinimumTargetCostMultiple);
   s.tp_pts=ClampD(MathMax(s.sl_pts*rr,cost_floor),InpMinTPPts,InpMaxTPPts);
}

bool BuildSignal(const int strategy,SignalInfo &s)
{
   ZeroMemory(s);
   if(strategy<1 || strategy>OMEGA_STRAT_COUNT) return false;
   const int idx=strategy-1;
   g_signal_attempts[idx]++;

   const int session=CurrentSession();
   if(!PassSignalStage(strategy,0,SessionAllowsStrategy(strategy,session))) return false;
   if(!PassSignalStage(strategy,1,g_count>=InpMinTicksBeforeSignal)) return false;

   const double atr=ATRPoints();
   const double spread=CurrentSpreadPts();
   if(!PassSignalStage(strategy,2,(atr>0.0 && spread!=DBL_MAX && PointValue()>0.0))) return false;

   const double v=g_last_velocity;
   const double vc=g_last_velocity_context;
   const double a=g_last_acceleration;
   const double pr=g_last_pressure;
   const double intensity=g_last_intensity;
   const double disp=g_last_displacement;
   const int regime=g_last_regime;

   bool enabled=true;
   double min_velocity=InpMicroVelocityMinPtsSec;
   double min_accel=InpMicroAccelerationMinPtsSec2;
   double min_persist=InpMicroPersistenceMin;
   double min_intensity=InpMicroIntensityMin;
   double min_displacement=InpMicroDisplacementMinPts;
   double min_pressure=InpMicroPressureMinPts;
   double min_score=InpMicroScoreMin;
   if(strategy==STRAT_MICRO_MOMENTUM)
      enabled=InpEnableMicroMomentum;
   else if(strategy==STRAT_SHORT_MOMENTUM)
   {
      enabled=InpEnableShortMomentum;
      min_velocity=InpShortVelocityMinPtsSec;
      min_accel=InpShortAccelerationMinPtsSec2;
      min_persist=InpShortPersistenceMin;
      min_intensity=InpShortIntensityMin;
      min_displacement=InpShortDisplacementMinPts;
      min_pressure=InpShortPressureMinPts;
      min_score=InpShortScoreMin;
   }
   else if(strategy==STRAT_EXPANSION_MOMENTUM)
   {
      enabled=InpEnableExpansionMomentum;
      min_velocity=InpExpansionVelocityMinPtsSec;
      min_accel=InpExpansionAccelerationMinPtsSec2;
      min_persist=InpExpansionPersistenceMin;
      min_intensity=InpExpansionIntensityMin;
      min_displacement=InpExpansionDisplacementMinPts;
      min_pressure=InpExpansionPressureMinPts;
      min_score=InpExpansionScoreMin;
   }
   if(!PassSignalStage(strategy,3,enabled)) return false;

   const bool velocity_safety_ok=(MathAbs(v)<=InpAbsoluteMaxVelocityPtsSec &&
                                  (!InpUseExtremeVelocityGuard || MathAbs(v)<=InpEmergencyMaxVelocityPtsSec));
   if(!PassSignalStage(strategy,4,velocity_safety_ok)) return false;

   const int direction=(v>=0.0 ? 1 : -1);
   const double directional_persistence=(direction>0 ? g_last_dir_persistence_buy : g_last_dir_persistence_sell);
   const double directional_score=ConditionalScore(direction,v,a,pr,directional_persistence,
                                                     intensity,disp,atr);

   if(!PassSignalStage(strategy,5,(MathAbs(v)>OMEGA_EPS && (!InpUseVelocityFilter || direction*v>=min_velocity)))) return false;
   if(!PassSignalStage(strategy,6,(!InpUseAccelerationFilter || direction*a>=min_accel))) return false;
   if(!PassSignalStage(strategy,7,(!InpUsePersistenceFilter || directional_persistence>=min_persist))) return false;
   if(!PassSignalStage(strategy,8,(!InpUseIntensityFilter || intensity>=min_intensity))) return false;
   if(!PassSignalStage(strategy,9,(!InpUseDisplacementFilter || direction*disp>=min_displacement))) return false;
   if(!PassSignalStage(strategy,10,(!InpUsePressureFilter || direction*pr>=min_pressure))) return false;
   const bool momentum_regime=(regime==REGIME_MOMENTUM || regime==REGIME_CHAOS);
   if(!PassSignalStage(strategy,11,(!InpUseRegimeFilter || momentum_regime))) return false;
   if(!PassSignalStage(strategy,12,(!InpUseDirectionalScoreFilter || directional_score>=min_score))) return false;
   const bool context_ok=(direction*vc>=-MathMax(0.0,InpMomentumContextOppositionMax));
   if(!PassSignalStage(strategy,13,(!InpUseContextOppositionFilter || context_ok))) return false;

   // Absolute spread ceiling is always active. Adaptive and spread-expansion
   // gates can be switched independently for controlled experiments.
   bool spread_ok=(spread<=InpEmergencyMaxSpreadPts);
   if(InpUseSpreadExpansionFilter)
      spread_ok=spread_ok && spread<=MathMin(InpMaxSpreadPts,InpSpreadExpansionMaxPts);
   if(InpUseSpreadMomentumGate)
      spread_ok=spread_ok && SpreadMomentumPts(5)<=InpSpreadMomentumThresholdPts;
   if(!PassSignalStage(strategy,14,spread_ok)) return false;

   s.strategy=strategy;
   s.direction=direction;
   s.session=session;
   s.regime=regime;
   s.created_msc=NowMilliseconds();
   s.signal_id=++g_signal_counter;
   s.velocity=v;
   s.acceleration=a;
   s.pressure=pr;
   s.intensity=intensity;
   s.persistence=directional_persistence;
   s.displacement_pts=disp;
   s.spread_pts=spread;
   s.probability=directional_score;
   s.confidence=ClampD((directional_score-0.5)*2.0,0.0,1.0);

   ConfigureMomentumStops(strategy,atr,spread,s);
   const double cost=spread+2.0*ExpectedOneWaySlippagePts();
   const double required_cost_floor=cost*MathMax(1.0,InpMinimumTargetCostMultiple);
   if(!PassSignalStage(strategy,16,s.tp_pts+OMEGA_EPS>=required_cost_floor)) return false;
   const double ev=s.probability*s.tp_pts-(1.0-s.probability)*s.sl_pts-cost;
   if(!PassSignalStage(strategy,15,(!InpUseExpectancyGate || ev>=InpMinimumExpectancyPts))) return false;
   s.edge_pts=ev;

   g_signal_accepted[idx]++;
   g_rej_stage[4]++;
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
   // A zero hard-DD input explicitly disables this throttle.
   if(InpHardDrawdownPct<=0.0) return 1.0;
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
   if(InpHardDrawdownPct>0.0)
      f*=ClampD(1.0-CurrentDrawdownPct()/InpHardDrawdownPct,0.25,1.0);
   if(InpDailyLossLimitPct>0.0)
      f*=ClampD(1.0-DailyDrawdownPct()/InpDailyLossLimitPct,0.20,1.0);
   // Confidence and market personality influence aggression continuously.
   f*=ClampD(0.65+0.70*s.confidence,0.65,1.35);
   if(g_execution_degraded) f*=0.80;
   if((g_last_regime==REGIME_MOMENTUM || g_last_regime==REGIME_CHAOS) && s.strategy==STRAT_EXPANSION_MOMENTUM) f*=1.10;
   if(s.strategy==STRAT_MICRO_MOMENTUM) f*=0.95;
   if(g_last_regime==REGIME_CHAOS) f*=0.80;
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
   const double minv=(broker_min>0.0?broker_min:0.01);
   const double maxv=MathMin(InpLotCap,broker_max>0.0?broker_max:InpLotCap);
   const double vol_step=(step>0.0?step:minv);
   if(volume<minv-OMEGA_EPS || vol_step<=0.0 || maxv<minv) return 0.0;
   volume=MathMin(volume,maxv);
   volume=MathFloor((volume+1e-10)/vol_step)*vol_step;
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
   const double slip=ExpectedOneWaySlippagePts();
   double sl=(type==ORDER_TYPE_BUY ? entry_price-sl_pts*point : entry_price+sl_pts*point);
   sl+=(type==ORDER_TYPE_BUY ? -slip*point : slip*point);
   double profit=0.0;
   if(!OrderCalcProfit(type,_Symbol,1.0,entry_price,NormalizePrice(sl),profit)) return 0.0;
   return MathMax(0.0,-profit);
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
   const double open=PositionGetDouble(POSITION_PRICE_OPEN);
   const double volume=PositionGetDouble(POSITION_VOLUME);
   const long type=PositionGetInteger(POSITION_TYPE);
   const ENUM_ORDER_TYPE ot=(type==POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   const double point=PointValue();
   if(open<=0.0 || volume<=0.0 || point<=0.0) return AccountInfoDouble(ACCOUNT_EQUITY);
   double sl=PositionGetDouble(POSITION_SL);
   if(sl<=0.0)
      sl=(type==POSITION_TYPE_BUY ? open-InpMaxSLPts*point : open+InpMaxSLPts*point);
   sl+=(type==POSITION_TYPE_BUY ? -ExpectedOneWaySlippagePts()*point : ExpectedOneWaySlippagePts()*point);
   double profit=0.0;
   if(!OrderCalcProfit(ot,_Symbol,volume,open,NormalizePrice(sl),profit))
      return AccountInfoDouble(ACCOUNT_EQUITY);
   return MathMax(0.0,-profit);
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
      double sl=OrderGetDouble(ORDER_SL);
      const double vol=OrderGetDouble(ORDER_VOLUME_CURRENT);
      if(price<=0.0 || vol<=0.0) continue;
      const ENUM_ORDER_TYPE ot=(type==ORDER_TYPE_BUY_LIMIT || type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_BUY_STOP_LIMIT ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      const double point=PointValue();
      if(sl<=0.0)
      {
         if(point<=0.0) { risk+=AccountInfoDouble(ACCOUNT_EQUITY); continue; }
         sl=(ot==ORDER_TYPE_BUY ? price-InpMaxSLPts*point : price+InpMaxSLPts*point);
      }
      sl+=(ot==ORDER_TYPE_BUY ? -ExpectedOneWaySlippagePts()*point : ExpectedOneWaySlippagePts()*point);
      double profit=0.0;
      if(OrderCalcProfit(ot,_Symbol,vol,price,NormalizePrice(sl),profit)) risk+=MathMax(0.0,-profit);
      else risk+=AccountInfoDouble(ACCOUNT_EQUITY);
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
   for(int i=1;i<n;i++)   // ascending insertion sort
   {
      const double key=losses[i];
      int j=i-1;
      while(j>=0 && losses[j]>key) { losses[j+1]=losses[j]; j--; }
      losses[j+1]=key;
   }
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

   // Dynamic thesis budget: signal quality, execution quality and current
   // volatility shape size. It is not a fixed lot; normalization always
   // rounds down to the broker volume step and never forces minimum volume.
   const double selected_risk_pct=(InpUseHalfPercentRiskProfile ? InpInitialRiskPct : InpRiskPctWhenHalfPercentOff);
   const double risk_ceiling=MathMin(MathMax(0.0,selected_risk_pct),MathMax(0.0,InpMaxAccountRiskPct));
   double risk_pct=risk_ceiling;
   risk_pct*=DrawdownMultiplier();
   risk_pct*=ClampD(0.55+0.90*s.confidence,0.55,1.45);
   risk_pct*=ClampD(ExecutionCostFactor(),0.25,1.0);
   risk_pct*=VolatilityDrag();
   risk_pct*=AdaptiveAggressionFactor(s);
   risk_pct*=CVaRMultiplier();
   risk_pct*=EmpiricalKellyBoost();
   risk_pct*=GovernorRiskMultiplier();
   risk_pct*=BucketWeight(s.strategy,s.regime,s.session);
   // Dynamic multipliers may reduce the selected risk budget, never increase it.
   // With the 0.50% profile ON, the theoretical per-entry budget cannot exceed 0.50%.
   risk_pct=MathMin(risk_pct,risk_ceiling);

   const double cash=equity*risk_pct/100.0;
   if(cash<=0.0) return 0.0;
   const double raw_lot=cash/loss_lot;
   double lot=NormalizeVolume(raw_lot);
   const double broker_min=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);

   // Never force broker minimum volume. If the risk-budget-sized lot is below
   // broker minimum, reject execution and count the lot-budget rejection.
   if(lot<=0.0 || lot<broker_min-OMEGA_EPS) return 0.0;
   if(InpLotCap>0.0 && lot>InpLotCap) lot=NormalizeVolume(InpLotCap);
   if(lot<=0.0 || lot<broker_min-OMEGA_EPS) return 0.0;

   const double actual_risk=loss_lot*lot;
   if(actual_risk>cash*1.0001) return 0.0;
   return lot;
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

int CountOutstandingOpeningRequests()
{
   int count=0;
   for(int i=0;i<OMEGA_REQ_CAPACITY;i++)
   {
      if(!g_requests[i].active || g_requests[i].position_ticket!=0) continue;
      if(g_requests[i].volume>0.0 && g_requests[i].requested_price>0.0) count++;
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
   const int idx=ClampI(s.strategy,1,OMEGA_STRAT_COUNT);
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
      if(!g_requests[i].active || g_requests[i].position_ticket!=0 || g_requests[i].volume<=0.0 || g_requests[i].sl<=0.0) continue;
      const ENUM_ORDER_TYPE ot=(g_requests[i].direction>0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      const double point=PointValue();
      double effective_sl=g_requests[i].sl+(g_requests[i].direction>0 ? -ExpectedOneWaySlippagePts()*point : ExpectedOneWaySlippagePts()*point);
      double p=0.0;
      if(OrderCalcProfit(ot,_Symbol,g_requests[i].volume,g_requests[i].requested_price,NormalizePrice(effective_sl),p))
         risk+=MathMax(0.0,-p);
   }
   return MathMax(0.0,risk);
}

double OutstandingRequestMargin()
{
   double margin=0.0;
   for(int i=0;i<OMEGA_REQ_CAPACITY;i++)
   {
      if(!g_requests[i].active || g_requests[i].position_ticket!=0 || g_requests[i].volume<=0.0 || g_requests[i].requested_price<=0.0) continue;
      const ENUM_ORDER_TYPE ot=(g_requests[i].direction>0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      double m=0.0;
      if(OrderCalcMargin(ot,_Symbol,g_requests[i].volume,g_requests[i].requested_price,m)) margin+=MathMax(0.0,m);
   }
   return margin;
}

bool PortfolioRiskGate(const SignalInfo &s,const double lot)
{
   if(lot<=0.0) return false;
   const double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   const double free_margin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(equity<=0.0 || free_margin<=0.0) return false;

   // Scale the allowed number of simultaneous theses with account equity.
   // At $10 the engine may hold 2 positions; the configured ceiling grows
   // gradually with equity and is never treated as a required trade count.
   const int equity_slots=2+(int)MathFloor(MathMax(0.0,equity-10.0)/25.0);
   const int max_allowed_pos=MathMax(1,MathMin(InpMaxConcurrentPositions,equity_slots));
   const int occupied_slots=CountOurPositions()+MathMax(CountOurPending(),CountOutstandingOpeningRequests());
   if(occupied_slots>=max_allowed_pos) return false;

   const int same_dir_cap=MathMax(1,MathMin(InpMaxSameDirectionPositions,max_allowed_pos));
   if(CountOurPositionsDirection(s.direction)>=same_dir_cap) return false;

   if(InpMaxPortfolioLots>0.0 && OurLots()+lot>InpMaxPortfolioLots) return false;
   const double delta=OurDeltaLots();
   if(InpMaxPortfolioDeltaLots>0.0 &&
      MathAbs(delta+s.direction*lot)>InpMaxPortfolioDeltaLots) return false;

   // Never impose an arbitrary margin-utilization percentage here. Actual
   // broker-calculated margin and OrderCheck remain mandatory before sending.
   const double reserved_margin=OutstandingRequestMargin();
   const ENUM_ORDER_TYPE ot=(s.direction>0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return false;
   double new_margin=0.0;
   const double price=(s.direction>0 ? tick.ask : tick.bid);
   if(!OrderCalcMargin(ot,_Symbol,lot,price,new_margin)) return false;
   if(free_margin-reserved_margin<new_margin) return false;

   // Adaptive aggregate loss budget. Each candidate must first fit its own
   // safe per-entry lot budget; aggregate open and pending risk is then capped.
   const double new_risk=LossPerLot(s.sl_pts)*lot;
   const double existing=OpenRiskMoney()+PendingRiskMoney()+OutstandingRequestRiskMoney();
   const double cap=equity*MathMax(0.0,InpPortfolioRiskCapPct)/100.0;
   if(cap>0.0 && existing+new_risk>cap) return false;

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
   g_requests[slot].order_ticket=0;
   g_requests[slot].position_ticket=req.position;
   g_requests[slot].signal_id=signal_id;
   g_requests[slot].regime=REGIME_UNKNOWN;
   g_requests[slot].session=SESSION_OFF;
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
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return false;
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
   const double free=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(free<=0.0) return false;
   const double reserved_margin=OutstandingRequestMargin();
   // Only broker feasibility plus a small configurable operational reserve.
   // A zero InpMarginUtilizationMax disables percentage-based throttling.
   if(free-reserved_margin < margin) return false;
   const double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(InpMarginUtilizationMax>0.0 && equity>0.0)
   {
      const double current_margin=AccountInfoDouble(ACCOUNT_MARGIN);
      const double projected_util=(current_margin+reserved_margin+margin)/equity;
      if(projected_util>=InpMarginUtilizationMax) return false;
   }
   if(InpFreeMarginFloorPct>0.0 && equity>0.0 &&
      free-reserved_margin-margin < equity*(InpFreeMarginFloorPct/100.0)) return false;
   return true;
}

ulong MakeMagic(const int strategy)
{
   return InpBaseMagic+(ulong)ClampI(strategy,1,OMEGA_STRAT_COUNT);
}

string StrategyName(const int strategy)
{
   if(strategy==STRAT_MICRO_MOMENTUM) return "MICRO_MOM";
   if(strategy==STRAT_SHORT_MOMENTUM) return "SHORT_MOM";
   if(strategy==STRAT_EXPANSION_MOMENTUM) return "EXPANSION";
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
   if(!OrderCheck(req,chk))
   {
      PrintFormat("OMEGA OrderCheck failed | error=%d retcode=%u comment=%s",GetLastError(),chk.retcode,chk.comment);
      return false;
   }
   // Per MQL5 reference, a successful OrderCheck commonly returns retcode=0.
   if(chk.retcode!=0 && chk.retcode!=TRADE_RETCODE_DONE &&
      chk.retcode!=TRADE_RETCODE_PLACED && chk.retcode!=TRADE_RETCODE_DONE_PARTIAL)
   {
      PrintFormat("OMEGA OrderCheck rejected | retcode=%u comment=%s",chk.retcode,chk.comment);
      return false;
   }
   return true;
}

bool SendMarket(const SignalInfo &s,const double lot)
{
   if(lot<=0.0 || !CanSendOrder()) return false;
   MqlTick t;
   if(!SymbolInfoTick(_Symbol,t)) return false;
   const ENUM_ORDER_TYPE type=(s.direction>0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   const double price=(s.direction>0 ? t.ask : t.bid);
   if(!CheckMarginForOrder(type,lot,price)) return false;

   const double point=PointValue();
   if(point<=0.0 || !StopDistancesValid(s.sl_pts,s.tp_pts)) return false;
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
   if(slot<0) return false;
   g_requests[slot].regime=s.regime;
   g_requests[slot].session=s.session;

   if(!ValidateTradeRequest(req) || !ConsumeToken())
   {
      ClearRequest(slot);
      return false;
   }
   ResetLastError();
   if(!OrderSendAsync(req,res))
   {
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
   if(lot<=0.0 || !CanSendOrder()) return false;
   if(CountOurPending()>=InpMaxPendingOrders) return false;
   MqlTick t;
   if(!SymbolInfoTick(_Symbol,t)) return false;
   const double point=PointValue();
   if(point<=0.0) return false;

   // Generic pending-order helper retained from the execution framework;
   // the three instant-momentum entry engines currently route market orders only.
   double price=(s.direction>0 ? t.bid-InpLimitDistancePts*point : t.ask+InpLimitDistancePts*point);
   price=NormalizePrice(price);
   const ENUM_ORDER_TYPE type=(s.direction>0 ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT);
   if(!CheckMarginForOrder(type,lot,price)) return false;

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
   if(slot<0) return false;
   g_requests[slot].regime=s.regime;
   g_requests[slot].session=s.session;
   if(!ValidateTradeRequest(req) || !ConsumeToken())
   {
      ClearRequest(slot);
      return false;
   }
   ResetLastError();
   if(!OrderSendAsync(req,res))
   {
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
   MqlTick current_tick;
   if(!SymbolInfoTick(_Symbol,current_tick)) return false;
   const double point=PointValue();
   const double min_distance=MinStopDistancePts()*point;
   const long position_type=PositionGetInteger(POSITION_TYPE);
   if(point<=0.0) return false;
   if(nsl>0.0)
   {
      if(position_type==POSITION_TYPE_BUY && nsl>=current_tick.bid-min_distance) return false;
      if(position_type==POSITION_TYPE_SELL && nsl<=current_tick.ask+min_distance) return false;
   }
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
   const ulong local_id=++g_local_request_counter;
   const long sent_us=NowMicroseconds();
   const int slot=TrackRequest(req,local_id,sent_us,(int)((long)req.magic-(long)InpBaseMagic),0);
   if(slot<0) return false;
   if(!ValidateTradeRequest(req) || !ConsumeToken()) { ClearRequest(slot); return false; }
   ResetLastError();
   if(!OrderSendAsync(req,res)) { ClearRequest(slot); return false; }
   BindRequestId(slot,res.request_id);
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

//----------------------------- Position Management ----------------//
void ManagePositions()
{
   // Signal-only research mode must not modify, close, or trail any position.
   if(InpSignalOnlyMode) return;
   const double atr=ATRPoints();
   const double point=PointValue();
   if(atr<=0.0 || point<=0.0) return;
   MqlTick t;
   if(!SymbolInfoTick(_Symbol,t)) return;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      const ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      const long magic=PositionGetInteger(POSITION_MAGIC);
      if(magic<(long)InpBaseMagic || magic>(long)InpBaseMagic+OMEGA_MAGIC_RANGE) continue;

      const long type=PositionGetInteger(POSITION_TYPE);
      const double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      const double tp=PositionGetDouble(POSITION_TP);
      const double price=(type==POSITION_TYPE_BUY ? t.bid : t.ask);
      const double profit_pts=(type==POSITION_TYPE_BUY ? (price-open)/point : (open-price)/point);
      const int pcidx=EnsurePositionControl(ticket);
      if(pcidx>=0 && InpEnableMFE_MAE)
      {
         g_pos_ctrl[pcidx].mfe_pts=MathMax(g_pos_ctrl[pcidx].mfe_pts,profit_pts);
         g_pos_ctrl[pcidx].mae_pts=MathMin(g_pos_ctrl[pcidx].mae_pts,profit_pts);
      }

      // Partial profit extraction is based on this engine's actual strategy-specific TP.
      const double target_distance_pts=(tp>0.0 ? MathAbs(tp-open)/point : MathMax(InpMinTPPts,atr));
      if(pcidx>=0 && InpEnablePartialClose && !g_pos_ctrl[pcidx].partial_done &&
         InpPartialCloseTrigger>0.0 && profit_pts>=target_distance_pts*InpPartialCloseTrigger)
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

      // Cost-aware two-stage protection. The trigger and locked distance expand
      // with observed adverse slippage, instead of moving SL inside transaction costs.
      if(InpUseMicroBreakEven)
      {
         const double expected_slip=ExpectedOneWaySlippagePts();
         const double be1_trigger=MathMax(InpBEStage1TriggerPts,expected_slip*InpBEStage1TriggerCostMultiple);
         const double be1_lock=MathMax(InpBEStage1LockPts,expected_slip*InpBEStage1LockCostMultiple);
         const double be2_trigger=MathMax(InpBEStage2TriggerPts,expected_slip*InpBEStage2TriggerCostMultiple);
         const double be2_lock=MathMax(InpBEStage2LockPts,expected_slip*InpBEStage2LockCostMultiple);
         if(profit_pts>=be2_trigger)
         {
            const double be2=(type==POSITION_TYPE_BUY ? open+be2_lock*point : open-be2_lock*point);
            const bool improve2=(type==POSITION_TYPE_BUY ? (sl==0.0 || be2>sl) : (sl==0.0 || be2<sl));
            if(improve2 && ModifyPositionSLTP(ticket,be2,tp)) sl=be2;
         }
         else if(profit_pts>=be1_trigger)
         {
            const double be1=(type==POSITION_TYPE_BUY ? open+be1_lock*point : open-be1_lock*point);
            const bool improve1=(type==POSITION_TYPE_BUY ? (sl==0.0 || be1>sl) : (sl==0.0 || be1<sl));
            if(improve1 && ModifyPositionSLTP(ticket,be1,tp)) sl=be1;
         }
      }

      // Horizon-aware momentum trailing. Activation is measured from the
      // original stop distance captured when this position was first observed.
      if(InpUseVelocityTrailing && profit_pts>0.0)
      {
         const int strategy=(int)(magic-(long)InpBaseMagic);
         double activation_r=InpMicroTrailActivationR;
         double tier_distance_atr=InpMicroTrailDistanceATR;
         if(strategy==STRAT_SHORT_MOMENTUM)
         {
            activation_r=InpShortTrailActivationR;
            tier_distance_atr=InpShortTrailDistanceATR;
         }
         else if(strategy==STRAT_EXPANSION_MOMENTUM)
         {
            activation_r=InpExpansionTrailActivationR;
            tier_distance_atr=InpExpansionTrailDistanceATR;
         }
         const double initial_risk=(pcidx>=0 && g_pos_ctrl[pcidx].initial_sl_pts>0.0 ?
                                    g_pos_ctrl[pcidx].initial_sl_pts : InpMinSLPts);
         const bool trail_activated=(profit_pts>=initial_risk*MathMax(0.0,activation_r));
         if(!trail_activated) continue;

         // Widen the trail only when momentum is favorable to this position.
         // An adverse burst must not widen the stop distance.
         const double favorable_velocity=(type==POSITION_TYPE_BUY ? g_last_velocity : -g_last_velocity);
         double base_trail_pts=atr*InpTrailWeakATR;
         if(favorable_velocity>=InpTrailVelocityStrong)
            base_trail_pts=atr*InpTrailStrongATR;
         else if(favorable_velocity>InpTrailVelocityWeak)
         {
            const double q=ClampD((favorable_velocity-InpTrailVelocityWeak)/
                                  MathMax(1.0,InpTrailVelocityStrong-InpTrailVelocityWeak),0.0,1.0);
            base_trail_pts=atr*(InpTrailWeakATR+q*(InpTrailStrongATR-InpTrailWeakATR));
         }
         base_trail_pts=MathMax(MathMax(8.0,atr*0.12),
                                MathMax(base_trail_pts,1.25*ExpectedOneWaySlippagePts()));
         const double position_trail_pts=MathMax(base_trail_pts,atr*tier_distance_atr);
         double new_sl=sl;
         if(type==POSITION_TYPE_BUY)
         {
            new_sl=price-position_trail_pts*point;
            if(new_sl>open && (sl==0.0 || new_sl>sl)) ModifyPositionSLTP(ticket,new_sl,tp);
         }
         else
         {
            new_sl=price+position_trail_pts*point;
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
         g_pos_ctrl[i].initial_sl_pts=0.0;
         if(PositionSelectByTicket(ticket))
         {
            const double op=PositionGetDouble(POSITION_PRICE_OPEN);
            const double slp=PositionGetDouble(POSITION_SL);
            const double pt=PointValue();
            if(op>0.0 && slp>0.0 && pt>0.0)
               g_pos_ctrl[i].initial_sl_pts=MathAbs(op-slp)/pt;
         }
         g_pos_ctrl[i].entry_msc=NowMilliseconds();
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
      OrderSendAsync(req,res);
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
   // Static clock blackout windows only. This is NOT a live economic-calendar feed;
   // do not treat it as a guarantee that all high-impact releases are covered.
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

string GlobalGateName(const int stage)
{
   switch(stage)
   {
      case 0:  return "MODE_ENABLED";
      case 1:  return "SYMBOL_ALLOWED";
      case 2:  return "NEWS_BLACKOUT";
      case 3:  return "ROLLOVER";
      case 4:  return "TRADE_ENVIRONMENT";
      case 5:  return "HARD_DRAWDOWN";
      case 6:  return "DAILY_LOSS_LIMIT";
      case 7:  return "LOSS_STREAK_GOVERNOR";
      case 8:  return "DAILY_TRADE_CAP";
      case 9:  return "PENDING_ORDER_CAP";
   }
   return "UNKNOWN";
}

bool PassGlobalGate(const int stage,const bool passed)
{
   if(stage<0 || stage>=OMEGA_GLOBAL_GATE_COUNT) return passed;
   g_global_gate_reached[stage]++;
   if(passed) g_global_gate_passed[stage]++;
   else g_global_gate_rejected[stage]++;
   return passed;
}

bool GeneralTradingGate()
{
   if(!PassGlobalGate(0,InpEnableTrading || InpSignalOnlyMode)) return false;
   if(!PassGlobalGate(1,SymbolAllowed())) return false;
   if(!PassGlobalGate(2,!IsNewsHaltActive())) return false;
   if(!PassGlobalGate(3,!IsRollover())) return false;

   // Signal-only research measures signal availability independently of
   // account balance, daily P/L, the loss-streak governor and order limits.
   // Those controls are applied in execution mode and diagnosed separately.
   if(!InpSignalOnlyMode)
   {
      if(!PassGlobalGate(4,IsTradeEnvironmentReady())) return false;
      if(!PassGlobalGate(5,(InpHardDrawdownPct<=0.0 || CurrentDrawdownPct()<InpHardDrawdownPct))) return false;
      if(!PassGlobalGate(6,(InpDailyLossLimitPct<=0.0 || DailyDrawdownPct()<InpDailyLossLimitPct))) return false;
      if(!PassGlobalGate(7,!GovernorBlocked())) return false;
      if(!PassGlobalGate(8,!DailyTradeCapReached())) return false;
      if(!PassGlobalGate(9,(CountOurPending()<InpMaxPendingOrders || InpAllowMultipleStrategies))) return false;
   }
   // Tick warm-up is counted per engine in BuildSignal, not hidden here.
   return true;
}

bool StrategyDuplicateGate(const SignalInfo &s)
{
   const int idx=ClampI(s.strategy,1,OMEGA_STRAT_COUNT);
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
   if(InpSignalOnlyMode)
   {
      if(StrategyDuplicateGate(s))
      {
         const int idx=strategy-1;
         g_signal_only_logged[idx]++;
         if(InpSignalLogEveryN>0 && (g_signal_only_logged[idx]%InpSignalLogEveryN)==1)
            PrintFormat("OMEGA2 SIGNAL-ONLY | engine=%s dir=%s vel=%.2f acc=%.2f intensity=%.2f persist=%.2f score=%.3f SL=%.1f TP=%.1f spread=%.1f",
                        StrategyName(strategy),(s.direction>0?"BUY":"SELL"),s.velocity,s.acceleration,
                        s.intensity,s.persistence,s.probability,s.sl_pts,s.tp_pts,s.spread_pts);
      }
      return;
   }

   if(!StrategyDuplicateGate(s)) return;
   const double lot=RiskLot(s);
   if(lot<=0.0) { g_rej_stage[5]++; g_lot_rejected[strategy-1]++; return; }
   if(!PortfolioRiskGate(s,lot)) { g_rej_stage[6]++; g_portfolio_rejected[strategy-1]++; return; }
   SendMarket(s,lot);
}

double SignalRank(const SignalInfo &s)
{
   const double execution=ExecutionCostFactor();
   const double edge=MathMax(0.10,s.edge_pts);
   const double horizon_bonus=(s.strategy==STRAT_EXPANSION_MOMENTUM ? 1.05 : 1.0);
   return MathMax(0.01,s.confidence)*edge*execution*horizon_bonus*BucketWeight(s.strategy,s.regime,s.session);
}

void ExecuteCandidate(const SignalInfo &s)
{
   if(!StrategyDuplicateGate(s)) return;
   const double lot=RiskLot(s);
   if(lot<=0.0) { g_rej_stage[5]++; g_lot_rejected[s.strategy-1]++; return; }
   if(!PortfolioRiskGate(s,lot)) { g_rej_stage[6]++; g_portfolio_rejected[s.strategy-1]++; return; }
   SendMarket(s,lot);
}

void RouteSignals()
{
   if(!GeneralTradingGate()) return;

   SignalInfo candidates[OMEGA_STRAT_COUNT];
   bool valid[OMEGA_STRAT_COUNT]={false,false,false};
   for(int i=0;i<OMEGA_STRAT_COUNT;i++) valid[i]=BuildSignal(i+1,candidates[i]);

   if(InpSignalOnlyMode)
   {
      for(int i=0;i<OMEGA_STRAT_COUNT;i++)
      {
         if(!valid[i] || !StrategyDuplicateGate(candidates[i])) continue;
         g_signal_only_logged[i]++;
         if(InpSignalLogEveryN>0 && (g_signal_only_logged[i]%InpSignalLogEveryN)==1)
            PrintFormat("OMEGA2 SIGNAL-ONLY | engine=%s dir=%s vel=%.2f acc=%.2f intensity=%.2f persist=%.2f score=%.3f SL=%.1f TP=%.1f spread=%.1f",
                        StrategyName(i+1),(candidates[i].direction>0?"BUY":"SELL"),
                        candidates[i].velocity,candidates[i].acceleration,candidates[i].intensity,
                        candidates[i].persistence,candidates[i].probability,candidates[i].sl_pts,
                        candidates[i].tp_pts,candidates[i].spread_pts);
      }
      return;
   }

   int best=-1;
   double best_rank=-1.0;
   for(int i=0;i<OMEGA_STRAT_COUNT;i++)
   {
      if(!valid[i]) continue;
      const double rank=SignalRank(candidates[i]);
      if(rank>best_rank) { best_rank=rank; best=i; }
   }
   if(best<0) return;

   const int winning_dir=candidates[best].direction;
   ExecuteCandidate(candidates[best]);

   // Allow same-direction tiers to add exposure only when the portfolio
   // budget and simultaneous-position rules still permit it.
   for(int i=0;i<OMEGA_STRAT_COUNT;i++)
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
                    const long latency,const double profit)
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
}

void FlushTelemetry()
{
   if(!InpPersistTelemetry || g_event_count<=0) return;
   int h=FileOpen(AccountScopedFile(InpTelemetryFile),FILE_READ|FILE_WRITE|FILE_CSV|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE,';');
   if(h==INVALID_HANDLE) return;
   if(FileSize(h)==0)
      FileWrite(h,"time","event","ticket","direction","volume","price","slippage_pts","latency_ms","profit","regime","session","spread","velocity","acceleration","pressure","intensity","persistence","dd");
   FileSeek(h,0,SEEK_END);
   while(g_event_count>0)
   {
      TelemetryEvent e=g_event_queue[g_event_head];
      FileWrite(h,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),e.event_name,(string)e.ticket,e.direction,
                DoubleToString(e.volume,4),DoubleToString(e.price,_Digits),DoubleToString(e.slippage_pts,3),e.latency_ms,
                DoubleToString(e.profit,2),g_last_regime,g_last_session,DoubleToString(g_last_spread_pts,2),
                DoubleToString(g_last_velocity,2),DoubleToString(g_last_acceleration,2),
                DoubleToString(g_last_pressure,3),DoubleToString(g_last_intensity,3),
                DoubleToString(g_last_persistence,3),DoubleToString(CurrentDrawdownPct(),2));
      ZeroMemory(g_event_queue[g_event_head]);
      g_event_head=(g_event_head+1)%OMEGA_EVENT_CAP;
      g_event_count--;
   }
   FileClose(h);
}

void SaveState(const bool force=false)
{
   if(!InpPersistState || MQLInfoInteger(MQL_TESTER)) return;
   const long now=NowMilliseconds();
   if(!force && !g_state_dirty) return;
   if(!force && g_last_state_save_ms>0 && now-g_last_state_save_ms<InpStateSaveIntervalSec*1000) return;
   int h=FileOpen(AccountScopedFile(InpStateFile),FILE_WRITE|FILE_CSV|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE,';');
   if(h==INVALID_HANDLE) return;
   FileWrite(h,"XTRD_OMIGA2_STATE",3,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS));
   FileWrite(h,"peak_equity",DoubleToString(g_peak_equity,8));
   FileWrite(h,"signal_counter",(string)g_signal_counter);
   FileWrite(h,"total_deals",g_total_deals);
   FileWrite(h,"wins",DoubleToString(g_total_wins,0));
   FileWrite(h,"losses",DoubleToString(g_total_losses,0));
   FileWrite(h,"profit",DoubleToString(g_total_profit,8));
   FileWrite(h,"loss",DoubleToString(g_total_loss,8));
   FileWrite(h,"day_key",(string)g_day_key);
   FileWrite(h,"day_start_equity",DoubleToString(g_day_start_equity,8));
   FileWrite(h,"learn_day",(string)g_learn_day_key);
   FileWrite(h,"consec_losses",g_consec_losses);
   FileWrite(h,"cooldown_until",(string)((long)g_cooldown_until));
   for(int s=0;s<OMEGA_STRAT_COUNT;s++)
   {
      for(int r=0;r<OMEGA_REGIME_COUNT;r++)
      {
         for(int e=0;e<OMEGA_SESSION_COUNT;e++)
         {
            if(g_bk_n[s][r][e]<=0.0) continue;
            FileWrite(h,"bk",s+1,r,e,DoubleToString(g_bk_n[s][r][e],6),
                      DoubleToString(g_bk_sum[s][r][e],6),DoubleToString(g_bk_abs[s][r][e],6));
         }
      }
   }
   FileClose(h);
   g_last_state_save_ms=NowMilliseconds();
   g_state_dirty=false;
}

void LoadState()
{
   if(!InpPersistState || MQLInfoInteger(MQL_TESTER)) return;
   int h=FileOpen(AccountScopedFile(InpStateFile),FILE_READ|FILE_CSV|FILE_COMMON|FILE_SHARE_READ|FILE_SHARE_WRITE,';');
   if(h==INVALID_HANDLE) return;
   while(!FileIsEnding(h))
   {
      const string key=FileReadString(h);
      if(key=="XTRD_OMIGA2_STATE")
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
      else if(key=="learn_day") g_learn_day_key=(long)FileReadNumber(h);
      else if(key=="consec_losses") g_consec_losses=(int)FileReadNumber(h);
      else if(key=="cooldown_until") g_cooldown_until=(datetime)((long)FileReadNumber(h));
      else if(key=="bk")
      {
         const int bs=(int)FileReadNumber(h)-1;
         const int br=(int)FileReadNumber(h);
         const int be=(int)FileReadNumber(h);
         const double bn=FileReadNumber(h);
         const double bsum=FileReadNumber(h);
         const double babs=FileReadNumber(h);
         if(bs>=0 && bs<OMEGA_STRAT_COUNT && br>=0 && br<OMEGA_REGIME_COUNT && be>=0 && be<OMEGA_SESSION_COUNT)
         {
            g_bk_n[bs][br][be]=bn;
            g_bk_sum[bs][br][be]=bsum;
            g_bk_abs[bs][br][be]=babs;
         }
      }
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

   const int strategy=(int)(PositionGetInteger(POSITION_MAGIC)-(long)InpBaseMagic);
   double sl_mult=InpMicroSL_ATR;
   double rr=InpMicroRewardRisk;
   if(strategy==STRAT_SHORT_MOMENTUM) { sl_mult=InpShortSL_ATR; rr=InpShortRewardRisk; }
   else if(strategy==STRAT_EXPANSION_MOMENTUM) { sl_mult=InpExpansionSL_ATR; rr=InpExpansionRewardRisk; }
   const double slpts=ClampD(atr*sl_mult,InpMinSLPts,InpMaxSLPts);
   const double spread=CurrentSpreadPts();
   const double cost_floor=(spread==DBL_MAX ? 0.0 : (spread+2.0*ExpectedOneWaySlippagePts())*InpMinimumTargetCostMultiple);
   const double tppts=ClampD(MathMax(slpts*rr,cost_floor),InpMinTPPts,InpMaxTPPts);
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
   PrintFormat("XTRD OMIGA 2 reconciliation: positions=%d pending=%d equity=%.2f DD=%.2f%%",
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
   {
      PrintFormat("XTRD OMIGA 2 ERROR: symbol=%s is not an allowed gold symbol (required=%s)",_Symbol,InpRequiredSymbol);
      return INIT_FAILED;
   }
   if(InpRequireHedgingAccount && !InpSignalOnlyMode &&
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("XTRD OMIGA 2: hedging account required for independent thesis positions.");
      return INIT_FAILED;
   }

   g_peak_equity=AccountInfoDouble(ACCOUNT_EQUITY);
   LoadState();
   if(g_peak_equity<=0.0) g_peak_equity=AccountInfoDouble(ACCOUNT_EQUITY);
   RefreshDailyState();

   const long order_mode=SymbolInfoInteger(_Symbol,SYMBOL_ORDER_MODE);
   if((order_mode & SYMBOL_ORDER_MARKET)==0)
   {
      Print("XTRD OMIGA 2: market order mode is not available on this symbol.");
      return INIT_FAILED;
   }

   g_atr_handle=iATR(_Symbol,PERIOD_M1,14);
   if(g_atr_handle==INVALID_HANDLE)
   {
      Print("XTRD OMIGA 2: ATR handle creation failed.");
      return INIT_FAILED;
   }

   for(int i=0;i<OMEGA_REQ_CAPACITY;i++) ZeroMemory(g_requests[i]);
   for(int j=0;j<OMEGA_SAMPLE_CAPACITY;j++) ZeroMemory(g_samples[j]);
   for(int k=0;k<5;k++) ZeroMemory(g_thesis[k]);

   g_tokens=(double)InpMaxRequestsPerSecond;
   g_last_token_us=NowMicroseconds();

   if(InpReconcileOnInit && !InpSignalOnlyMode) ReconcileState();

   EventSetMillisecondTimer(100);
   PrintFormat("XTRD OMIGA 2 v3.00 initialized | symbol=%s | equity=%.2f %s | leverage=1:%d | min_lot=%.3f step=%.3f | point=%g tick_size=%g | stop_level=%d | risk=%.2f%% | max_positions=%d | tester_gmt_offset=%d",
               _Symbol,AccountInfoDouble(ACCOUNT_EQUITY),AccountInfoString(ACCOUNT_CURRENCY),
               (int)AccountInfoInteger(ACCOUNT_LEVERAGE),SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),
               SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),PointValue(),TickSize(),
               (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),InpInitialRiskPct,InpMaxConcurrentPositions,
               InpTesterGMTOffsetHours);
   PrintFormat("Research mode: signal_only=%s trading_enabled=%s half_percent_profile=%s selected_risk_cap=%.2f%% alt_risk=%.2f%% broker_min_lot_override=REMOVED",
               (InpSignalOnlyMode?"true":"false"),(InpEnableTrading?"true":"false"),
               (InpUseHalfPercentRiskProfile?"true":"false"),
               (InpUseHalfPercentRiskProfile?InpInitialRiskPct:InpRiskPctWhenHalfPercentOff),
               InpRiskPctWhenHalfPercentOff);
   Print("Research principle: test net edge after spread/slippage; signal counts are not fills or proof of profitability.");
   Print("INSTANT MOMENTUM PROFILE: Micro / Short / Expansion engines; M1 ATR exits; independent filter switches.");
   Print("Broker margin feasibility and OrderCheck remain mandatory; this is not colocated institutional HFT.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   SaveState(true);
   FlushTelemetry();
   if(g_atr_handle!=INVALID_HANDLE) IndicatorRelease(g_atr_handle);
   for(int gi=0;gi<OMEGA_GLOBAL_GATE_COUNT;gi++)
      PrintFormat("OMEGA2 GLOBAL GATE | stage=%s reached=%I64d passed=%I64d rejected=%I64d",
                  GlobalGateName(gi),g_global_gate_reached[gi],g_global_gate_passed[gi],g_global_gate_rejected[gi]);
   for(int si=0;si<OMEGA_STRAT_COUNT;si++)
   {
      PrintFormat("OMEGA2 SUMMARY | engine=%s attempts=%I64d accepted=%I64d signal_only=%I64d lot_reject=%I64d portfolio_reject=%I64d",
                  StrategyName(si+1),g_signal_attempts[si],g_signal_accepted[si],g_signal_only_logged[si],
                  g_lot_rejected[si],g_portfolio_rejected[si]);
      for(int st=0;st<OMEGA_FILTER_STAGE_COUNT;st++)
         PrintFormat("OMEGA2 FILTER | engine=%s stage=%s reached=%I64d passed=%I64d rejected=%I64d",
                     StrategyName(si+1),FilterStageName(st),g_filter_reached[si][st],
                     g_filter_passed[si][st],g_filter_rejected[si][st]);
   }
   PrintFormat("XTRD OMIGA 2 stopped. deals=%d DD=%.2f%% avg_slip=%.2f avg_latency=%.1fms profit=%.2f",
               g_total_deals,CurrentDrawdownPct(),AvgSlippage(),AvgLatency(),g_total_profit+g_total_loss);
}

void OnTick()
{
   MqlTick t;
   if(!SymbolInfoTick(_Symbol,t)) return;
   if(InpOnlySymbol && !SymbolAllowed()) return;

   UpdateMarketState(t);
   MaintainLearning();

   if(IsRollover())
   {
      if(InpCancelPendingRollover && !InpSignalOnlyMode) CancelOurPending();
      ManagePositions();
      g_last_tick_msc=(long)t.time_msc;
      return;
   }

   if(!InpSignalOnlyMode)
   {
      ManagePositions();
      RepriceLimits();
   }
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
   if(IsRollover() && InpCancelPendingRollover && !InpSignalOnlyMode) CancelOurPending();
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
            if(request.position!=0) g_requests[slot].position_ticket=request.position;
         }
         if(slot>=0)
         {
            const bool accepted=(result.retcode==TRADE_RETCODE_PLACED ||
                                 result.retcode==TRADE_RETCODE_DONE ||
                                 result.retcode==TRADE_RETCODE_DONE_PARTIAL);
            if(!accepted)
            {
               QueueTelemetry("REQUEST_REJECT",0,g_requests[slot].direction,g_requests[slot].volume,
                              g_requests[slot].requested_price,0.0,
                              (NowMicroseconds()-g_requests[slot].sent_us)/1000,0.0);
               if(request.position!=0)
               {
                  const int pc=FindPositionControl(request.position);
                  if(pc>=0)
                  {
                     g_pos_ctrl[pc].close_pending=false;
                     g_pos_ctrl[pc].last_sent_sl=0.0;
                     g_pos_ctrl[pc].last_sent_tp=0.0;
                     g_pos_ctrl[pc].last_modify_ms=0;
                  }
               }
               ClearRequest(slot);
            }
            else if(request.action==TRADE_ACTION_SLTP)
            {
               ClearRequest(slot);
            }
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
   const int strategy=ClampI((int)(magic-(long)InpBaseMagic),1,OMEGA_STRAT_COUNT);
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
   // MqlTradeTransaction has no request_id member. Request IDs are available
   // only in MqlTradeResult for TRADE_TRANSACTION_REQUEST events.
   if(slot>=0)
   {
      requested=g_requests[slot].requested_price;
      latency=(NowMicroseconds()-g_requests[slot].sent_us)/1000;
      if(point>0.0 && requested>0.0)
         slip=(price-requested)/point*(direction>0?1.0:-1.0);
   }

   const long deal_entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
   if(slot>=0 && (deal_entry==DEAL_ENTRY_IN || deal_entry==DEAL_ENTRY_INOUT))
      g_requests[slot].position_ticket=trans.position;
   if(deal_entry==DEAL_ENTRY_OUT || deal_entry==DEAL_ENTRY_OUT_BY || deal_entry==DEAL_ENTRY_INOUT)
   {
      const ulong pos_ticket=trans.position;
      const int pc=FindPositionControl(pos_ticket);
      if(pc>=0) g_pos_ctrl[pc].close_pending=false;
   }
   if(deal_entry==DEAL_ENTRY_OUT || deal_entry==DEAL_ENTRY_OUT_BY || deal_entry==DEAL_ENTRY_INOUT)
   {
      AddDealSample(MathAbs(slip),profit,volume,latency,direction,strategy);
   }
   // Instant momentum engine learning bookkeeping (v3.00)
   if(deal_entry==DEAL_ENTRY_IN && slot>=0 && trans.position!=0)
   {
      RegisterOpenedPosition(trans.position,strategy,g_requests[slot].regime,g_requests[slot].session);
      g_trades_today++;
   }
   if(deal_entry==DEAL_ENTRY_OUT || deal_entry==DEAL_ENTRY_OUT_BY || deal_entry==DEAL_ENTRY_INOUT)
      AccumulateClosedDeal(trans.position,profit);
   QueueTelemetry("DEAL",deal,direction,volume,price,slip,latency,profit);
   if(slot>=0 && (deal_entry==DEAL_ENTRY_OUT || deal_entry==DEAL_ENTRY_OUT_BY || deal_entry==DEAL_ENTRY_INOUT))
      ClearRequest(slot);
}
//+------------------------------------------------------------------+
