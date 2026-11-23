#property strict
#property version "0.10"
#property description "X13 Autonomous Empire - Core Architecture"


#include <Trade/Trade.mqh>


CTrade Trade;


//==================================================
// X13 CORE DEFINITIONS
//==================================================


enum X13_SESSION
{
   SESSION_ASIA,
   SESSION_LONDON,
   SESSION_NEWYORK,
   SESSION_OVERLAP,
   SESSION_TRANSITION,
   SESSION_UNKNOWN
};


enum X13_REGIME
{
   REGIME_UNKNOWN,
   REGIME_TREND,
   REGIME_RANGE,
   REGIME_HIGH_VOLATILITY,
   REGIME_LOW_VOLATILITY,
   REGIME_CHAOTIC
};


enum X13_STRATEGY_ID
{
   STRAT_MOMENTUM,
   STRAT_PULLBACK,
   STRAT_BREAKOUT,
   STRAT_MEAN_REVERSION,
   STRAT_EXHAUSTION,
   STRAT_TICK_PRESSURE,
   STRAT_COUNT
};


enum X13_SIGNAL_DIRECTION
{
   SIGNAL_NONE,
   SIGNAL_BUY,
   SIGNAL_SELL
};


//==================================================
// MARKET SNAPSHOT
//==================================================


struct X13_MARKET
{
   string symbol;


   double bid;
   double ask;
   double spread_points;


   double mid_price;
   double previous_mid;


   double tick_velocity;
   double price_change;


   double point;
   int digits;


   long tick_count;


   datetime last_tick_time;


   X13_SESSION session;
   X13_REGIME regime;
};


//==================================================
// STRATEGY STATE
//==================================================


struct X13_STRATEGY
{
   X13_STRATEGY_ID id;


   string name;


   bool enabled;
   bool cooling_down;


   int total_signals;
   int accepted_signals;
   int rejected_signals;


   int consecutive_losses;


   double gross_profit;
   double gross_loss;


   datetime cooldown_until;
};


//==================================================
// SIGNAL CONTRACT
//==================================================


struct X13_SIGNAL
{
   X13_STRATEGY_ID strategy;


   X13_SIGNAL_DIRECTION direction;


   double entry_price;
   double initial_sl;
   double target_price;


   double confidence;
   double expected_cost;


   double expected_reward;


   datetime signal_time;


   string reason;
};


//==================================================
// GLOBAL ENGINE STATE
//==================================================


X13_MARKET Market;


X13_STRATEGY Strategies[STRAT_COUNT];


int LogHandle = INVALID_HANDLE;


bool CoreReady = false;


datetime LastTimerTime = 0;


input string InpSymbol = "XAUUSD.m";
input int InpTimerSeconds = 1;
input bool InpDiagnosticLog = true;


//==================================================
// LOGGING ENGINE
//==================================================


void X13_Log(string category, string message)
{
   string line =
      TimeToString(TimeTradeServer(), TIME_DATE|TIME_SECONDS)
      + " | " + category
      + " | " + message;


   Print("[X13] ", line);


   if(LogHandle != INVALID_HANDLE)
   {
      FileWrite(LogHandle, line);
      FileFlush(LogHandle);
   }
}


//==================================================
// STRATEGY REGISTRY
//==================================================


void X13_RegisterStrategies()
{
   string names[STRAT_COUNT] =
   {
      "Momentum",
      "Pullback",
      "Breakout",
      "MeanReversion",
      "Exhaustion",
      "TickPressure"
   };


   for(int i=0; i<STRAT_COUNT; i++)
   {
      Strategies[i].id = (X13_STRATEGY_ID)i;


      Strategies[i].name = names[i];


      Strategies[i].enabled = true;
      Strategies[i].cooling_down = false;


      Strategies[i].total_signals = 0;
      Strategies[i].accepted_signals = 0;
      Strategies[i].rejected_signals = 0;


      Strategies[i].consecutive_losses = 0;


      Strategies[i].gross_profit = 0.0;
      Strategies[i].gross_loss = 0.0;


      Strategies[i].cooldown_until = 0;
   }


   X13_Log("CORE", "Strategy registry initialized");
}


//==================================================
// SESSION INTELLIGENCE - INITIAL VERSION
//==================================================


X13_SESSION X13_DetectSession(datetime server_time)
{
   MqlDateTime dt;


   TimeToStruct(server_time, dt);


   int hour = dt.hour;


   // Initial UTC-like hour mapping.
   // Must be calibrated against broker server time.


   if(hour >= 0 && hour < 7)
      return SESSION_ASIA;


   if(hour >= 7 && hour < 12)
      return SESSION_LONDON;


   if(hour >= 12 && hour < 16)
      return SESSION_OVERLAP;


   if(hour >= 16 && hour < 21)
      return SESSION_NEWYORK;


   return SESSION_TRANSITION;
}


