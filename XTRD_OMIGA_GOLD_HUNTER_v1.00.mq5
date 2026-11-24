//+------------------------------------------------------------------+
//| XTRD OMIGA - GOLD HUNTER v1.00                                   |
//| Dual Stop Adaptive Movement Hunter for MetaTrader 5              |
//| Research-first source. Compile and test in MetaEditor before use. |
//+------------------------------------------------------------------+
#property copyright "XTRD OMIGA"
#property version   "1.00"
#property strict
#property description "Dual Buy Stop / Sell Stop gold movement hunter with tick momentum and adaptive trailing."

#include <Trade/Trade.mqh>

//--------------------------- INPUTS ---------------------------------
input group "01. General"
input string InpTradeSymbol              = "";          // Empty = chart symbol
input ulong  InpMagicNumber              = 26112401;
input bool   InpResearchMode              = true;        // true: no live order placement/modification
input bool   InpEnableTrading             = false;       // Must be explicitly enabled
input bool   InpSignalOnlyMode             = true;        // Log setups, do not send orders
input int    InpMaxOpenPositions           = 16;
input int    InpMaxPendingOrders           = 2;
input int    InpDeviationPoints            = 30;
input int    InpMaxSpreadPoints            = 0;           // 0 = no spread filter; broker costs still apply
input int    InpMinSecondsBetweenCycles    = 10;

input group "02. Volume"
input double InpInitialLot                = 0.01;
input double InpMaxLotPerPosition         = 0.09;
input double InpLotStep                   = 0.01;
input bool   InpScaleLotsWithMomentum      = false;       // OFF by default; no automatic lot escalation
input double InpStrongMomentumLot         = 0.02;        // Used only if scaling is enabled

input group "03. Movement and Momentum"
input bool   InpEnableMovementScanner     = true;
input bool   InpEnableMicroHunter         = true;
input bool   InpEnableMomentum            = true;
input int    InpFastTickWindow             = 12;
input int    InpSlowTickWindow             = 60;
input int    InpMinTicksForSignal          = 20;
input double InpMinDirectionalRatio        = 0.58;        // 0.50..1.00
input double InpMinNetMovePoints           = 8.0;
input double InpMinSpeedPointsPerSecond    = 0.0;         // 0 = diagnostic only
input double InpMinAccelerationRatio      = 1.05;
input int    InpATRPeriod                  = 14;
input ENUM_TIMEFRAMES InpATRTimeframe      = PERIOD_M1;
input double InpEntryATRMultiplier         = 0.35;
input double InpMinEntryDistancePoints     = 30.0;
input double InpMaxEntryDistancePoints     = 500.0;
input double InpPendingRepricePoints       = 15.0;
input int    InpPendingExpiryMinutes       = 5;
input bool   InpUseTickDirectionFilter     = true;

input group "04. Adaptive Trailing"
input bool   InpEnableAdaptiveTrailing     = true;
input double InpInitialSL_ATRMultiplier    = 1.50;
input double InpTrailATRMultiplierFast     = 1.60;
input double InpTrailATRMultiplierSlow     = 0.85;
input double InpTrailActivationATR         = 0.80;
input double InpTrailMinDistancePoints     = 40.0;
input double InpTrailTightenMomentumRatio  = 0.70;        // Slow/fast speed ratio below this tightens trail
input int    InpTrailMinStepPoints         = 10;

input group "05. Order Management"
input bool   InpEnableDualStop             = true;
input bool   InpEnableOCO                  = true;
input bool   InpEnableStacking             = true;
input bool   InpCancelStalePendings        = true;
input bool   InpRearmAfterFill             = true;
input bool   InpRequireMomentumForRearm    = true;
input bool   InpEnableMomentumExit         = false;       // Off initially; trailing remains primary exit
input double InpMomentumExitRatio          = 0.35;

input group "06. Diagnostics"
input bool   InpVerboseLog                 = true;
input bool   InpShowChartStatus             = true;

//--------------------------- GLOBALS --------------------------------
string   g_symbol = "";
int      g_atr_handle = INVALID_HANDLE;
datetime g_last_cycle_time = 0;
datetime g_last_signal_log = 0;
ulong    g_seen_deal_tickets[];

