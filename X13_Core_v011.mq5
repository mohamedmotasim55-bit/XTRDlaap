#property strict
#property version   "0.11"
#property description "X13 Core v0.11 - Tick Intelligence Engine"


#include <Trade/Trade.mqh>


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
// MARKET STRUCTURE
//==================================================


struct X13_MARKET
{
   string symbol;

   double bid;
   double ask;
   double mid_price;
   double previous_mid;

   double spread_points;
   double spread_average;
   double spread_minimum;
   double spread_maximum;

   double price_change;

   double velocity_50ms;
   double velocity_100ms;
   double velocity_250ms;
   double velocity_1000ms;

   double acceleration;

   double point;
   double tick_size;

   int digits;

   long tick_count;
   long invalid_ticks;
   long same_ms_ticks;
   long tick_gaps;

   long last_tick_msc;

   X13_SESSION session;
   X13_REGIME regime;
};


//==================================================
// STRATEGY STRUCTURE
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
// SIGNAL STRUCTURE
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
// INPUTS
//==================================================


input string InpSymbol = "XAUUSD.m";

input int InpTimerSeconds = 1;

input bool InpDiagnosticLog = true;

input int InpHistoryCapacity = 512;

input int InpGapWarningMilliseconds = 2000;


//==================================================
// CONSTANTS
//==================================================


#define X13_MAX_HISTORY 512
#define X13_SPREAD_HISTORY 128


//==================================================
// GLOBAL STATE
//==================================================


X13_MARKET Market;

X13_STRATEGY Strategies[STRAT_COUNT];

int LogHandle = INVALID_HANDLE;

bool CoreReady = false;

datetime LastTimerTime = 0;

long TickTimes[X13_MAX_HISTORY];

double TickPrices[X13_MAX_HISTORY];

int TickHead = 0;
int TickCount = 0;

double SpreadHistory[X13_SPREAD_HISTORY];

int SpreadHead = 0;
int SpreadCount = 0;

double SpreadSum = 0.0;

ulong MaxProcessingTime = 0;


//==================================================
// LOGGING ENGINE
//==================================================


void X13_Log(string category,string message)
{
   string line =
      TimeToString(TimeTradeServer(),
      TIME_DATE|TIME_SECONDS)
      +" | "+category
      +" | "+message;

   Print("[X13] ",line);

   if(LogHandle != INVALID_HANDLE)
      FileWrite(LogHandle,line);
}


//==================================================
// SESSION INTELLIGENCE
//==================================================


X13_SESSION X13_DetectSession(datetime server_time)
{
   if(server_time <= 0)
      return SESSION_UNKNOWN;

   MqlDateTime dt;

   TimeToStruct(server_time,dt);

   int hour = dt.hour;

   // Provisional broker-server-time mapping.
   // Requires calibration for broker offset and DST.

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

   for(int i=0;i<STRAT_COUNT;i++)
   {
      Strategies[i].id =
         (X13_STRATEGY_ID)i;

      Strategies[i].name = names[i];

      Strategies[i].enabled = true;

      Strategies[i].cooling_down = false;

      Strategies[i].total_signals = 0;

      Strategies[i].accepted_signals = 0;

      Strategies[i].rejected_signals = 0;

      Strategies[i].consecutive_losses = 0;

      Strategies[i].gross_profit = 0;

      Strategies[i].gross_loss = 0;

      Strategies[i].cooldown_until = 0;
   }

   X13_Log("CORE","Strategy registry initialized");
}


//==================================================
// DATA VALIDATION
//==================================================


bool X13_ValidateTick(MqlTick &tick)
{
   if(tick.bid <= 0 || tick.ask <= 0)
      return false;

   if(tick.ask < tick.bid)
      return false;

   if(tick.time_msc <= 0)
      return false;

   if(Market.point <= 0)
      return false;

   return true;
}


//==================================================
// SPREAD INTELLIGENCE
//==================================================


void X13_UpdateSpread(double spread)
{
   if(SpreadCount < X13_SPREAD_HISTORY)
   {
      SpreadHistory[SpreadHead] = spread;

      SpreadSum += spread;

      SpreadCount++;
   }
   else
   {
      SpreadSum -= SpreadHistory[SpreadHead];

      SpreadHistory[SpreadHead] = spread;

      SpreadSum += spread;
   }

   SpreadHead++;

   if(SpreadHead >= X13_SPREAD_HISTORY)
      SpreadHead = 0;

   double minimum = spread;
   double maximum = spread;

   for(int i=0;i<SpreadCount;i++)
   {
      if(SpreadHistory[i] < minimum)
         minimum = SpreadHistory[i];

      if(SpreadHistory[i] > maximum)
         maximum = SpreadHistory[i];
   }

   Market.spread_average =
      SpreadSum / SpreadCount;

   Market.spread_minimum = minimum;

   Market.spread_maximum = maximum;
}


