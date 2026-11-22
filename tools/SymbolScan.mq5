//+------------------------------------------------------------------+
//| SymbolScan.mq5                                                   |
//| Diagnostic only: dumps the terminal symbol tree so the CI job can |
//| resolve the broker's real gold symbol name (XAUUSD vs XAUUSD.a    |
//| vs XAUUSD_i ...). It never trades.                                |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Dumps the terminal symbol tree to Common\\Files\\symbols.csv"

int OnInit()
{
   const string fname="symbols.csv";
   int h=FileOpen(fname,FILE_WRITE|FILE_CSV|FILE_COMMON,';');
   if(h==INVALID_HANDLE)
   {
      PrintFormat("SymbolScan: cannot open %s (err %d)",fname,GetLastError());
      return INIT_FAILED;
   }
   FileWrite(h,"name","description","path","spread_pts","trade_mode");
   const int total=SymbolsTotal(false);
   for(int i=0;i<total;i++)
   {
      const string name=SymbolName(i,false);
      FileWrite(h,name,
                SymbolInfoString(name,SYMBOL_DESCRIPTION),
                SymbolInfoString(name,SYMBOL_PATH),
                DoubleToString((double)SymbolInfoInteger(name,SYMBOL_SPREAD),1),
                (string)SymbolInfoInteger(name,SYMBOL_TRADE_MODE));
   }
   FileClose(h);
   PrintFormat("SymbolScan: wrote %d symbols to %s",total,fname);
   return INIT_SUCCEEDED;
}

void OnTick() {}