#define TICK_BUFFER_SIZE 256
double   g_tick_mid[TICK_BUFFER_SIZE];
long     g_tick_time_msc[TICK_BUFFER_SIZE];
int      g_tick_count = 0;
int      g_tick_head = 0;
double   g_fast_speed = 0.0;
double   g_slow_speed = 0.0;
double   g_directional_ratio = 0.5;
double   g_net_move_points = 0.0;
double   g_atr = 0.0;
bool     g_momentum_up = false;
bool     g_momentum_down = false;
bool     g_micro_up = false;
bool     g_micro_down = false;

//--------------------------- UTILITIES ------------------------------
void Log(string msg)
{
   if(InpVerboseLog) Print("[GOLD_HUNTER] ", msg);
}

double PointValue()
{
   return SymbolInfoDouble(g_symbol, SYMBOL_POINT);
}

int DigitsValue()
{
   return (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
}

double NormalizePrice(double price)
{
   return NormalizeDouble(price, DigitsValue());
}

double NormalizeVolume(double volume)
{
   double vmin = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) return 0.0;
   volume = MathMax(vmin, MathMin(vmax, volume));
   volume = MathFloor(volume / step + 1e-8) * step;
   int vd = 2;
   if(step < 0.01) vd = 3;
   if(step < 0.001) vd = 4;
   return NormalizeDouble(volume, vd);
}

bool IsHedgingAccount()
{
   ENUM_ACCOUNT_MARGIN_MODE mode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   return (mode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

bool TradingPermitted()
{
   if(InpResearchMode || !InpEnableTrading || InpSignalOnlyMode) return false;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return false;
   return true;
}

bool SpreadOK()
{
   if(InpMaxSpreadPoints <= 0) return true;
   MqlTick t;
   if(!SymbolInfoTick(g_symbol, t)) return false;
   double p = PointValue();
   if(p <= 0) return false;
   return ((t.ask - t.bid) / p <= InpMaxSpreadPoints);
}

bool GetATR(double &atr)
{
   atr = 0.0;
   if(g_atr_handle == INVALID_HANDLE) return false;
   double b[];
   ArraySetAsSeries(b, true);
   if(CopyBuffer(g_atr_handle, 0, 0, 2, b) < 1) return false;
   atr = b[0];
   return (atr > 0.0);
}

//--------------------------- TICK ENGINE ----------------------------
void PushTick(const MqlTick &tick)
{
   double mid = (tick.bid + tick.ask) * 0.5;
   g_tick_mid[g_tick_head] = mid;
   g_tick_time_msc[g_tick_head] = (long)tick.time_msc;
   g_tick_head = (g_tick_head + 1) % TICK_BUFFER_SIZE;
   if(g_tick_count < TICK_BUFFER_SIZE) g_tick_count++;
}

int BufferIndexFromNewest(int offset)
{
   int idx = g_tick_head - 1 - offset;
   while(idx < 0) idx += TICK_BUFFER_SIZE;
   return idx % TICK_BUFFER_SIZE;
}

bool GetTickAt(int offset, double &price, long &tm)
{
   if(offset < 0 || offset >= g_tick_count) return false;
   int idx = BufferIndexFromNewest(offset);
   price = g_tick_mid[idx];
   tm = g_tick_time_msc[idx];
   return true;
}

void CalculateTickMetrics()
{
   g_fast_speed = 0.0;
   g_slow_speed = 0.0;
   g_directional_ratio = 0.5;
   g_net_move_points = 0.0;
   g_momentum_up = false;
   g_momentum_down = false;
   g_micro_up = false;
   g_micro_down = false;
   double point = PointValue();
   if(point <= 0 || g_tick_count < InpMinTicksForSignal) return;

   int fastN = MathMin(InpFastTickWindow, g_tick_count - 1);
   int slowN = MathMin(InpSlowTickWindow, g_tick_count - 1);
   if(fastN < 2 || slowN < fastN) return;

   double newest, oldestFast, oldestSlow;
   long tnew, tf, ts;
   if(!GetTickAt(0, newest, tnew) || !GetTickAt(fastN, oldestFast, tf) || !GetTickAt(slowN, oldestSlow, ts)) return;

   double fastSeconds = MathMax(0.001, (double)(tnew - tf) / 1000.0);
   double slowSeconds = MathMax(0.001, (double)(tnew - ts) / 1000.0);
   g_fast_speed = MathAbs(newest - oldestFast) / point / fastSeconds;
   g_slow_speed = MathAbs(newest - oldestSlow) / point / slowSeconds;
   g_net_move_points = (newest - oldestFast) / point;

   int up = 0, down = 0;
   for(int i=0; i<fastN; i++)
   {
      double p0,p1; long x0,x1;
      if(!GetTickAt(i,p0,x0) || !GetTickAt(i+1,p1,x1)) continue;
      if(p0 > p1) up++;
      else if(p0 < p1) down++;
   }
   int directional = up + down;
   if(directional > 0)
   {
      double dominant = (double)MathMax(up,down) / directional;
      g_directional_ratio = dominant;
   }

   double speedRatio = (g_slow_speed > 0.000001 ? g_fast_speed / g_slow_speed : 1.0);
   g_momentum_up = (g_net_move_points >= InpMinNetMovePoints && up > down && g_directional_ratio >= InpMinDirectionalRatio && speedRatio >= InpMinAccelerationRatio);
   g_momentum_down = (g_net_move_points <= -InpMinNetMovePoints && down > up && g_directional_ratio >= InpMinDirectionalRatio && speedRatio >= InpMinAccelerationRatio);

   // Micro detector uses a smaller displacement threshold but keeps directional consistency.
   double microThreshold = MathMax(2.0, InpMinNetMovePoints * 0.25);
   g_micro_up = (InpEnableMicroHunter && g_net_move_points >= microThreshold && up > down && g_directional_ratio >= InpMinDirectionalRatio);
   g_micro_down = (InpEnableMicroHunter && g_net_move_points <= -microThreshold && down > up && g_directional_ratio >= InpMinDirectionalRatio);

   if(InpMinSpeedPointsPerSecond > 0.0)
   {
      if(g_fast_speed < InpMinSpeedPointsPerSecond)
      {
         g_momentum_up = false;
         g_momentum_down = false;
      }
   }
}

//--------------------------- COUNTS ----------------------------------
int CountOurPositions()
{
   int count=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==g_symbol && (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagicNumber) count++;
   }
   return count;
}

int CountOurPendingOrders()
{
   int count=0;
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=g_symbol || (ulong)OrderGetInteger(ORDER_MAGIC)!=InpMagicNumber) continue;
      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_SELL_STOP || type==ORDER_TYPE_BUY_STOP_LIMIT || type==ORDER_TYPE_SELL_STOP_LIMIT) count++;
   }
   return count;
}

