//+------------------------------------------------------------------+
//|  XTRD_OMIGA_FINAL.mq5 — evolutionary breakthrough config          |
//|  Fade a 15-bar channel break, ATR-dynamic target/stop,            |
//|  ATR>=3x spread gate, hours 3,12,15,21,22,23, 240-min hold.       |
//|  Source: 4800-eval walk-forward search; robust across 3 months.   |
//+------------------------------------------------------------------+
#property copyright "XTRD / OMIGA"
#property version   "2.00"
#include <Trade\Trade.mqh>

input group           "=== Engine ==="
input int             InpMagic              = 20261122;
input double          InpLot                 = 0.01;
input int             InpChannelBars         = 15;
input int             InpBreakoutPts         = 20;
input double          InpTargetATR           = 6.0;
input double          InpStopATR             = 3.0;
input double          InpATRGate            = 3.0;
input int             InpATRPeriod           = 60;
input int             InpHoldMinutes         = 240;
input int             InpCooldownMin         = 15;
input string          InpHours               = "3,12,15,21,22,23";
input double          InpPulseRatio          = 1.3;
input int             InpPulseAvgBars        = 60;
input int             InpMaxSpreadPts        = 60;
input double          InpMaxAccountRiskPct   = 100.0;
input group           "=== Telemetry ==="
input bool            InpTelemetry           = true;
input string          InpTelemetryFile       = "X13_Omega_Telemetry.csv";

CTrade   g_trade;
datetime g_lastExit = 0;
bool     g_hadPosition = false;
datetime g_blockUntil = 0;
double   g_point = 0.0;

int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(50);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_point = _Point;
   if(g_point <= 0.0) return(INIT_FAILED);
   if(InpTelemetry)
   {
      int h = FileOpen(InpTelemetryFile, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
      if(h != INVALID_HANDLE)
      { FileWrite(h,"time","event","dir","price","lots","pnl_pts","reason"); FileClose(h); }
   }
   PrintFormat("XTRD FINAL ready %s | tgt=%.1fxATR stop=%.1fxATR gate=%.1fx hours=%s",
               _Symbol, InpTargetATR, InpStopATR, InpATRGate, InpHours);
   return(INIT_SUCCEEDED);
}
void OnDeinit(const int reason) { }

double SpreadPts()
{ return (SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID))/g_point; }

bool BarClose(const int shift, double &v)
{
   double b[]; ArraySetAsSeries(b,true);
   int n = CopyClose(_Symbol,PERIOD_M1,0,shift+1,b);
   if(n<=shift) return false;
   v=b[shift]; return true;
}
bool Channel(const int lb,const int start,double &hh,double &ll)
{
   double hi[],lo[]; ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true);
   int need=start+lb+1;
   int nh=CopyHigh(_Symbol,PERIOD_M1,0,need,hi);
   int nl=CopyLow (_Symbol,PERIOD_M1,0,need,lo);
   if(nh<need||nl<need) return false;
   hh=-1.0e100; ll=1.0e100;
   for(int i=start;i<start+lb;i++){ if(hi[i]>hh)hh=hi[i]; if(lo[i]<ll)ll=lo[i]; }
   return true;
}
double ATR()
{
   double hi[],lo[]; ArraySetAsSeries(hi,true); ArraySetAsSeries(lo,true);
   int n=CopyHigh(_Symbol,PERIOD_M1,0,InpATRPeriod+1,hi);
   int m=CopyLow (_Symbol,PERIOD_M1,0,InpATRPeriod+1,lo);
   if(n<InpATRPeriod+1||m<InpATRPeriod+1) return 0.0;
   double s=0; for(int i=1;i<=InpATRPeriod;i++) s+=(hi[i]-lo[i]);
   return s/(double)InpATRPeriod;
}
double PulseRatio()
{
   long v[]; ArraySetAsSeries(v,true);
   int n=CopyTickVolume(_Symbol,PERIOD_M1,0,InpPulseAvgBars+1,v);
   if(n<10) return 1.0;
   double s=0; int c=0;
   for(int i=1;i<n;i++){ s+=(double)v[i]; c++; }
   if(c<=0) return 1.0;
   double avg=s/(double)c; if(avg<=0.0) return 1.0;
   return (double)v[1]/avg;
}
bool HourAllowed(const int h)
{
   string p[]; int n=StringSplit(InpHours,',',p);
   for(int i=0;i<n;i++) if((int)StringToInteger(p[i])==h) return true;
   return false;
}
bool HasOurPosition(datetime &tOut,int &dOut,double &pOut,ulong &tkOut)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      tkOut=tk; tOut=(datetime)PositionGetInteger(POSITION_TIME);
      dOut=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)?1:-1;
      pOut=PositionGetDouble(POSITION_PRICE_OPEN);
      return true;
   }
   return false;
}
int CountOurPositions()
{
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      n++;
   }
   return n;
}
void Telemetry(const string ev,const int dir,const double px,const double lots,const double pnl,const string rsn)
{
   if(!InpTelemetry) return;
   int h=FileOpen(InpTelemetryFile,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(h==INVALID_HANDLE) return;
   FileSeek(h,0,SEEK_END);
   FileWrite(h,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),ev,dir,
             DoubleToString(px,_Digits),DoubleToString(lots,2),DoubleToString(pnl,0),rsn);
   FileClose(h);
}

