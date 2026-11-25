//+------------------------------------------------------------------+
//| XTRD_TICK_EXPORT_1S.mq5                                          |
//| Dumps one bid/ask sample per second to Common\Files for research.|
//| No trading. Used only to export a month of market data.          |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"

input string InpOutFile = "XTRD_TICKS_1S.csv";

int    g_fh   = INVALID_HANDLE;
long   g_last = -1;
long   g_rows = 0;

int OnInit()
{
   g_fh = FileOpen(InpOutFile, FILE_WRITE|FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
   if(g_fh == INVALID_HANDLE)
   {
      Print("EXPORT_FAILED open error ", GetLastError());
      return INIT_FAILED;
   }
   FileWrite(g_fh, "sec", "bid", "ask");
   g_last = -1;
   g_rows = 0;
   Print("EXPORT_INIT | ", InpOutFile);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t))
      return;
   if(t.time == g_last)
      return;
   g_last = t.time;
   FileWrite(g_fh, (string)t.time, DoubleToString(t.bid, _Digits), DoubleToString(t.ask, _Digits));
   g_rows++;
}

void OnDeinit(const int reason)
{
   if(g_fh != INVALID_HANDLE)
   {
      FileFlush(g_fh);
      FileClose(g_fh);
      g_fh = INVALID_HANDLE;
   }
   Print("EXPORT_DONE | rows=", g_rows, " | reason=", reason);
}