bool HasOurPositionDirection(ENUM_POSITION_TYPE direction)
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_symbol || (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==direction) return true;
   }
   return false;
}

//--------------------------- TRADE REQUESTS --------------------------
bool SendPending(ENUM_ORDER_TYPE type, double volume, double price, double sl, datetime expiration, string comment)
{
   MqlTradeRequest req;
   MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action=TRADE_ACTION_PENDING;
   req.symbol=g_symbol;
   req.magic=InpMagicNumber;
   req.volume=volume;
   req.type=type;
   req.price=NormalizePrice(price);
   req.sl=(sl>0 ? NormalizePrice(sl) : 0.0);
   req.tp=0.0;
   req.deviation=InpDeviationPoints;
   req.type_filling=ORDER_FILLING_RETURN;
   req.type_time=(expiration>0 ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC);
   req.expiration=expiration;
   req.comment=comment;

   if(!TradingPermitted())
   {
      Log(StringFormat("RESEARCH setup: %s vol=%.2f price=%.*f SL=%.*f",EnumToString(type),volume,DigitsValue(),req.price,DigitsValue(),req.sl));
      return false;
   }
   bool ok=OrderSend(req,res);
   if(!ok || (res.retcode!=TRADE_RETCODE_DONE && res.retcode!=TRADE_RETCODE_PLACED))
   {
      Log(StringFormat("Pending send failed type=%s retcode=%u comment=%s",EnumToString(type),res.retcode,res.comment));
      return false;
   }
   Log(StringFormat("Pending placed ticket=%I64u type=%s vol=%.2f price=%.*f",res.order,EnumToString(type),volume,DigitsValue(),req.price));
   return true;
}

