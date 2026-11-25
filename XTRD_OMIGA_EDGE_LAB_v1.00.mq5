//+------------------------------------------------------------------+
//| XTRD_OMIGA_EDGE_LAB_v1.00.mq5                                    |
//| Research EA: executable bid/ask outcome measurement only.        |
//| NO ORDERS ARE SENT. Use Strategy Tester with "Every tick based   |
//| on real ticks" or attach to a demo chart for forward collection. |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "XTRD edge validation lab: samples executable bid/ask returns at multiple horizons. No trading."

input string InpSymbol              = "";       // Empty = chart symbol
input string InpCsvFile             = "XTRD_OMIGA_EDGE_LAB.csv";
input int    InpSampleIntervalMs    = 1000;     // One candidate per interval
input int    InpMaxCandidates       = 2000;     // Circular candidate buffer
input bool   InpFlushEveryRow       = true;
input bool   InpShowStatus          = true;

#define HORIZON_COUNT 7
int g_horizons[HORIZON_COUNT] = {1,3,5,10,30,60,300};

struct Candidate
{
   long   time_msc;
   double bid;
   double ask;
   double spread_points;
   bool   done[HORIZON_COUNT];
   bool   active;
};

Candidate g_candidates[];
int g_capacity=0;
int g_next=0;
int g_file=INVALID_HANDLE;
long g_total_ticks=0;
long g_total_candidates=0;
long g_total_rows=0;
long g_last_sample_msc=0;
double g_point=0.0;
string g_symbol="";

//+------------------------------------------------------------------+
int OnInit()
{
   g_symbol=(InpSymbol=="" ? _Symbol : InpSymbol);
   if(g_symbol!=_Symbol)
   {
      Print("Attach this EA to the same symbol specified in InpSymbol.");
      return INIT_FAILED;
   }
   if(!SymbolSelect(g_symbol,true))
      return INIT_FAILED;

   g_point=SymbolInfoDouble(g_symbol,SYMBOL_POINT);
   if(g_point<=0.0) return INIT_FAILED;

   g_capacity=MathMax(100,MathMin(20000,InpMaxCandidates));
   ArrayResize(g_candidates,g_capacity);

   g_file=FileOpen(InpCsvFile,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE,',');
   if(g_file==INVALID_HANDLE)
   {
      Print("CSV open failed. Error=",GetLastError());
      return INIT_FAILED;
   }
   if(FileSize(g_file)==0)
   {
      FileWrite(g_file,
         "symbol","candidate_time_msc","horizon_seconds",
         "entry_bid","entry_ask","entry_spread_points",
         "exit_bid","exit_ask","exit_spread_points",
         "long_executable_points","short_executable_points",
         "mid_move_points","elapsed_ms");
      FileFlush(g_file);
   }
   FileSeek(g_file,0,SEEK_END);

   Print("XTRD EDGE LAB v1.00 started on ",g_symbol,
         ". Research only: no trade requests will be sent.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_file!=INVALID_HANDLE)
   {
      FileFlush(g_file);
      FileClose(g_file);
      g_file=INVALID_HANDLE;
   }
   Comment("");
   Print("EDGE LAB stopped. ticks=",g_total_ticks,
         " candidates=",g_total_candidates," outcome_rows=",g_total_rows);
}

//+------------------------------------------------------------------+
void AddCandidate(const MqlTick &tick)
{
   int idx=g_next;
   g_candidates[idx].time_msc=tick.time_msc;
   g_candidates[idx].bid=tick.bid;
   g_candidates[idx].ask=tick.ask;
   g_candidates[idx].spread_points=(tick.ask-tick.bid)/g_point;
   g_candidates[idx].active=true;
   for(int h=0;h<HORIZON_COUNT;h++) g_candidates[idx].done[h]=false;

   g_next=(g_next+1)%g_capacity;
   g_total_candidates++;
}

//+------------------------------------------------------------------+
void EvaluateCandidates(const MqlTick &tick)
{
   for(int i=0;i<g_capacity;i++)
   {
      if(!g_candidates[i].active) continue;
      long elapsed=tick.time_msc-g_candidates[i].time_msc;
      if(elapsed<0) continue;

      bool all_done=true;
      for(int h=0;h<HORIZON_COUNT;h++)
      {
         if(g_candidates[i].done[h]) continue;
         long target=(long)g_horizons[h]*1000;
         if(elapsed>=target)
         {
            double exit_spread=(tick.ask-tick.bid)/g_point;
            double long_pts=(tick.bid-g_candidates[i].ask)/g_point;
            double short_pts=(g_candidates[i].bid-tick.ask)/g_point;
            double mid_entry=(g_candidates[i].bid+g_candidates[i].ask)*0.5;
            double mid_exit=(tick.bid+tick.ask)*0.5;
            double mid_move=(mid_exit-mid_entry)/g_point;

            FileWrite(g_file,g_symbol,
               g_candidates[i].time_msc,g_horizons[h],
               DoubleToString(g_candidates[i].bid,_Digits),
               DoubleToString(g_candidates[i].ask,_Digits),
               DoubleToString(g_candidates[i].spread_points,1),
               DoubleToString(tick.bid,_Digits),
               DoubleToString(tick.ask,_Digits),
               DoubleToString(exit_spread,1),
               DoubleToString(long_pts,1),
               DoubleToString(short_pts,1),
               DoubleToString(mid_move,1),elapsed);
            g_candidates[i].done[h]=true;
            g_total_rows++;
            if(InpFlushEveryRow) FileFlush(g_file);
         }
         if(!g_candidates[i].done[h]) all_done=false;
      }
      if(all_done) g_candidates[i].active=false;
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol,tick)) return;
   if(tick.time_msc<=0 || tick.bid<=0.0 || tick.ask<tick.bid) return;

   g_total_ticks++;
   EvaluateCandidates(tick);

   if(g_last_sample_msc==0 ||
      tick.time_msc-g_last_sample_msc>=MathMax(100,InpSampleIntervalMs))
   {
      AddCandidate(tick);
      g_last_sample_msc=tick.time_msc;
   }

   if(InpShowStatus)
   {
      double spread=(tick.ask-tick.bid)/g_point;
      Comment("XTRD OMIGA EDGE LAB v1.00\n",
              "SYMBOL: ",g_symbol," | RESEARCH ONLY / NO TRADING\n",
              "Spread: ",DoubleToString(spread,1)," points\n",
              "Ticks: ",g_total_ticks,
              " | Candidates: ",g_total_candidates,"\n",
              "Outcome rows: ",g_total_rows,
              " | Horizons: 1,3,5,10,30,60,300 sec\n",
              "CSV: MQL5/Files/",InpCsvFile);
   }
}
//+------------------------------------------------------------------+
