//+------------------------------------------------------------------+
//|                                         X13_EXPORT_TICKS.mq5     |
//|   Non-trading agent. Dumps raw ticks (ms time, bid, ask, last,   |
//|   volume, flags) for the last N days of the test window so the   |
//|   research harness can study sub-second predictability.          |
//+------------------------------------------------------------------+
#property copyright "X13 LAB"
#property version   "1.00"
#property strict

input int    InpDays    = 10;               // tail of the window to export
input string InpOutFile = "X13_TICKS.csv";

int OnInit() { return INIT_SUCCEEDED; }

void OnDeinit(const int reason)
  {
   datetime to   = TimeCurrent();
   datetime from = to - InpDays * 86400;

   MqlTick ticks[];
   int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_ALL, (long)from * 1000, (long)to * 1000);
   if(n <= 0)
     {
      Print("X13 TICKS: CopyTicksRange returned ", n, " err=", GetLastError());
      return;
     }

   int h = FileOpen(InpOutFile, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE) { Print("X13 TICKS: open failed ", GetLastError()); return; }

   FileWrite(h, "msc", "bid", "ask", "last", "vol", "flags");
   for(int i = 0; i < n; i++)
     {
      FileWrite(h,
                (long)ticks[i].time_msc,
                DoubleToString(ticks[i].bid, _Digits),
                DoubleToString(ticks[i].ask, _Digits),
                DoubleToString(ticks[i].last, _Digits),
                (int)ticks[i].volume,
                (int)ticks[i].flags);
     }
   FileClose(h);
   PrintFormat("X13 TICKS: wrote %d ticks to %s (%.1f MB)",
               n, InpOutFile, (double)n * 40.0 / 1048576.0);
  }

void OnTick() { }
//+------------------------------------------------------------------+