bool DeleteOrder(ulong ticket)
{
   if(ticket==0) return false;
   if(!TradingPermitted()) { Log(StringFormat("RESEARCH cancel pending ticket=%I64u",ticket)); return false; }
   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action=TRADE_ACTION_REMOVE;
   req.order=ticket;
   req.symbol=g_symbol;
   req.magic=InpMagicNumber;
   bool ok=OrderSend(req,res);
   if(!ok || res.retcode!=TRADE_RETCODE_DONE)
   {
      Log(StringFormat("Cancel failed ticket=%I64u retcode=%u %s",ticket,res.retcode,res.comment));
      return false;
   }
   Log(StringFormat("Pending cancelled ticket=%I64u",ticket));
   return true;
}

bool ModifyPositionSL(ulong ticket, double newSL)
{
   if(!TradingPermitted()) return false;
   if(!PositionSelectByTicket(ticket)) return false;
   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action=TRADE_ACTION_SLTP;
   req.position=ticket;
   req.symbol=g_symbol;
   req.magic=InpMagicNumber;
   req.sl=NormalizePrice(newSL);
   req.tp=PositionGetDouble(POSITION_TP);
   bool ok=OrderSend(req,res);
   if(!ok || (res.retcode!=TRADE_RETCODE_DONE && res.retcode!=TRADE_RETCODE_NO_CHANGES))
   {
      Log(StringFormat("SL modify failed pos=%I64u retcode=%u %s",ticket,res.retcode,res.comment));
      return false;
   }
   Log(StringFormat("Trailing updated pos=%I64u SL=%.*f",ticket,DigitsValue(),req.sl));
   return true;
}

//--------------------------- PENDING MANAGEMENT ---------------------
void CancelOppositePendings()
{
   if(!InpEnableOCO) return;
   bool hasBuy=HasOurPositionDirection(POSITION_TYPE_BUY);
   bool hasSell=HasOurPositionDirection(POSITION_TYPE_SELL);
   if(!hasBuy && !hasSell) return;
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=g_symbol || (ulong)OrderGetInteger(ORDER_MAGIC)!=InpMagicNumber) continue;
      ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if((hasBuy && type==ORDER_TYPE_SELL_STOP) || (hasSell && type==ORDER_TYPE_BUY_STOP)) DeleteOrder(ticket);
   }
}

void CancelAllOurPendings()
{
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0) continue;
      if(OrderGetString(ORDER_SYMBOL)==g_symbol && (ulong)OrderGetInteger(ORDER_MAGIC)==InpMagicNumber) DeleteOrder(ticket);
   }
}

bool FindPending(ENUM_ORDER_TYPE type, ulong &ticket, double &price, datetime &setupTime)
{
   ticket=0; price=0; setupTime=0;
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong t=OrderGetTicket(i);
      if(t==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=g_symbol || (ulong)OrderGetInteger(ORDER_MAGIC)!=InpMagicNumber) continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)!=type) continue;
      ticket=t;
      price=OrderGetDouble(ORDER_PRICE_OPEN);
      setupTime=(datetime)OrderGetInteger(ORDER_TIME_SETUP);
      return true;
   }
   return false;
}

bool ModifyPendingPrice(ulong ticket, ENUM_ORDER_TYPE type, double newPrice, double newSL)
{
   if(!TradingPermitted()) return false;
   if(!OrderSelect(ticket)) return false;
   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);
   req.action=TRADE_ACTION_MODIFY;
   req.order=ticket;
   req.symbol=g_symbol;
   req.magic=InpMagicNumber;
   req.price=NormalizePrice(newPrice);
   req.sl=(newSL>0 ? NormalizePrice(newSL) : 0.0);
   req.tp=0.0;
   req.type_time=(InpPendingExpiryMinutes>0 ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC);
   req.expiration=(InpPendingExpiryMinutes>0 ? TimeCurrent()+InpPendingExpiryMinutes*60 : 0);
   bool ok=OrderSend(req,res);
   if(!ok || (res.retcode!=TRADE_RETCODE_DONE && res.retcode!=TRADE_RETCODE_NO_CHANGES))
   {
      Log(StringFormat("Pending modify failed ticket=%I64u retcode=%u %s",ticket,res.retcode,res.comment));
      return false;
   }
   return true;
}

