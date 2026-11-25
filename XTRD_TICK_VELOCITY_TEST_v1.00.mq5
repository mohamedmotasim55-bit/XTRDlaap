//+------------------------------------------------------------------+
//| XTRD_TICK_VELOCITY_TEST_v1.00.mq5                               |
//| Standalone tick-velocity measurement EA - SIGNAL/LOG ONLY        |
//| No orders are sent by this program.                              |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Measures tick count and price displacement over 1s and 3s windows. No trading."

input string InpLogFileName       = "XTRD_TICK_VELOCITY_TEST.csv";
input int    InpMaxStoredTicks    = 4096;   // Circular buffer capacity
input bool   InpLogEveryTick      = true;  // Write one CSV row per received tick
input bool   InpPrintToExperts    = false;

#define MAX_TICKS_HARD_LIMIT 20000

long   g_time_msc[];
double g_mid[];
double g_bid[];
double g_ask[];
int    g_capacity = 0;
int    g_next     = 0;   // next write position
int    g_count    = 0;
int    g_file    = INVALID_HANDLE;
long   g_total_ticks = 0;
long   g_last_logged_msc = -1;

//+------------------------------------------------------------------+
int OnInit()
{
   g_capacity = InpMaxStoredTicks;
   if(g_capacity < 100) g_capacity = 100;
   if(g_capacity > MAX_TICKS_HARD_LIMIT) g_capacity = MAX_TICKS_HARD_LIMIT;

   ArrayResize(g_time_msc, g_capacity);
   ArrayResize(g_mid,      g_capacity);
   ArrayResize(g_bid,      g_capacity);
   ArrayResize(g_ask,      g_capacity);

   g_file = FileOpen(InpLogFileName,
                     FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ,
                     ',');
   if(g_file == INVALID_HANDLE)
   {
      Print("ERROR: Cannot open CSV log. Error=", GetLastError());
      return INIT_FAILED;
   }

   if(FileSize(g_file) == 0)
   {
      FileWrite(g_file,
         "server_time", "time_msc", "symbol",
         "bid", "ask", "mid", "spread_points",
         "ticks_1s", "displacement_1s_price", "velocity_1s_price_per_sec",
         "ticks_3s", "displacement_3s_price", "velocity_3s_price_per_sec",
         "direction_1s", "direction_3s", "total_ticks", "buffer_ticks");
   }
   FileSeek(g_file, 0, SEEK_END);

   Print("XTRD Tick Velocity Test v1.00 initialized on ", _Symbol,
         ". Logging to MQL5/Files/", InpLogFileName,
         ". No trading functions are used.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_file != INVALID_HANDLE)
   {
      FileFlush(g_file);
      FileClose(g_file);
      g_file = INVALID_HANDLE;
   }
   Print("XTRD Tick Velocity Test stopped. Total received ticks=", g_total_ticks);
}

//+------------------------------------------------------------------+
string DirectionText(const double delta)
{
   double epsilon = _Point * 0.1;
   if(delta > epsilon)  return "UP";
   if(delta < -epsilon) return "DOWN";
   return "FLAT";
}

//+------------------------------------------------------------------+
void OnTick()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   long stamp = tick.time_msc;
   if(stamp <= 0)
      stamp = (long)TimeCurrent() * 1000;

   // Ignore duplicate or out-of-order timestamps. This prevents invalid
   // elapsed-time calculations while preserving normal same-ms ticks
   // only when their millisecond timestamp advances.
   if(g_count > 0)
   {
      int newest = (g_next - 1 + g_capacity) % g_capacity;
      if(stamp < g_time_msc[newest])
         return;
   }

   double mid = (tick.bid + tick.ask) * 0.5;
   if(tick.bid <= 0.0 || tick.ask <= 0.0 || tick.ask < tick.bid)
      return;

   g_time_msc[g_next] = stamp;
   g_mid[g_next]      = mid;
   g_bid[g_next]      = tick.bid;
   g_ask[g_next]      = tick.ask;

   g_next = (g_next + 1) % g_capacity;
   if(g_count < g_capacity) g_count++;
   g_total_ticks++;

   // Find the oldest sample still inside each time window.
   int count1 = 0, count3 = 0;
   int oldest1 = -1, oldest3 = -1;
   for(int back = 0; back < g_count; back++)
   {
      int idx = (g_next - 1 - back + g_capacity) % g_capacity;
      long age = stamp - g_time_msc[idx];
      if(age < 0) continue;

      if(age <= 1000)
      {
         count1++;
         oldest1 = idx;
      }
      if(age <= 3000)
      {
         count3++;
         oldest3 = idx;
      }
      if(age > 3000)
         break;
   }

   double disp1 = 0.0, vel1 = 0.0;
   double disp3 = 0.0, vel3 = 0.0;
   string dir1 = "WARMUP", dir3 = "WARMUP";

   if(oldest1 >= 0 && count1 >= 2)
   {
      long elapsed = stamp - g_time_msc[oldest1];
      disp1 = mid - g_mid[oldest1];
      if(elapsed > 0)
         vel1 = disp1 / ((double)elapsed / 1000.0);
      dir1 = DirectionText(disp1);
   }

   if(oldest3 >= 0 && count3 >= 2)
   {
      long elapsed = stamp - g_time_msc[oldest3];
      disp3 = mid - g_mid[oldest3];
      if(elapsed > 0)
         vel3 = disp3 / ((double)elapsed / 1000.0);
      dir3 = DirectionText(disp3);
   }

   double spread_points = (tick.ask - tick.bid) / _Point;

   if(InpLogEveryTick && g_file != INVALID_HANDLE)
   {
      FileWrite(g_file,
         TimeToString((datetime)tick.time, TIME_DATE|TIME_SECONDS),
         stamp, _Symbol,
         DoubleToString(tick.bid, _Digits),
         DoubleToString(tick.ask, _Digits),
         DoubleToString(mid, _Digits),
         DoubleToString(spread_points, 1),
         count1,
         DoubleToString(disp1, _Digits),
         DoubleToString(vel1, _Digits),
         count3,
         DoubleToString(disp3, _Digits),
         DoubleToString(vel3, _Digits),
         dir1, dir3, g_total_ticks, g_count);
      FileFlush(g_file);
      g_last_logged_msc = stamp;
   }

   if(InpPrintToExperts)
   {
      Print("TickVelocity | ", _Symbol,
            " | 1s ticks=", count1,
            " displacement=", DoubleToString(disp1, _Digits),
            " velocity=", DoubleToString(vel1, _Digits),
            " direction=", dir1,
            " | 3s ticks=", count3,
            " displacement=", DoubleToString(disp3, _Digits),
            " velocity=", DoubleToString(vel3, _Digits),
            " direction=", dir3,
            " | spread=", DoubleToString(spread_points, 1), " points");
   }
}
//+------------------------------------------------------------------+
