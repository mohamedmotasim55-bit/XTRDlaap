//+------------------------------------------------------------------+
//| DataPrep.mq5 - forces MT5 to download and cache history.         |
//| Read-only with respect to trading: places no orders.             |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"

input string InpSymbol        = "";     // empty = chart symbol
input int    InpWindowDays    = 365;    // tick window to request
input bool   InpDownloadTicks = true;
input int    InpChunkDays     = 7;      // tick request chunk

string g_sym="";
int    g_h=INVALID_HANDLE;

string TfName(const ENUM_TIMEFRAMES tf)
{
   switch(tf)
     {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
     }
   return EnumToString(tf);
}

void Row(const string kind,const string name,const string first,const string last,
         const string count,const string note)
{
   if(g_h==INVALID_HANDLE) return;
   FileWrite(g_h,kind,name,first,last,count,note);
   FileFlush(g_h);
}

int OnInit()
{
   g_sym=(StringLen(InpSymbol)>0 ? InpSymbol : _Symbol);
   PrintFormat("DataPrep start | symbol=%s window=%d ticks=%s",
               g_sym,InpWindowDays,(InpDownloadTicks?"yes":"no"));

   g_h=FileOpen("dataprep.csv",FILE_WRITE|FILE_CSV|FILE_COMMON|FILE_ANSI,',');
   if(g_h==INVALID_HANDLE) { Print("DataPrep: cannot open dataprep.csv"); return INIT_FAILED; }
   Row("meta","symbol",g_sym,"",IntegerToString(InpWindowDays),TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES));

   ENUM_TIMEFRAMES tfs[]={PERIOD_M1,PERIOD_M5,PERIOD_M15,PERIOD_M30,PERIOD_H1,PERIOD_H4,PERIOD_D1};
   for(int i=0;i<ArraySize(tfs);i++)
     {
      MqlRates r[];
      int n=0;
      for(int a=0;a<120;a++)
        {
         n=CopyRates(g_sym,tfs[i],0,1000000,r);
         if(n>0) break;
         Sleep(1000);
        }
      if(n>0)
        {
         const string f=TimeToString(r[n-1].time,TIME_DATE|TIME_MINUTES);
         const string l=TimeToString(r[0].time,TIME_DATE|TIME_MINUTES);
         Row("rates",TfName(tfs[i]),f,l,IntegerToString(n),"");
         PrintFormat("rates %-3s : %7d bars  %s -> %s",TfName(tfs[i]),n,f,l);
        }
      else
        {
         Row("rates",TfName(tfs[i]),"","","0","no data");
         PrintFormat("rates %-3s : NO DATA",TfName(tfs[i]));
        }
     }

   if(InpDownloadTicks)
     {
      const datetime now=TimeCurrent();
      datetime cur=now-(datetime)(InpWindowDays*86400);
      const long chunk=(long)InpChunkDays*86400;
      long total=0;
      int chunks=0, empty_streak=0;
      while(cur<now && chunks<400)
        {
         datetime end=(datetime)((long)cur+chunk);
         if(end>now) end=now;
         MqlTick t[];
         int got=0;
         for(int a=0;a<12;a++)
           {
            got=CopyTicksRange(g_sym,t,COPY_TICKS_ALL,(ulong)cur*1000,(ulong)end*1000);
            if(got>0) break;
            Sleep(2000);
           }
         if(got<0) got=0;
         total+=got;
         if(got==0) empty_streak++; else empty_streak=0;
         Row("ticks",TimeToString(cur,TIME_DATE)+".."+TimeToString(end,TIME_DATE),
             TimeToString(cur,TIME_DATE),TimeToString(end,TIME_DATE),
             IntegerToString(got),(got>0?"":"empty"));
         PrintFormat("ticks %s..%s : %d",TimeToString(cur,TIME_DATE),TimeToString(end,TIME_DATE),got);
         cur=end;
         chunks++;
         if(empty_streak>=12) { Print("DataPrep: 12 consecutive empty chunks, stopping."); break; }
        }
      Row("ticks_total","all",TimeToString(now-(datetime)(InpWindowDays*86400),TIME_DATE),
          TimeToString(now,TIME_DATE),IntegerToString(total),"");
      PrintFormat("ticks total: %I64d",total);
     }

   Row("done","","","","","");
   FileClose(g_h);
   g_h=INVALID_HANDLE;
   Print("DataPrep done");
   ExpertRemove();
   return INIT_SUCCEEDED;
}

void OnTick() {}