//--------------------------- ENTRY ENGINE ---------------------------
double CalculateEntryDistance()
{
   double p=PointValue();
   if(p<=0) return 0;
   double dist=MathMax(InpMinEntryDistancePoints*p,g_atr*InpEntryATRMultiplier);
   if(InpMaxEntryDistancePoints>0) dist=MathMin(dist,InpMaxEntryDistancePoints*p);
   long stops=SymbolInfoInteger(g_symbol,SYMBOL_TRADE_STOPS_LEVEL);
   dist=MathMax(dist,(stops+2)*p);
   return dist;
}

double SelectEntryLot()
{
   double lot=InpInitialLot;
   if(InpScaleLotsWithMomentum && g_fast_speed>g_slow_speed*1.5 && g_directional_ratio>0.75)
      lot=MathMax(lot,InpStrongMomentumLot);
   lot=MathMin(lot,InpMaxLotPerPosition);
   lot=NormalizeVolume(lot);
   if(lot>InpMaxLotPerPosition+1e-8) lot=NormalizeVolume(InpMaxLotPerPosition);
   return lot;
}

void EnsureDualStops()
{
   if(!InpEnableDualStop || !SpreadOK()) return;
   int positions=CountOurPositions();
   if(positions>=InpMaxOpenPositions) return;
   if(!InpEnableStacking && positions>0) return;
   if(TimeCurrent()-g_last_cycle_time<InpMinSecondsBetweenCycles) return;
   if(InpRequireMomentumForRearm && positions>0 && !g_momentum_up && !g_momentum_down && !g_micro_up && !g_micro_down) return;

   MqlTick tick;
   if(!SymbolInfoTick(g_symbol,tick)) return;
   double dist=CalculateEntryDistance();
   if(dist<=0) return;
   double point=PointValue();
   long stops=SymbolInfoInteger(g_symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minDist=(stops+2)*point;
   double buyPrice=NormalizePrice(MathMax(tick.ask+dist,tick.ask+minDist));
   double sellPrice=NormalizePrice(MathMin(tick.bid-dist,tick.bid-minDist));
   double lot=SelectEntryLot();
   if(lot<=0) return;
   datetime expiry=(InpPendingExpiryMinutes>0 ? TimeCurrent()+InpPendingExpiryMinutes*60 : 0);

   ulong buyTicket,sellTicket; double buyOld,sellOld; datetime bt,st;
   bool hasBuy=FindPending(ORDER_TYPE_BUY_STOP,buyTicket,buyOld,bt);
   bool hasSell=FindPending(ORDER_TYPE_SELL_STOP,sellTicket,sellOld,st);
   double reprice=InpPendingRepricePoints*point;

   if(!hasBuy)
   {
      double sl=buyPrice-MathMax(g_atr*InpInitialSL_ATRMultiplier,InpTrailMinDistancePoints*point);
      SendPending(ORDER_TYPE_BUY_STOP,lot,buyPrice,sl,expiry,"GH_BUY_STOP");
   }
   else if(MathAbs(buyOld-buyPrice)>=reprice && InpCancelStalePendings)
   {
      if(DeleteOrder(buyTicket))
      {
         double sl=buyPrice-MathMax(g_atr*InpInitialSL_ATRMultiplier,InpTrailMinDistancePoints*point);
         SendPending(ORDER_TYPE_BUY_STOP,lot,buyPrice,sl,expiry,"GH_BUY_STOP_R");
      }
   }

   if(!hasSell)
   {
      double sl=sellPrice+MathMax(g_atr*InpInitialSL_ATRMultiplier,InpTrailMinDistancePoints*point);
      SendPending(ORDER_TYPE_SELL_STOP,lot,sellPrice,sl,expiry,"GH_SELL_STOP");
   }
   else if(MathAbs(sellOld-sellPrice)>=reprice && InpCancelStalePendings)
   {
      if(DeleteOrder(sellTicket))
      {
         double sl=sellPrice+MathMax(g_atr*InpInitialSL_ATRMultiplier,InpTrailMinDistancePoints*point);
         SendPending(ORDER_TYPE_SELL_STOP,lot,sellPrice,sl,expiry,"GH_SELL_STOP_R");
      }
   }
   g_last_cycle_time=TimeCurrent();
}

//--------------------------- ADAPTIVE TRAILING ----------------------
void ManageAdaptiveTrailing()
{
   if(!InpEnableAdaptiveTrailing || g_atr<=0) return;
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol,tick)) return;
   double point=PointValue();
   if(point<=0) return;
   long stops=SymbolInfoInteger(g_symbol,SYMBOL_TRADE_STOPS_LEVEL);
   long freeze=SymbolInfoInteger(g_symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   double brokerMin=(MathMax(stops,freeze)+2)*point;
   double speedRatio=(g_slow_speed>0.000001 ? g_fast_speed/g_slow_speed : 1.0);
   bool tighten=(speedRatio<InpTrailTightenMomentumRatio);
   double mult=(tighten ? InpTrailATRMultiplierSlow : InpTrailATRMultiplierFast);
   double distance=MathMax(InpTrailMinDistancePoints*point,g_atr*mult);
   distance=MathMax(distance,brokerMin);

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_symbol || (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double oldSL=PositionGetDouble(POSITION_SL);
      double profitMove=(type==POSITION_TYPE_BUY ? tick.bid-open : open-tick.ask);
      if(profitMove < g_atr*InpTrailActivationATR) continue;

      double candidate=(type==POSITION_TYPE_BUY ? tick.bid-distance : tick.ask+distance);
      candidate=NormalizePrice(candidate);
      bool improve=false;
      if(type==POSITION_TYPE_BUY)
      {
         if(candidate<tick.bid-brokerMin && (oldSL==0.0 || candidate>oldSL+InpTrailMinStepPoints*point)) improve=true;
      }
      else
      {
         if(candidate>tick.ask+brokerMin && (oldSL==0.0 || candidate<oldSL-InpTrailMinStepPoints*point)) improve=true;
      }
      if(improve) ModifyPositionSL(ticket,candidate);
   }
}

