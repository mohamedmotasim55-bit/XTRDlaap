//+------------------------------------------------------------------+
//| XTRD OMIGA SIGNAL ENGINE - BUY/SELL discovery only                |
//| No trade execution, no lots, no SL/TP, no account management.      |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Signal discovery engine only: BUY / SELL / WAIT. No trade execution."

input ENUM_TIMEFRAMES SignalTF = PERIOD_M1;
input int    EMA_Fast = 9;
input int    EMA_Mid  = 21;
input int    EMA_Slow = 50;
input int    RSI_Period = 14;
input int    ADX_Period = 14;
input int    ATR_Period = 14;
input int    BB_Period = 20;
input double BB_Deviation = 2.0;
input int    MinSignalScore = 55;       // minimum directional score 0..100
input int    MinStrategyAgreement = 2;  // independent strategy groups
input int    SignalCooldownSeconds = 30;
input bool   PopupAlerts = true;
input bool   PrintSignalLog = true;
input bool   ShowDashboard = true;
input int    TickWindowSeconds = 5;

int hFast=INVALID_HANDLE, hMid=INVALID_HANDLE, hSlow=INVALID_HANDLE;
int hRSI=INVALID_HANDLE, hADX=INVALID_HANDLE, hATR=INVALID_HANDLE;
int hBands=INVALID_HANDLE, hMACD=INVALID_HANDLE;

#define TICK_CAP 2048
datetime tickTime[TICK_CAP];
double tickPrice[TICK_CAP];
int tickHead=0, tickCount=0;
datetime lastSignalTime=0;
string lastSignal="WAIT";
int lastScore=0;
string lastRegime="UNKNOWN";

//+------------------------------------------------------------------+
//| MEASUREMENT MODULE — logging only. No orders, no signal changes. |
//+------------------------------------------------------------------+
#define HZ_COUNT 6
int    g_hz_ms[HZ_COUNT]   = {100,500,1000,3000,5000,10000};
string g_hz_name[HZ_COUNT] = {"100ms","500ms","1s","3s","5s","10s"};

struct PendingSignal
{
   int    id;
   long   t_msc;
   int    dir;
   double entry;
   bool   done[HZ_COUNT];
   bool   active;
};

PendingSignal g_pend[2048];
int    g_pendCount = 0;
int    g_signalId  = 0;
int    g_fhRaw     = INVALID_HANDLE;
int    g_fhFol     = INVALID_HANDLE;
double g_pointMeas = 0.0;