void OnTick()
{
   ulong tk=0; datetime openT=0; int dir=0; double openP=0.0;
   if(HasOurPosition(openT,dir,openP,tk))
   {
      g_hadPosition=true;
      if((long)(TimeCurrent()-openT)>=(long)InpHoldMinutes*60)
      {
         double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
         double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         double cp=(dir>0)?bid:ask;
         double pp=(dir>0)?(cp-openP)/g_point:(openP-cp)/g_point;
         if(g_trade.PositionClose(tk))
         { Telemetry("EXIT",dir,cp,InpLot,pp,"time"); g_lastExit=TimeCurrent(); }
      }
      return;
   }
   if(g_hadPosition){ g_hadPosition=false; if(g_lastExit==0) g_lastExit=TimeCurrent(); }

   if(TimeCurrent()<g_blockUntil) return;
   if(CountOurPositions()>=1) return;
   if((long)(TimeCurrent()-g_lastExit)<(long)InpCooldownMin*60) return;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   if(!HourAllowed(dt.hour)) return;
   double spread=SpreadPts();
   if(spread>(double)InpMaxSpreadPts) return;
   if(PulseRatio()<InpPulseRatio) return;
   double atr=ATR();
   if(atr<=0.0) return;
   if(atr < InpATRGate*spread*g_point) return;          // dynamic ATR gate

   double hh,ll,c1;
   if(!Channel(InpChannelBars,2,hh,ll)) return;
   if(!BarClose(1,c1)) return;
   double thr=(double)InpBreakoutPts*g_point;
   int sig=0;
   if(c1>hh+thr) sig=-1;                                 // FADE
   if(c1<ll-thr) sig= 1;
   if(sig==0) return;

   double stopPts=InpStopATR*atr/g_point;
   double tgtPts =InpTargetATR*atr/g_point;
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(stopPts*g_point*InpLot*100.0 > equity*InpMaxAccountRiskPct/100.0) return;

   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(sig>0)
   {
      double sl=ask-stopPts*g_point, tp=ask+tgtPts*g_point;
      if(g_trade.Buy(InpLot,_Symbol,0.0,sl,tp,"XTRD-FADE"))
      { g_blockUntil=TimeCurrent()+180; Telemetry("ENTRY",1,ask,InpLot,0,"fade-buy"); }
   }
   else
   {
      double sl=bid+stopPts*g_point, tp=bid-tgtPts*g_point;
      if(g_trade.Sell(InpLot,_Symbol,0.0,sl,tp,"XTRD-FADE"))
      { g_blockUntil=TimeCurrent()+180; Telemetry("ENTRY",-1,bid,InpLot,0,"fade-sell"); }
   }
}
//+------------------------------------------------------------------+