//--------------------------- OPTIONAL MOMENTUM EXIT -----------------
void ManageMomentumExit()
{
   if(!InpEnableMomentumExit) return;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_symbol || (ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool reverse=(type==POSITION_TYPE_BUY ? g_momentum_down : g_momentum_up);
      if(reverse && g_directional_ratio>=InpMinDirectionalRatio)
         Log(StringFormat("Momentum reversal detected for position %I64u; trailing remains responsible for exit in v1.00.",ticket));
   }
}

//--------------------------- HISTORY RECONCILIATION ------------------
bool DealAlreadySeen(ulong ticket)
{
   for(int i=0;i<ArraySize(g_seen_deal_tickets);i++) if(g_seen_deal_tickets[i]==ticket) return true;
   return false;
}

void ReconcileHistory()
{
   datetime from=TimeCurrent()-86400*30;
   if(!HistorySelect(from,TimeCurrent())) return;
   int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
   {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0 || DealAlreadySeen(deal)) continue;
      if(HistoryDealGetString(deal,DEAL_SYMBOL)!=g_symbol) continue;
      if((ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagicNumber) continue;
      int n=ArraySize(g_seen_deal_tickets);
      ArrayResize(g_seen_deal_tickets,n+1);
      g_seen_deal_tickets[n]=deal;
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY);
      Log(StringFormat("History reconciliation: deal=%I64u entry=%s volume=%.2f price=%.*f",deal,EnumToString(entry),HistoryDealGetDouble(deal,DEAL_VOLUME),DigitsValue(),HistoryDealGetDouble(deal,DEAL_PRICE)));
   }
}

