//+------------------------------------------------------------------+
//| XTRD_TICK_EXPORT_1S.mq5  (full tick dump, no trading)            |
//+------------------------------------------------------------------+
#property strict
#property version "1.01"

input string InpOutFile = "XTRD_TICKS.csv";

int  g_fh = INVALID_HANDLE;
long g_rows = 0;

int OnInit()
{
   g_fh = FileOpen(InpOutFile, FILE_WRITE|FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ',');
   if(g_fh == INVALID_HANDLE) { Print("EXPORT_FAILED ", GetLastError()); return INIT_FAILED; }
   FileWrite(g_fh, "sec", "msc", "bid", "ask");
   Print("EXPORT_INIT | ", InpOutFile);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t)) return;
   FileWrite(g_fh, (string)t.time, (string)t.time_msc,
             DoubleToString(t.bid, _Digits), DoubleToString(t.ask, _Digits));
   g_rows++;
}

void OnDeinit(const int reason)
{
   if(g_fh != INVALID_HANDLE) { FileFlush(g_fh); FileClose(g_fh); g_fh = INVALID_HANDLE; }
   Print("EXPORT_DONE | rows=", g_rows);
}