//==================================================
// MARKET DATA ENGINE
//==================================================


bool X13_UpdateMarket()
{
   MqlTick tick;


   if(!SymbolInfoTick(InpSymbol, tick))
   {
      X13_Log("DATA", "SymbolInfoTick failed");
      return false;
   }


   Market.previous_mid = Market.mid_price;


   Market.bid = tick.bid;
   Market.ask = tick.ask;


   Market.mid_price = (tick.bid + tick.ask) / 2.0;


   Market.point = SymbolInfoDouble(
      InpSymbol, SYMBOL_POINT
   );


   Market.digits = (int)SymbolInfoInteger(
      InpSymbol, SYMBOL_DIGITS
   );


   if(Market.point <= 0.0)
      return false;


   Market.spread_points =
      (Market.ask - Market.bid) / Market.point;


   Market.price_change =
      Market.mid_price - Market.previous_mid;


   Market.tick_count++;


   datetime now = TimeTradeServer();


   if(Market.last_tick_time > 0)
   {
      double elapsed =
         (double)(tick.time_msc -
         (long)Market.last_tick_time * 1000);


      if(elapsed > 0.0)
      {
         Market.tick_velocity =
            MathAbs(Market.price_change)
            / Market.point
            / (elapsed / 1000.0);
      }
   }


   Market.last_tick_time = (datetime)tick.time;


   Market.session = X13_DetectSession(now);


   return true;
}


//==================================================
// REGIME PLACEHOLDER
//==================================================


void X13_UpdateRegime()
{
   // Regime detection will be implemented
   // in the Market Intelligence module.


   Market.regime = REGIME_UNKNOWN;
}


//==================================================
// SIGNAL BUS
//==================================================


bool X13_PublishSignal(X13_SIGNAL &signal)
{
   if(signal.strategy < 0 ||
      signal.strategy >= STRAT_COUNT)
      return false;


   Strategies[signal.strategy].total_signals++;


   X13_Log(
      "SIGNAL",
      Strategies[signal.strategy].name
      + " | Direction="
      + IntegerToString((int)signal.direction)
      + " | Confidence="
      + DoubleToString(signal.confidence, 3)
   );


   return true;
}


//==================================================
// DIAGNOSTICS
//==================================================


void X13_Diagnostics()
{
   string report =
      "Ticks=" + IntegerToString((int)Market.tick_count)
      + " Spread=" + DoubleToString(Market.spread_points, 1)
      + " Velocity=" + DoubleToString(Market.tick_velocity, 2)
      + " Session=" + IntegerToString((int)Market.session);


   X13_Log("HEARTBEAT", report);
}


//==================================================
// INITIALIZATION
//==================================================


int OnInit()
{
   Market.symbol = InpSymbol;


   if(!SymbolSelect(InpSymbol, true))
   {
      Print("X13 ERROR: Cannot select symbol ", InpSymbol);
      return INIT_FAILED;
   }


   Market.tick_count = 0;
   Market.mid_price = 0.0;
   Market.previous_mid = 0.0;
   Market.tick_velocity = 0.0;


   X13_RegisterStrategies();


   if(InpDiagnosticLog)
   {
      LogHandle = FileOpen(
         "X13_Core_Diagnostics.csv",
         FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE,
         ';'
      );


      if(LogHandle != INVALID_HANDLE)
         FileSeek(LogHandle, 0, SEEK_END);
      else
         Print("X13 warning: diagnostic file unavailable");
   }


   if(!EventSetTimer(MathMax(1, InpTimerSeconds)))
   {
      Print("X13 ERROR: Timer initialization failed");
      return INIT_FAILED;
   }


   CoreReady = true;


   X13_Log("CORE", "X13 CORE v0.10 started");


   return INIT_SUCCEEDED;
}


//==================================================
// حدث تيك
//==================================================


void OnTick()
{
   if(!CoreReady)
      return;


   if(!X13_UpdateMarket())
      return;


   X13_UpdateRegime();


   // يتم ربط محركات الاستراتيجية هنا في المراحل التالية.
}


//==================================================
// حدث مؤقت
//==================================================


void OnTimer()
{
   if(!CoreReady)
      return;


   datetime now = TimeTradeServer();


   if(now == LastTimerTime)
      return;


   LastTimerTime = now;


   X13_Diagnostics();
}


//==================================================
// اغلق
//==================================================


void OnDeinit(const int reason)
{
   CoreReady = false;


   EventKillTimer();


   X13_Log(
      "CORE",
      "shutdown reason=" + IntegerToString(reason)
   );


   if(LogHandle != INVALID_HANDLE)
   {
      FileClose(LogHandle);
      LogHandle = INVALID_HANDLE;
   }
}