//==================================================
// TICK HISTORY
//==================================================


void X13_AddTick(long time_msc,double price)
{
   TickTimes[TickHead] = time_msc;

   TickPrices[TickHead] = price;

   TickHead++;

   if(TickHead >= InpHistoryCapacity)
      TickHead = 0;

   if(TickCount < InpHistoryCapacity)
      TickCount++;
}


//==================================================
// VELOCITY ENGINE
//==================================================


double X13_CalculateVelocity(
   int window_ms,
   long current_time,
   double current_price
)
{
   if(TickCount < 2)
      return 0.0;

   int capacity = InpHistoryCapacity;

   int newest = TickHead - 1;

   if(newest < 0)
      newest = capacity - 1;

   int index = newest;

   int visited = 0;

   while(visited < TickCount-1)
   {
      int previous = index-1;

      if(previous < 0)
         previous = capacity-1;

      long age =
         current_time-TickTimes[previous];

      if(age > window_ms)
         break;

      index = previous;

      visited++;
   }

   long elapsed =
      current_time-TickTimes[index];

   if(elapsed <= 0)
      return 0.0;

   return
      ((current_price-TickPrices[index])/Market.point)
      /(elapsed/1000.0);
}


//==================================================
// MARKET DATA ENGINE
//==================================================


bool X13_UpdateMarket()
{
   MqlTick tick;

   if(!SymbolInfoTick(InpSymbol,tick))
   {
      Market.invalid_ticks++;
      return false;
   }

   if(!X13_ValidateTick(tick))
   {
      Market.invalid_ticks++;
      return false;
   }

   long previous_time =
      Market.last_tick_msc;

   double previous_mid =
      Market.mid_price;

   double current_mid =
      (tick.bid+tick.ask)*0.5;

   if(previous_time > 0)
   {
      long delta =
         tick.time_msc-previous_time;

      if(delta < 0)
      {
         Market.invalid_ticks++;
         return false;
      }

      if(delta == 0)
         Market.same_ms_ticks++;

      if(delta > InpGapWarningMilliseconds)
         Market.tick_gaps++;
   }

   Market.previous_mid = previous_mid;

   Market.bid = tick.bid;

   Market.ask = tick.ask;

   Market.mid_price = current_mid;

   Market.price_change =
      previous_time > 0
      ? current_mid-previous_mid
      : 0.0;

   Market.spread_points =
      (tick.ask-tick.bid)/Market.point;

   Market.tick_count++;

   Market.last_tick_msc =
      tick.time_msc;

   X13_AddTick(tick.time_msc,current_mid);

   X13_UpdateSpread(Market.spread_points);

   Market.velocity_50ms =
      X13_CalculateVelocity(
         50,tick.time_msc,current_mid);

   Market.velocity_100ms =
      X13_CalculateVelocity(
         100,tick.time_msc,current_mid);

   Market.velocity_250ms =
      X13_CalculateVelocity(
         250,tick.time_msc,current_mid);

   Market.velocity_1000ms =
      X13_CalculateVelocity(
         1000,tick.time_msc,current_mid);

   Market.acceleration =
      Market.velocity_100ms-
      Market.velocity_250ms;

   Market.session =
      X13_DetectSession(TimeTradeServer());

   return true;
}


//==================================================
// REGIME ENGINE - RESERVED
//==================================================


void X13_UpdateRegime()
{
   // Real regime classification will be added
   // after the data engine passes validation.

   Market.regime = REGIME_UNKNOWN;
}


//==================================================
// SIGNAL BUS
//==================================================


bool X13_PublishSignal(X13_SIGNAL &signal)
{
   if((int)signal.strategy < 0 ||
      (int)signal.strategy >= STRAT_COUNT)
      return false;

   Strategies[signal.strategy].total_signals++;

   X13_Log(
      "SIGNAL",
      Strategies[signal.strategy].name+
      " | Direction="+
      IntegerToString((int)signal.direction)+
      " | Confidence="+
      DoubleToString(signal.confidence,3)
   );

   return true;
}


//==================================================
// DIAGNOSTICS
//==================================================


void X13_Diagnostics()
{
   string report =
      "Ticks="+
      IntegerToString((int)Market.tick_count)+

      " Invalid="+
      IntegerToString((int)Market.invalid_ticks)+

      " SameMS="+
      IntegerToString((int)Market.same_ms_ticks)+

      " Gaps="+
      IntegerToString((int)Market.tick_gaps)+

      " Spread="+
      DoubleToString(Market.spread_points,1)+

      " SpreadAvg="+
      DoubleToString(Market.spread_average,1)+

      " SpreadMin="+
      DoubleToString(Market.spread_minimum,1)+

      " SpreadMax="+
      DoubleToString(Market.spread_maximum,1)+

      V50=+
      DoubleToString(Market.velocity_50ms,2)+

      "V100="+
      DoubleToString(Market.velocity_100ms,2)+

      "V250="+
      DoubleToString(Market.velocity_250ms,2)+

      "V1000="+
      DoubleToString(Market.velocity_1000ms,2)+

      التسارع = +
      DoubleToString(Market.acceleration,2);

   X13_Log("HEARTBEAT",report);
}