void MeasInit()
{
   g_pointMeas = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_fhRaw = FileOpen("sig_signals_raw.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(g_fhRaw != INVALID_HANDLE)
   {
      if(FileSize(g_fhRaw) == 0)
         FileWrite(g_fhRaw,"signal_id","time_msc","symbol","direction","score","regime",
                   "bid","ask","spread_pts","rsi","adx","atr_pts","tick_vel","up_ratio",
                   "activity","buy_agree","sell_agree","buy_score","sell_score","families");
      FileSeek(g_fhRaw, 0, SEEK_END);
   }
   g_fhFol = FileOpen("sig_followups.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(g_fhFol != INVALID_HANDLE)
   {
      if(FileSize(g_fhFol) == 0)
         FileWrite(g_fhFol,"signal_id","direction","horizon","entry","exit",
                   "net_pts","mfe_pts","mae_pts","positive","ticks");
      FileSeek(g_fhFol, 0, SEEK_END);
   }
   for(int i=0;i<2048;i++){ g_pend[i].active=false; for(int h=0;h<HZ_COUNT;h++) g_pend[i].done[h]=false; }
   g_pendCount=0;
}

void MeasDeinit()
{
   if(g_fhRaw!=INVALID_HANDLE){ FileFlush(g_fhRaw); FileClose(g_fhRaw); g_fhRaw=INVALID_HANDLE; }
   if(g_fhFol!=INVALID_HANDLE){ FileFlush(g_fhFol); FileClose(g_fhFol); g_fhFol=INVALID_HANDLE; }
}

void RecordSignal(const int dir,const int score,const string regime,const double bid,const double ask,
                  const double rsi,const double adx,const double atrPts,const double velocity,
                  const double upRatio,const double activity,const int bAgree,const int sAgree,
                  const double bScore,const double sScore,const string families,const long t_msc)
{
   g_signalId++;
   double spreadPts = (g_pointMeas>0.0) ? (ask-bid)/g_pointMeas : 0.0;
   if(g_fhRaw != INVALID_HANDLE)
   {
      FileWrite(g_fhRaw, g_signalId, (long)t_msc, _Symbol, (dir>0?"BUY":"SELL"), score, regime,
                DoubleToString(bid,_Digits), DoubleToString(ask,_Digits), DoubleToString(spreadPts,1),
                DoubleToString(rsi,2), DoubleToString(adx,2), DoubleToString(atrPts,1),
                DoubleToString(velocity,2), DoubleToString(upRatio,3), DoubleToString(activity,2),
                bAgree, sAgree, DoubleToString(bScore,1), DoubleToString(sScore,1), families);
      FileFlush(g_fhRaw);
   }
   int idx=-1;
   for(int i=0;i<g_pendCount;i++){ if(!g_pend[i].active){ idx=i; break; } }
   if(idx<0 && g_pendCount<2048){ idx=g_pendCount; g_pendCount++; }
   if(idx<0) return;
   g_pend[idx].id    = g_signalId;
   g_pend[idx].t_msc = t_msc;
   g_pend[idx].dir   = dir;
   g_pend[idx].entry = (dir>0) ? ask : bid;
   g_pend[idx].active= true;
   for(int h=0;h<HZ_COUNT;h++) g_pend[idx].done[h]=false;
}

void ResolveFollowups(const long now_msc)
{
   for(int i=0;i<g_pendCount;i++)
   {
      if(!g_pend[i].active) continue;
      bool allDone=true;
      for(int h=0;h<HZ_COUNT;h++)
      {
         if(g_pend[i].done[h]) continue;
         long boundary = g_pend[i].t_msc + (long)g_hz_ms[h];
         if(now_msc < boundary){ allDone=false; continue; }
         MqlTick tk[];
         int n = CopyTicksRange(_Symbol, tk, COPY_TICKS_ALL, (ulong)g_pend[i].t_msc, (ulong)boundary);
         if(n<=0)
         {
            if(g_fhFol!=INVALID_HANDLE)
               FileWrite(g_fhFol, g_pend[i].id, (g_pend[i].dir>0?"BUY":"SELL"), g_hz_name[h],
                         "NA","NA","NA","NA","NA","NA",0);
            g_pend[i].done[h]=true;
            continue;
         }
         double entry = g_pend[i].entry;
         double mfe=-1.0e18, mae=1.0e18, exitPx=entry;
         for(int k=0;k<n;k++)
         {
            double px = (g_pend[i].dir>0) ? tk[k].bid : tk[k].ask;
            double fav = (g_pend[i].dir>0) ? (px-entry) : (entry-px);
            if(fav>mfe) mfe=fav;
            if(fav<mae) mae=fav;
            exitPx = px;
         }
         double net = (g_pend[i].dir>0) ? (exitPx-entry) : (entry-exitPx);
         double pt  = (g_pointMeas>0.0) ? g_pointMeas : 1.0;
         if(g_fhFol!=INVALID_HANDLE)
            FileWrite(g_fhFol, g_pend[i].id, (g_pend[i].dir>0?"BUY":"SELL"), g_hz_name[h],
                      DoubleToString(entry,_Digits), DoubleToString(exitPx,_Digits),
                      DoubleToString(net/pt,2), DoubleToString(mfe/pt,2), DoubleToString(mae/pt,2),
                      (net>0.0?1:0), n);
         g_pend[i].done[h]=true;
      }
      if(allDone) g_pend[i].active=false;
   }
}
//+------------------------------------------------------------------+


bool ReadVal(const int handle,const int buffer,const int shift,double &v)
{
   double a[]; ArraySetAsSeries(a,true);
   if(handle==INVALID_HANDLE || CopyBuffer(handle,buffer,shift,1,a)!=1) return false;
   v=a[0]; return true;
}
void AddTick(const MqlTick &t)
{
   tickHead=(tickHead+1)%TICK_CAP;
   tickTime[tickHead]=t.time;
   tickPrice[tickHead]=(t.bid+t.ask)*0.5;
   if(tickCount<TICK_CAP) tickCount++;
}
void TickFeatures(double &velocityPts,double &upRatio,double &activity)
{
   velocityPts=0; upRatio=0.5; activity=0;
   if(tickCount<2) return;
   int oldest=(tickHead-tickCount+1+TICK_CAP)%TICK_CAP;
   double first=0,last=tickPrice[tickHead]; int valid=0,up=0,down=0;
   datetime cutoff=TimeCurrent()-TickWindowSeconds; bool firstFound=false;
   for(int k=0;k<tickCount;k++)
   {
      int idx=(oldest+k)%TICK_CAP;
      if(tickTime[idx]>=cutoff){ if(!firstFound){first=tickPrice[idx];firstFound=true;} valid++; }
   }
   if(valid<2) return;
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(point>0) velocityPts=(last-first)/point;
   int examined=0;
   for(int k=1;k<tickCount;k++)
   {
      int prev=(oldest+k-1)%TICK_CAP,cur=(oldest+k)%TICK_CAP;
      if(tickTime[cur]<cutoff) continue;
      if(tickPrice[cur]>tickPrice[prev]) up++;
      else if(tickPrice[cur]<tickPrice[prev]) down++;
      examined++;
   }
   if(up+down>0) upRatio=(double)up/(up+down);
   activity=(double)valid/TickWindowSeconds;
}

int ClampScore(double x){ if(x<0)x=0; if(x>100)x=100; return (int)MathRound(x); }

int OnInit()
{
   hFast=iMA(_Symbol,SignalTF,EMA_Fast,0,MODE_EMA,PRICE_CLOSE);
   hMid=iMA(_Symbol,SignalTF,EMA_Mid,0,MODE_EMA,PRICE_CLOSE);
   hSlow=iMA(_Symbol,SignalTF,EMA_Slow,0,MODE_EMA,PRICE_CLOSE);
   hRSI=iRSI(_Symbol,SignalTF,RSI_Period,PRICE_CLOSE);
   hADX=iADX(_Symbol,SignalTF,ADX_Period);
   hATR=iATR(_Symbol,SignalTF,ATR_Period);
   hBands=iBands(_Symbol,SignalTF,BB_Period,0,BB_Deviation,PRICE_CLOSE);
   hMACD=iMACD(_Symbol,SignalTF,12,26,9,PRICE_CLOSE);
   if(hFast==INVALID_HANDLE||hMid==INVALID_HANDLE||hSlow==INVALID_HANDLE||hRSI==INVALID_HANDLE||hADX==INVALID_HANDLE||hATR==INVALID_HANDLE||hBands==INVALID_HANDLE||hMACD==INVALID_HANDLE)
   { Print("Signal Engine: indicator handle initialization failed."); return INIT_FAILED; }
   ArrayInitialize(tickTime,0); ArrayInitialize(tickPrice,0);
   Print("XTRD OMIGA SIGNAL ENGINE initialized. Signal-only mode; trading functions are not used.");

   MeasInit();   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   if(hFast!=INVALID_HANDLE) IndicatorRelease(hFast);
   if(hMid!=INVALID_HANDLE) IndicatorRelease(hMid);
   if(hSlow!=INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hRSI!=INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hADX!=INVALID_HANDLE) IndicatorRelease(hADX);
   if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR);
   if(hBands!=INVALID_HANDLE) IndicatorRelease(hBands);
   if(hMACD!=INVALID_HANDLE) IndicatorRelease(hMACD);
   MeasDeinit();
   Comment("");
}

void OnTick()
{
   MqlTick t; if(!SymbolInfoTick(_Symbol,t)) return; AddTick(t);
   ResolveFollowups(t.time_msc);
   double ef,em,es,rsi,adx,diP,diM,atr,bbMid,bbUp,bbLow,macd,macdSig;
   if(!ReadVal(hFast,0,0,ef)||!ReadVal(hMid,0,0,em)||!ReadVal(hSlow,0,0,es)||
      !ReadVal(hRSI,0,0,rsi)||!ReadVal(hADX,0,0,adx)||!ReadVal(hADX,1,0,diP)||!ReadVal(hADX,2,0,diM)||
      !ReadVal(hATR,0,0,atr)||!ReadVal(hBands,0,0,bbMid)||!ReadVal(hBands,1,0,bbUp)||!ReadVal(hBands,2,0,bbLow)||
      !ReadVal(hMACD,0,0,macd)||!ReadVal(hMACD,1,0,macdSig)) return;
   double velocity,upRatio,activity; TickFeatures(velocity,upRatio,activity);
   double bid=t.bid, ask=t.ask, mid=(bid+ask)/2.0;
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT); if(point<=0) return;
   double atrPts=atr/point;
   double bbWidth=(bbUp-bbLow)/MathMax(bbMid,point);
   bool trendUp=ef>em && em>es, trendDown=ef<em && em<es;
   bool strongTrend=adx>=22;
   bool rangeMode=adx<18;
   bool expansion=(atrPts>0 && bbWidth>0.0020);
   bool compression=(bbWidth<0.0012);
   bool exhaustionUp=(rsi>72 && mid>bbUp && velocity<0);
   bool exhaustionDown=(rsi<28 && mid<bbLow && velocity>0);
   if(strongTrend) lastRegime=(trendUp?"TREND UP":trendDown?"TREND DOWN":"TREND/UNCLEAR");
   else if(compression) lastRegime="COMPRESSION";
   else if(expansion) lastRegime="EXPANSION";
   else if(rangeMode) lastRegime="RANGE";
   else lastRegime="MIXED";

   // Strategy scores: six separate signal families, 0..100 per direction.
   double buy[6],sell[6]; ArrayInitialize(buy,0); ArrayInitialize(sell,0);
   // S1 Micro Momentum: short EMA direction + RSI + MACD + tick direction/velocity
   if(ef>em && rsi>52 && macd>macdSig){ buy[0]=45+(rsi-50)*1.2+MathMin(15,MathMax(0,velocity)); }
   if(ef<em && rsi<48 && macd<macdSig){ sell[0]=45+(50-rsi)*1.2+MathMin(15,MathMax(0,-velocity)); }
   if(upRatio>0.62) buy[0]+=MathMin(15,(upRatio-0.5)*50);
   if(upRatio<0.38) sell[0]+=MathMin(15,(0.5-upRatio)*50);
   // S2 Breakout: BB edge and recent momentum/expansion
   if(mid>bbUp && velocity>0 && expansion) buy[1]=65+MathMin(20,velocity/3.0);
   if(mid<bbLow && velocity<0 && expansion) sell[1]=65+MathMin(20,-velocity/3.0);
   // S3 Trend pullback: directional regime, pullback toward fast/mid EMA, recovering momentum
   if(trendUp && mid>=em && rsi>=48 && rsi<=68 && diP>diM) buy[2]=60+(strongTrend?15:0);
   if(trendDown && mid<=em && rsi>=32 && rsi<=52 && diM>diP) sell[2]=60+(strongTrend?15:0);
   // S4 Mean reversion, only in low ADX/range environment
   if(rangeMode && mid<bbLow && rsi<35) buy[3]=62+MathMin(18,(35-rsi));
   if(rangeMode && mid>bbUp && rsi>65) sell[3]=62+MathMin(18,(rsi-65));
   // S5 Exhaustion reversal
   if(exhaustionDown) buy[4]=68+MathMin(15,(28-rsi));
   if(exhaustionUp) sell[4]=68+MathMin(15,(rsi-72));
   // S6 Tick microstructure imbalance
   if(upRatio>=0.70 && velocity>0 && activity>=0.5) buy[5]=60+MathMin(25,(upRatio-0.5)*50+velocity/4.0);
   if(upRatio<=0.30 && velocity<0 && activity>=0.5) sell[5]=60+MathMin(25,(0.5-upRatio)*50+(-velocity)/4.0);
   for(int i=0;i<6;i++){ buy[i]=ClampScore(buy[i]); sell[i]=ClampScore(sell[i]); }
   // Strategy-family agreement and score aggregation. Only active scores count.
   double bSum=0,sSum=0; int bAgree=0,sAgree=0; double bMax=0,sMax=0;
   for(int i=0;i<6;i++)
   { if(buy[i]>=55){bSum+=buy[i];bAgree++;if(buy[i]>bMax)bMax=buy[i];}
     if(sell[i]>=55){sSum+=sell[i];sAgree++;if(sell[i]>sMax)sMax=sell[i];} }
   double bScore=(bAgree>0)?(bSum/bAgree+MathMin(12,(bAgree-1)*4)):0;
   double sScore=(sAgree>0)?(sSum/sAgree+MathMin(12,(sAgree-1)*4)):0;
   bScore=ClampScore(bScore); sScore=ClampScore(sScore);
   string signal="WAIT"; int score=0;
   if(bScore>=MinSignalScore && bAgree>=MinStrategyAgreement && bScore>sScore+8){signal="BUY";score=(int)bScore;}
   else if(sScore>=MinSignalScore && sAgree>=MinStrategyAgreement && sScore>bScore+8){signal="SELL";score=(int)sScore;}
   string strategyNames="";
   string names[6]={"Momentum","Breakout","TrendPullback","MeanReversion","Exhaustion","TickFlow"};
   if(signal=="BUY") for(int i=0;i<6;i++) if(buy[i]>=55) strategyNames+=names[i]+" ";
   if(signal=="SELL") for(int i=0;i<6;i++) if(sell[i]>=55) strategyNames+=names[i]+" ";
   bool newSignal=(signal!="WAIT" && (signal!=lastSignal || score>=lastScore+10) && (TimeCurrent()-lastSignalTime>=SignalCooldownSeconds));
   if(newSignal)
   {
      lastSignal=signal; lastScore=score; lastSignalTime=TimeCurrent();
      string msg=StringFormat("XTRD SIGNAL %s | score %d | regime %s | strategies %s | RSI %.1f ADX %.1f tickVel %.1fpts tickUp %.2f",signal,score,lastRegime,strategyNames,rsi,adx,velocity,upRatio);
      if(PrintSignalLog) Print(msg);
      if(PopupAlerts) Alert(msg);
      RecordSignal((signal=="BUY"?1:-1),score,lastRegime,bid,ask,rsi,adx,atrPts,velocity,upRatio,activity,bAgree,sAgree,bScore,sScore,strategyNames,t.time_msc);
   }
   if(signal=="WAIT" && (TimeCurrent()-lastSignalTime>SignalCooldownSeconds)) {lastSignal="WAIT";lastScore=0;}
   if(ShowDashboard)
   {
      string dash=StringFormat("XTRD OMIGA — SIGNAL ENGINE ONLY\nSymbol: %s | TF: %s\nMarket: %s\nCurrent: %s | Score: %d | Agree: B%d/S%d\nBUY score: %.0f | SELL score: %.0f\nRSI %.1f | ADX %.1f | ATR %.1f points\nTick velocity: %.1f pts/%ds | Up-tick ratio %.2f | activity %.1f/s\n\nBUY families: ",_Symbol,EnumToString(SignalTF),lastRegime,signal,score,bAgree,sAgree,bScore,sScore,rsi,adx,atrPts,velocity,TickWindowSeconds,upRatio,activity);
      for(int i=0;i<6;i++) if(buy[i]>=55) dash+=names[i]+"("+IntegerToString((int)buy[i])+") ";
      dash+="\nSELL families: "; for(int i=0;i<6;i++) if(sell[i]>=55) dash+=names[i]+"("+IntegerToString((int)sell[i])+") ";
      dash+="\nNo orders are sent by this EA."; Comment(dash);
   }
}