//--------------------------- STATUS ----------------------------------
void UpdateStatus()
{
   if(!InpShowChartStatus) return;
   string mode=(TradingPermitted()?"LIVE PERMITTED":"RESEARCH / SIGNAL ONLY");
   string state="NEUTRAL";
   if(g_momentum_up) state="BULLISH MOMENTUM";
   if(g_momentum_down) state="BEARISH MOMENTUM";
   if(!g_momentum_up && !g_momentum_down && g_micro_up) state="MICRO UP MOVE";
   if(!g_momentum_up && !g_momentum_down && g_micro_down) state="MICRO DOWN MOVE";
   Comment("XTRD OMIGA - GOLD HUNTER v1.00\n",
           "Symbol: ",g_symbol," | Mode: ",mode,"\n",
           "Market: ",state,"\n",
           "Fast speed: ",DoubleToString(g_fast_speed,2)," pts/s | Slow: ",DoubleToString(g_slow_speed,2)," pts/s\n",
           "Direction ratio: ",DoubleToString(g_directional_ratio,2)," | Net move: ",DoubleToString(g_net_move_points,1)," pts\n",
           "ATR: ",DoubleToString(g_atr,DigitsValue())," | Positions: ",CountOurPositions(),"/",InpMaxOpenPositions,
           " | Pendings: ",CountOurPendingOrders());
}

//--------------------------- EVENTS ----------------------------------
int OnInit()
{
   g_symbol=(InpTradeSymbol=="" ? _Symbol : InpTradeSymbol);
   if(!SymbolSelect(g_symbol,true))
   {
      Print("[GOLD_HUNTER] Failed to select symbol: ",g_symbol);
      return INIT_FAILED;
   }
   if(InpMaxOpenPositions<1 || InpInitialLot<=0 || InpMaxLotPerPosition<InpInitialLot || InpFastTickWindow<2 || InpSlowTickWindow<=InpFastTickWindow)
   {
      Print("[GOLD_HUNTER] Invalid inputs. Check position limits, lots and tick windows.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(!IsHedgingAccount())
      Print("[GOLD_HUNTER] WARNING: Account is NETTING. Multiple independent positions on one symbol are not supported; use a HEDGING account for the 16-position design.");

   g_atr_handle=iATR(g_symbol,InpATRTimeframe,InpATRPeriod);
   if(g_atr_handle==INVALID_HANDLE)
   {
      Print("[GOLD_HUNTER] Failed to create ATR handle.");
      return INIT_FAILED;
   }
   ArrayResize(g_seen_deal_tickets,0);
   Log("Initialized. ResearchMode="+(InpResearchMode?"true":"false")+", EnableTrading="+(InpEnableTrading?"true":"false")+", SignalOnly="+(InpSignalOnlyMode?"true":"false"));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_atr_handle!=INVALID_HANDLE) IndicatorRelease(g_atr_handle);
   Comment("");
}

void OnTick()
{
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol,tick)) return;
   PushTick(tick);
   CalculateTickMetrics();
   GetATR(g_atr);

   CancelOppositePendings();
   ManageAdaptiveTrailing();
   ManageMomentumExit();
   ReconcileHistory();

   if(g_tick_count>=InpMinTicksForSignal && g_atr>0 && InpEnableMovementScanner && InpEnableMomentum)
      EnsureDualStops();

   UpdateStatus();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.symbol!="" && trans.symbol!=g_symbol) return;
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong deal=trans.deal;
      if(deal>0 && HistoryDealSelect(deal))
      {
         ulong magic=(ulong)HistoryDealGetInteger(deal,DEAL_MAGIC);
         if(magic==InpMagicNumber)
         {
            Log(StringFormat("TRADE DEAL ADD ticket=%I64u type=%s volume=%.2f price=%.*f",deal,EnumToString((ENUM_DEAL_TYPE)HistoryDealGetInteger(deal,DEAL_TYPE)),HistoryDealGetDouble(deal,DEAL_VOLUME),DigitsValue(),HistoryDealGetDouble(deal,DEAL_PRICE)));
            if(InpEnableOCO) CancelOppositePendings();
         }
      }
   }
   else if(trans.type==TRADE_TRANSACTION_ORDER_ADD || trans.type==TRADE_TRANSACTION_ORDER_UPDATE || trans.type==TRADE_TRANSACTION_ORDER_DELETE)
   {
      Log(StringFormat("TRADE ORDER EVENT type=%s order=%I64u",EnumToString(trans.type),trans.order));
   }
}
//+------------------------------------------------------------------+