//==================================================
// التهيئة
//==================================================


دالة OnInit()
{
   Market.symbol = InpSymbol;

   if(!SymbolSelect(InpSymbol,true))
   {
      Print("X13 ERROR: Symbol selection failed");

      أرجع INIT_FAILED؛
   }

   Market.point =
      SymbolInfoDouble(InpSymbol,SYMBOL_POINT);

   حجم التكة في السوق =
      SymbolInfoDouble(
         InpSymbol,
         حجم علامة التداول
      );

   Market.digits =
      (int)SymbolInfoInteger(
         InpSymbol,
         أرقام الرمز
      );

   إذا كانت قيمة نقطة السوق أقل من أو تساوي صفرًا
   {
      Print("X13 ERROR: نقطة رمز غير صالحة");

      أرجع INIT_FAILED؛
   }

   إذا كانت سعة سجل الإدخال أقل من 32 أو
      InpHistoryCapacity > X13_MAX_HISTORY)
   {
      Print("X13 ERROR: History capacity must be 32..512");

      أعد INIT_PARAMETERS_INCORRECT؛
   }

   Market.tick_count = 0;

   Market.invalid_ticks = 0;

   Market.same_ms_ticks = 0;

   Market.tick_gaps = 0;

   Market.last_tick_msc = 0;

   Market.mid_price = 0;

   Market.previous_mid = 0;

   TickHead = 0;

   TickCount = 0;

   SpreadHead = 0;

   SpreadCount = 0;

   SpreadSum = 0;

   MaxProcessingTime = 0;

   X13_RegisterStrategies();

   if(InpDiagnosticLog)
   {
      LogHandle = FileOpen(
         "X13_Core_v011_Diagnostics.csv"
         قراءة الملف | كتابة الملف | ملف CSV |
         ملف_ANSI|ملف_مشاركة_قراءة|
         FILE_SHARE_WRITE,
         ;
      );

      إذا كان (LogHandle != INVALID_HANDLE)
         FileSeek(LogHandle,0,SEEK_END);
      آخر
         Print("X13 تحذير: ملف السجل غير متوفر");
   }

   if(!EventSetTimer(MathMax(1,InpTimerSeconds))))
   {
      Print("X13 ERROR: Timer initialization failed");

      إذا كان (LogHandle != INVALID_HANDLE)
         FileClose(LogHandle);

      LogHandle = INVALID_HANDLE;

      أرجع INIT_FAILED؛
   }

   CoreReady = صحيح؛

   X13_Log("CORE","X13 CORE v0.11 STARTED - DATA ONLY");

   أعد INIT_SUCCEEDED؛
}


//==================================================
// حدث تيك
//==================================================


void OnTick()
{
   إذا لم يكن CoreReady
      يعود؛

   ulong begin = GetMicro SecondCount();

   إذا تم تحديث السوق (X13_UpdateMarket())
      X13_UpdateRegime();

   ulong Finished = GetMicro SecondCount();

   إذا (تم الانتهاء >= تم البدء)
   {
      ulong elapsed = finished-started;

      إذا كان الوقت المنقضي أكبر من الحد الأقصى لوقت المعالجة
         MaxProcessingTime = elapsed;
   }
}


//==================================================
// حدث مؤقت
//==================================================


void OnTimer()
{
   إذا لم يكن CoreReady
      يعود؛

   datetime now = TimeTradeServer();

   إذا كان الوقت الحالي يساوي وقت المؤقت الأخير
      يعود؛

   LastTimerTime = الآن؛

   if(InpDiagnosticLog)
      X13_Diagnostics();

   إذا كان (LogHandle != INVALID_HANDLE)
      FileFlush(LogHandle);
}


//==================================================
// اغلق
//==================================================


void OnDeinit(const int reason)
{
   CoreReady = false;

   EventKillTimer();

   X13_Log(
      "جوهر"،
      "سبب الإغلاق"+
      IntegerToString(reason)+
      " | علامات "+
      IntegerToString((int)Market.tick_count)+
      " | غير صالح"+
      IntegerToString((int)Market.invalid_ticks)+
      " | الفجوات "+
      IntegerToString((int)Market.tick_gaps)
   );

   إذا كان (LogHandle != INVALID_HANDLE)
   {
      FileFlush(LogHandle);

      FileClose(LogHandle);

      LogHandle = INVALID_HANDLE;
   }
}
