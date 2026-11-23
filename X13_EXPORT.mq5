//+------------------------------------------------------------------+
//|                                                X13_EXPORT.mq5    |
//|   Non-trading agent: dumps M1 bars + real spread to CSV so the   |
//|   research harness can screen strategies outside the tester.     |
//+------------------------------------------------------------------+
#property copyright "X13 LAB"
#property version   "1.00"
#property strict

input string InpOutFile = "X13_M1.csv";

int OnInit()
  {
   Print("X13 EXPORT armed, symbol=", _Symbol);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   int total = iBars(_Symbol, PERIOD_M1);
   if(total <= 0) { Print("X13 EXPORT: no bars"); return; }

   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_M1, 0, total, r);
   if(n <= 0) { Print("X13 EXPORT: CopyRates failed ", GetLastError()); return; }

   int h = FileOpen(InpOutFile, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE) { Print("X13 EXPORT: open failed ", GetLastError()); return; }

   FileWrite(h, "time", "open", "high", "low", "close", "tickvol", "spread");
   for(int i = 0; i < n; i++)
     {
      int sp = (int)iSpread(_Symbol, PERIOD_M1, i);
      FileWrite(h,
                TimeToString(r[i].time, TIME_DATE | TIME_SECONDS),
                DoubleToString(r[i].open, _Digits),
                DoubleToString(r[i].high, _Digits),
                DoubleToString(r[i].low, _Digits),
                DoubleToString(r[i].close, _Digits),
                (long)r[i].tick_volume,
                sp);
     }
   FileClose(h);
   PrintFormat("X13 EXPORT: wrote %d bars to %s", n, InpOutFile);
  }

void OnTick() { }
//+------------------------------------------------------------------+
