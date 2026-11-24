//+------------------------------------------------------------------+
//|                                        X13_GLOBAL_FINAL.mq5      |
//|  Unified scalping platform. Five independent engines submit      |
//|  opportunities to one central decision engine. Signals, sizing,  |
//|  execution, risk and reporting all run inside MT5.               |
//+------------------------------------------------------------------+
#property copyright "X13 GLOBAL"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//===================== INPUTS ====================//
input group "=== Capital ==="
input double InpRiskPct      = 20.0;   // max risk per trade (% of equity)
input double InpMaxDDHaltPct = 55.0;   // halt all trading past this drawdown
input int    InpMaxPositions = 3;
input bool   InpAllowHedging = true;
input bool   InpAllowPyramiding = true;  // allow adds in the same direction
input double InpMinConsensus = 0.45;     // combined strength needed to act
input bool   InpIndependent  = false;    // each engine trades on its own
input bool   InpInvertSignals = false;   // diagnostic: flip every direction

input group "=== Spread engine ==="
input int    InpMaxSpreadPts = 40;
input double InpMinEVmult    = 1.35;   // required expected move / cost
input double InpMinEdgePts   = 20.0;   // minimum edge above the spread, points

input group "=== Engine 1: burst ==="
input bool   InpEngBurst      = true;
input int    InpBurstLookback = 50;
input double InpBurstVolMult  = 2.0;

input group "=== Engine 2: momentum ==="
input bool   InpEngMomentum = true;
input int    InpMomFast     = 8;
input int    InpMomSlow     = 34;

input group "=== Engine 3: reversion ==="
input bool   InpEngReversion = true;
input double InpRevATRmult   = 2.2;

input group "=== Engine 4: tick flow ==="
input bool   InpEngTickFlow = true;
input int    InpTickWindow  = 200;
input double InpTickRatio   = 0.56;

input group "=== Engine 5: exhaustion ==="
input bool   InpEngExhaustion = true;
input int    InpExhBars       = 5;
input double InpExhATRmult    = 1.6;

input group "=== Exits ==="
input int    InpSlPts      = 110;
input int    InpTpPts      = 190;
input int    InpBeAtPts    = 70;
input int    InpTrailStart = 110;
input int    InpTrailPts   = 70;
input int    InpMaxBars    = 45;

input group "=== Misc ==="
input ulong  InpMagicBase = 14000;
input bool   InpVerbose   = false;
input group "=== Diagnostics ==="
input bool   InpAuditFunnel = true;   // write the opportunity funnel audit

//===================== STATE ====================//
CTrade   g_trade;
int      hATR = INVALID_HANDLE;
int      hEmaF = INVALID_HANDLE, hEmaS = INVALID_HANDLE;
double   g_point = 0, g_tickSize = 1, g_tickValue = 1, g_volPerPt = 0, g_volStep = 0.01;
double   g_volMin = 0.01, g_volMax = 100, g_contract = 100;
int      g_digits = 0;
double   g_initEq = 0;
bool     g_halsted = false;
datetime g_lastBar = 0;

double   g_spSum = 0;
int      g_spN = 0;
double   g_spMedian = 26;

string   g_engName[6] = {"", "BURST", "MOMENTUM", "REVERSION", "TICKFLOW", "EXHAUSTION"};
int      g_slPts[6]  = {0, 60, 110, 90, 70, 80};
int      g_tpPts[6]  = {0, 90, 190, 120, 110, 110};
int      g_sig[6], g_acc[6], g_rej[6];

double   g_buyScore = 0, g_sellScore = 0;
int      g_voteBuy[6], g_voteSell[6];
double   g_tickLastMid = 0;
int      g_tickUp = 0, g_tickDn = 0, g_tickN = 0;
int      g_lastEng = 1;

#define MAX_REJ 60000
datetime g_rejT[MAX_REJ];
int      g_rejDir[MAX_REJ], g_rejEng[MAX_REJ], g_rejWhy[MAX_REJ];
double   g_rejPx[MAX_REJ], g_rejSl[MAX_REJ], g_rejTp[MAX_REJ];
int      g_rejN = 0;

#define R_SPREAD   1
#define R_QUALITY  2
#define R_REGIME   3
#define R_MOMENTUM 4
#define R_COOLDOWN 5
#define R_DUPLICATE 6
#define R_POSLIMIT 7
#define R_MARGIN   8
#define R_RISK     9
#define R_OPPOSITE 10
#define R_EXEC     11
#define R_SESSION  12
#define R_VOLAT    13
#define R_STOPDIST 14
#define R_OTHER    15

void LogRej(int eng, int dir, int why)
  {
   if(g_rejN >= MAX_REJ) return;
   g_rejT[g_rejN]  = TimeCurrent();
   g_rejDir[g_rejN] = dir;
   g_rejEng[g_rejN] = eng;
   g_rejWhy[g_rejN] = why;
   g_rejPx[g_rejN]  = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   g_rejSl[g_rejN]  = g_slPts[eng];
   g_rejTp[g_rejN]  = g_tpPts[eng];
   g_rejN++;
  }

//===================== HELPERS ===================//
double VolPerPoint()
  {
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0) return 0;
   return tv * (g_point / ts);
  }

double SpreadPts()
  {
   return (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / g_point;
  }

bool IsOurPosition()
  {
   int mg = (int)PositionGetInteger(POSITION_MAGIC);
   return (mg >= (int)InpMagicBase && mg <= (int)InpMagicBase + 5);
  }

int CountPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(!IsOurPosition()) continue;
      n++;
     }
   return n;
  }

bool HasSameDir(int dir)
  {
   long want = (dir > 0) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(!IsOurPosition()) continue;
      if((long)PositionGetInteger(POSITION_TYPE) == want) return true;
     }
   return false;
  }

bool HasOpposite(int dir)
  {
   long want = (dir > 0) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(!IsOurPosition()) continue;
      if((long)PositionGetInteger(POSITION_TYPE) == want) return true;
     }
   return false;
  }

double ATRval()
  {
   double b[];
   if(CopyBuffer(hATR, 0, 0, 1, b) != 1) return 0;
   return b[0];
  }

double EmaF()
  {
   double b[];
   if(CopyBuffer(hEmaF, 0, 0, 1, b) != 1) return 0;
   return b[0];
  }

double EmaS()
  {
   double b[];
   if(CopyBuffer(hEmaS, 0, 0, 1, b) != 1) return 0;
   return b[0];
  }

void Submit(int dir, int eng, double strength);

//===================== ENGINES ===================//
void EngBurst()
  {
   if(!InpEngBurst) return;
   double atr = ATRval();
   if(atr <= 0) return;
   double vpp = 0, base = 0;
   for(int k = 1; k <= InpBurstLookback; k++)
     {
      double r = (iHigh(_Symbol, PERIOD_M1, k) - iLow(_Symbol, PERIOD_M1, k)) / g_point;
      double x = (double)iVolume(_Symbol, PERIOD_M1, k) / MathMax(r, 1.0);
      if(k == 1) vpp = x;
      base += x;
     }
   base /= InpBurstLookback;
   if(base <= 0) return;
   double o1 = iOpen(_Symbol, PERIOD_M1, 1);
   double c1 = iClose(_Symbol, PERIOD_M1, 1);
   double body = c1 - o1;
   if(MathAbs(body) < atr * 0.4) return;
   if(vpp < base * InpBurstVolMult) return;
   Submit((body > 0) ? 1 : -1, 1, MathAbs(body) / atr);
  }
void EngMomentum()
  {
   if(!InpEngMomentum) return;
   double atr = ATRval();
   if(atr <= 0) return;
   double f = EmaF(), sl = EmaS();
   if(f <= 0 || sl <= 0) return;
   double c1 = iClose(_Symbol, PERIOD_M1, 1);
   double dF = c1 - iClose(_Symbol, PERIOD_M1, 1 + InpMomFast);
   double dS = c1 - iClose(_Symbol, PERIOD_M1, 1 + InpMomSlow);
   if(dF == 0 || dS == 0) return;
   int sF = (dF > 0) ? 1 : -1;
   int sS = (dS > 0) ? 1 : -1;
   if(sF != sS) return;
   if(sF > 0 && !(c1 > f && f > sl)) return;
   if(sF < 0 && !(c1 < f && f < sl)) return;
   if(MathAbs(dF) < atr * 0.5) return;
   Submit(sF, 2, MathAbs(dF) / atr);
  }
void EngReversion()
  {
   if(!InpEngReversion) return;
   double atr = ATRval();
   if(atr <= 0) return;
   double c1 = iClose(_Symbol, PERIOD_M1, 1);
   double m = 0;
   for(int k = 1; k <= 20; k++) m += iClose(_Symbol, PERIOD_M1, k);
   m /= 20.0;
   double dev = c1 - m;
   if(MathAbs(dev) < atr * InpRevATRmult) return;
   Submit((dev > 0) ? -1 : 1, 3, MathAbs(dev) / atr);
  }
void EngTickFlow()
  {
   if(!InpEngTickFlow) return;
   if(g_tickN < InpTickWindow) return;
   double tot = (double)(g_tickUp + g_tickDn);
   if(tot < 1) return;
   double ratio = (double)g_tickUp / tot;
   if(ratio >= InpTickRatio)
      Submit(1, 4, (ratio - 0.5) * 4.0);
   else if(ratio <= 1.0 - InpTickRatio)
      Submit(-1, 4, (0.5 - ratio) * 4.0);
  }
void EngExhaustion()
  {
   if(!InpEngExhaustion) return;
   double atr = ATRval();
   if(atr <= 0) return;
   int up = 0, dn = 0;
   for(int k = 1; k <= InpExhBars; k++)
     {
      double o = iOpen(_Symbol, PERIOD_M1, k);
      double c = iClose(_Symbol, PERIOD_M1, k);
      if(c > o) up++;
      else if(c < o) dn++;
     }
   if(up < InpExhBars && dn < InpExhBars) return;
   double c1 = iClose(_Symbol, PERIOD_M1, 1);
   double cN = iClose(_Symbol, PERIOD_M1, 1 + InpExhBars);
   double move = MathAbs(c1 - cN);
   if(move < atr * InpExhATRmult) return;
   Submit((c1 > cN) ? -1 : 1, 5, move / atr);
  }

//===================== SIZING ===================//
double SizeLot()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = eq * InpRiskPct / 100.0;
   int eng = MathMax(g_lastEng, 1);
   double lotByRisk = riskMoney / MathMax(g_slPts[eng] * g_volPerPt, 1e-9);

   double margin1 = 0;
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lotByMargin = 0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, price, margin1) && margin1 > 0)
      lotByMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.8 / margin1;
   else
     {
      double notional = g_contract * price;
      double lev = (double)AccountInfoInteger(ACCOUNT_LEVERAGE);
      lotByMargin = (lev > 0) ? AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.8 * lev / notional : 0;
     }

   double lot = MathMin(lotByRisk, lotByMargin);
   lot = MathFloor(lot / g_volStep) * g_volStep;
   if(lot < g_volMin) return 0;
   if(lot > g_volMax) lot = g_volMax;
   return NormalizeDouble(lot, 2);
  }

bool TryEnter(int dir, int eng, double conf)
  {
   if(g_halsted) { LogRej(eng, dir, R_RISK); return false; }
   if(CountPositions() >= InpMaxPositions) { LogRej(eng, dir, R_POSLIMIT); return false; }
   if(HasSameDir(dir) && !InpAllowPyramiding) { LogRej(eng, dir, R_DUPLICATE); return false; }
   if(!InpAllowHedging && HasOpposite(dir)) { LogRej(eng, dir, R_OPPOSITE); return false; }

   double sp = SpreadPts();
   if(sp > InpMaxSpreadPts) { LogRej(eng, dir, R_SPREAD); return false; }

   double atr = ATRval();
   if(atr <= 0) { LogRej(eng, dir, R_VOLAT); return false; }

   double expMove = MathMin(250.0, conf * (atr / g_point));
   if(expMove < sp + InpMinEdgePts) { LogRej(eng, dir, R_QUALITY); return false; }

   g_lastEng = eng;
   double lot = SizeLot();
   if(lot <= 0) { LogRej(eng, dir, R_MARGIN); return false; }
   double confScale = MathMin(1.0, 0.55 + conf * 0.25);
   lot = MathFloor((lot * confScale) / g_volStep) * g_volStep;
   if(lot < g_volMin) lot = g_volMin;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   g_trade.SetExpertMagicNumber(InpMagicBase + eng);

   bool ok;
   if(dir > 0)
      ok = g_trade.Buy(lot, _Symbol, 0.0,
                       NormalizeDouble(ask - g_slPts[eng] * g_point, g_digits),
                       NormalizeDouble(ask + g_tpPts[eng] * g_point, g_digits),
                       g_engName[eng]);
   else
      ok = g_trade.Sell(lot, _Symbol, 0.0,
                        NormalizeDouble(bid + g_slPts[eng] * g_point, g_digits),
                        NormalizeDouble(bid - g_tpPts[eng] * g_point, g_digits),
                        g_engName[eng]);

   if(ok) g_acc[eng]++;
   return ok;
  }

void Submit(int dir, int eng, double strength)
  {
   if(strength <= 0) return;
   if(InpInvertSignals) dir = -dir;
   if(InpIndependent)
     {
      g_sig[eng]++;
      TryEnter(dir, eng, strength);
      return;
     }
   if(dir > 0) { g_buyScore += strength; g_voteBuy[eng]++; }
   else        { g_sellScore += strength; g_voteSell[eng]++; }
  }

void DecideAndExecute()
  {
   double b = g_buyScore, sScore = g_sellScore;
   g_buyScore = 0;
   g_sellScore = 0;
   int votesB = 0, votesS = 0;
   for(int e = 1; e <= 5; e++)
     {
      votesB += g_voteBuy[e];
      votesS += g_voteSell[e];
      g_voteBuy[e] = 0;
      g_voteSell[e] = 0;
     }
   if(InpIndependent) return;

   int dir = 0;
   double conf = 0;
   if(b >= sScore * 1.15 && b >= InpMinConsensus)           { dir = 1;  conf = b; }
   else if(sScore >= b * 1.15 && sScore >= InpMinConsensus) { dir = -1; conf = sScore; }
   if(dir == 0) return;

   int eng = (dir > 0) ? ((votesB >= votesS) ? 1 : 2) : ((votesS >= votesB) ? 1 : 2);
   if(votesB + votesS >= 2) eng = 5;
   TryEnter(dir, eng, conf);
  }

//===================== MANAGEMENT ===================//
void Manage()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(!IsOurPosition()) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double cur = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                               : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double gain = (type == POSITION_TYPE_BUY) ? (cur - op) / g_point : (op - cur) / g_point;

      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(InpMaxBars > 0 && (TimeCurrent() - opened) > InpMaxBars * 60)
        {
         g_trade.PositionClose(t);
         continue;
        }

      int e = (int)PositionGetInteger(POSITION_MAGIC) - (int)InpMagicBase;
      if(e < 1 || e > 5) e = 2;
      double beAt = g_tpPts[e] * 0.40;
      double trailStart = g_tpPts[e] * 0.60;
      double trailPts = g_slPts[e] * 0.60;

      double newSl = sl;
      if(gain >= trailStart)
         newSl = (type == POSITION_TYPE_BUY) ? cur - trailPts * g_point
                                             : cur + trailPts * g_point;
      else if(gain >= beAt)
         newSl = op;

      if(newSl != sl)
        {
         bool better = (type == POSITION_TYPE_BUY) ? (newSl > sl) : (newSl < sl || sl == 0);
         if(better && MathAbs(cur - newSl) / g_point > 15)
            g_trade.PositionModify(t, NormalizeDouble(newSl, g_digits), tp);
        }
     }
  }

//===================== LIFECYCLE ===================//
int OnInit()
  {
   g_point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   g_volMin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_volMax    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_volStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   g_contract  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(g_point <= 0 || g_tickSize <= 0 || g_tickValue <= 0 || g_volStep <= 0) return INIT_FAILED;
   g_volPerPt = VolPerPoint();

   hATR = iATR(_Symbol, PERIOD_M1, 14);
   hEmaF = iMA(_Symbol, PERIOD_M1, InpMomFast, 0, MODE_EMA, PRICE_CLOSE);
   hEmaS = iMA(_Symbol, PERIOD_M1, InpMomSlow, 0, MODE_EMA, PRICE_CLOSE);
   if(hATR == INVALID_HANDLE || hEmaF == INVALID_HANDLE || hEmaS == INVALID_HANDLE) return INIT_FAILED;

   g_slPts[1] = InpSlPts;
   g_tpPts[1] = InpTpPts;
   g_slPts[2] = (int)(InpSlPts * 1.8); g_tpPts[2] = (int)(InpTpPts * 2.1);
   g_slPts[3] = (int)(InpSlPts * 1.5); g_tpPts[3] = (int)(InpTpPts * 1.3);
   g_slPts[4] = (int)(InpSlPts * 1.2); g_tpPts[4] = (int)(InpTpPts * 1.2);
   g_slPts[5] = (int)(InpSlPts * 1.3); g_tpPts[5] = (int)(InpTpPts * 1.2);

   g_trade.SetDeviationInPoints(50);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_initEq = AccountInfoDouble(ACCOUNT_EQUITY);

   PrintFormat("X13 FINAL start eq=%.2f volPerPt=%.5f minLot=%.3f step=%.3f contract=%.1f marginMode=%d",
               g_initEq, g_volPerPt, g_volMin, g_volStep, g_contract,
               (int)AccountInfoInteger(ACCOUNT_MARGIN_MODE));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hEmaF != INVALID_HANDLE) IndicatorRelease(hEmaF);
   if(hEmaS != INVALID_HANDLE) IndicatorRelease(hEmaS);
   PrintFormat("X13 FINAL end eq=%.2f", AccountInfoDouble(ACCOUNT_EQUITY));
  }

void OnTick()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(!g_halsted && g_initEq > 0 && eq <= g_initEq * (1.0 - InpMaxDDHaltPct / 100.0))
     {
      g_halsted = true;
      Print("X13 FINAL: drawdown halt engaged");
     }

   double sp = SpreadPts();
   g_spSum += sp;
   g_spN++;
   if(g_spN >= 1000)
     {
      g_spMedian = g_spSum / g_spN;
      g_spSum = 0;
      g_spN = 0;
     }

   double mid = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) * 0.5;
   if(g_tickLastMid > 0)
     {
      if(mid > g_tickLastMid) g_tickUp++;
      else if(mid < g_tickLastMid) g_tickDn++;
      g_tickN++;
     }
   g_tickLastMid = mid;

   Manage();

   datetime bar = iTime(_Symbol, PERIOD_M1, 0);
   if(bar == 0 || bar == g_lastBar) return;
   g_lastBar = bar;

   EngBurst();
   EngMomentum();
   EngReversion();
   EngTickFlow();
   EngExhaustion();
   DecideAndExecute();
   g_tickUp = 0;
   g_tickDn = 0;
   g_tickN  = 0;
  }

//===================== REJECTION AUDIT ===================//
void WriteRejectAudit()
  {
   if(g_rejN <= 0) return;
   int bars = Bars(_Symbol, PERIOD_M1);
   if(bars < 50) return;
   MqlRates r[];
   int got = CopyRates(_Symbol, PERIOD_M1, 0, bars, r);
   if(got < 50) return;

   int win[6][16], los[6][16], cnt[6][16];
   ArrayInitialize(win, 0);
   ArrayInitialize(los, 0);
   ArrayInitialize(cnt, 0);

   int ptr = 0;
   for(int k = 0; k < g_rejN; k++)
     {
      int e = MathMin(MathMax(g_rejEng[k], 1), 5);
      int w = MathMin(MathMax(g_rejWhy[k], 1), 15);
      cnt[e][w]++;
      while(ptr < got - 1 && r[ptr].time < g_rejT[k]) ptr++;
      if(ptr >= got - 1) continue;
      double px = g_rejPx[k];
      double tp = g_rejTp[k] * g_point;
      double sl = g_rejSl[k] * g_point;
      int dir = g_rejDir[k];
      int end = MathMin(ptr + 60, got - 1);
      for(int j = ptr + 1; j <= end; j++)
        {
         if(dir > 0)
           {
            if(r[j].high >= px + tp) { win[e][w]++; break; }
            if(r[j].low  <= px - sl) { los[e][w]++; break; }
           }
         else
           {
            if(r[j].low  <= px - tp) { win[e][w]++; break; }
            if(r[j].high >= px + sl) { los[e][w]++; break; }
           }
        }
     }

   int h = FileOpen("X13_Reject_" + _Symbol + ".csv",
                    FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE) return;
   FileWrite(h, "engine", "reason", "count", "would_win", "would_lose", "net_usd_001");
   for(int e = 1; e <= 5; e++)
      for(int w = 1; w <= 15; w++)
        {
         if(cnt[e][w] == 0) continue;
         double net = (win[e][w] * g_tpPts[e] - los[e][w] * g_slPts[e]
                       - cnt[e][w] * g_spMedian) * g_volPerPt * 0.01;
         FileWrite(h, g_engName[e], IntegerToString(w), IntegerToString(cnt[e][w]),
                   IntegerToString(win[e][w]), IntegerToString(los[e][w]),
                   DoubleToString(net, 2));
        }
   FileClose(h);
   PrintFormat("X13 rejection audit -> X13_Reject_%s.csv (%d rejected)", _Symbol, g_rejN);
  }

//===================== FUNNEL AUDIT ===================//
void WriteFunnel()
  {
   if(!InpAuditFunnel) return;
   int n = Bars(_Symbol, PERIOD_M1);
   if(n < 100) return;
   MqlRates r[];
   int got = CopyRates(_Symbol, PERIOD_M1, 0, n, r);
   if(got <= 0) return;

   int h = FileOpen("X13_Funnel_" + _Symbol + ".csv", FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE) return;
   FileWrite(h, "horizon_bars", "bars", "opp_over_spread", "opp_over_3x_spread",
             "opp_per_day", "hindsight_max_usd_at_001", "actual_trades", "capture_pct");

   int horizons[3] = {5, 15, 60};
   double sp = MathMax(g_spMedian, 1.0);
   for(int q = 0; q < 3; q++)
     {
      int K = horizons[q];
      int opp = 0, big = 0;
      double maxUsd = 0;
      for(int i = 0; i + K < got; i++)
        {
         double fwd = (r[i + K].close - r[i].close) / g_point;
         double af = MathAbs(fwd);
         if(af > sp)
           {
            opp++;
            maxUsd += (af - sp) * g_volPerPt * 0.01;
           }
         if(af > sp * 3.0) big++;
        }
      int spanMin = (int)((r[got - 1].time - r[0].time) / 60);
      double days = MathMax(spanMin / 1440.0, 1.0);
      double trades = TesterStatistics(STAT_TRADES);
      FileWrite(h, IntegerToString(K), IntegerToString(got), IntegerToString(opp),
                IntegerToString(big), DoubleToString(opp / days, 0),
                DoubleToString(maxUsd, 2), DoubleToString(trades, 0),
                DoubleToString(100.0 * trades / MathMax(opp, 1), 2));
     }
   FileClose(h);
   PrintFormat("X13 funnel -> X13_Funnel_%s.csv", _Symbol);
  }

//===================== NATIVE REPORT ===================//
double OnTester()
  {
   double engPnL[6];
   ArrayInitialize(engPnL, 0.0);
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      if(!HistoryDealSelect(t)) continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol) continue;
      int mg = (int)HistoryDealGetInteger(t, DEAL_MAGIC);
      int e = mg - (int)InpMagicBase;
      if(e < 1 || e > 5) continue;
      engPnL[e] += HistoryDealGetDouble(t, DEAL_PROFIT)
                 + HistoryDealGetDouble(t, DEAL_SWAP)
                 + HistoryDealGetDouble(t, DEAL_COMMISSION);
     }

   WriteRejectAudit();
   WriteFunnel();

   double dealSum = 0.0;
   int dealCount = 0;
   for(int i = 0; i < total; i++)
     {
      ulong tt = HistoryDealGetTicket(i);
      if(tt == 0) continue;
      if(!HistoryDealSelect(tt)) continue;
      if(HistoryDealGetInteger(tt, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      if(HistoryDealGetString(tt, DEAL_SYMBOL) != _Symbol) continue;
      dealSum += HistoryDealGetDouble(tt, DEAL_PROFIT)
               + HistoryDealGetDouble(tt, DEAL_SWAP)
               + HistoryDealGetDouble(tt, DEAL_COMMISSION);
      dealCount++;
     }
   double statProfit = TesterStatistics(STAT_PROFIT);

   string f = "X13_Native_" + _Symbol + ".csv";
   int h = FileOpen(f, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE) return 0.0;

   FileWrite(h, "metric", "value");
   FileWrite(h, "net_profit",       DoubleToString(TesterStatistics(STAT_PROFIT), 2));
   FileWrite(h, "gross_profit",     DoubleToString(TesterStatistics(STAT_GROSS_PROFIT), 2));
   FileWrite(h, "gross_loss",       DoubleToString(TesterStatistics(STAT_GROSS_LOSS), 2));
   FileWrite(h, "profit_factor",    DoubleToString(TesterStatistics(STAT_PROFIT_FACTOR), 3));
   FileWrite(h, "expected_payoff",  DoubleToString(TesterStatistics(STAT_EXPECTED_PAYOFF), 3));
   FileWrite(h, "trades",           DoubleToString(TesterStatistics(STAT_TRADES), 0));
   FileWrite(h, "profit_trades",    DoubleToString(TesterStatistics(STAT_PROFIT_TRADES), 0));
   FileWrite(h, "loss_trades",      DoubleToString(TesterStatistics(STAT_LOSS_TRADES), 0));
   FileWrite(h, "win_pct",          DoubleToString(100.0 * TesterStatistics(STAT_PROFIT_TRADES) /
                                                  MathMax(TesterStatistics(STAT_TRADES), 1), 1));
   FileWrite(h, "equity_dd",        DoubleToString(TesterStatistics(STAT_EQUITY_DD), 2));
   FileWrite(h, "equity_dd_pct",    DoubleToString(TesterStatistics(STAT_EQUITYDD_PERCENT), 2));
   FileWrite(h, "recovery",         DoubleToString(TesterStatistics(STAT_RECOVERY_FACTOR), 3));
   FileWrite(h, "sharpe",           DoubleToString(TesterStatistics(STAT_SHARPE_RATIO), 3));
   FileWrite(h, "initial_deposit",  DoubleToString(TesterStatistics(STAT_INITIAL_DEPOSIT), 2));
   FileWrite(h, "final_balance",    DoubleToString(TesterStatistics(STAT_INITIAL_DEPOSIT) +
                                                   TesterStatistics(STAT_PROFIT), 2));
   FileWrite(h, "spread_median_pts", DoubleToString(g_spMedian, 2));
   FileWrite(h, "audit_deal_sum",    DoubleToString(dealSum, 2));
   FileWrite(h, "audit_deal_count",  IntegerToString(dealCount));
   FileWrite(h, "audit_stat_profit", DoubleToString(statProfit, 2));
   FileWrite(h, "audit_mismatch",    DoubleToString(dealSum - statProfit, 4));

   for(int e = 1; e <= 5; e++)
     {
      FileWrite(h, "eng" + IntegerToString(e) + "_name", g_engName[e]);
      FileWrite(h, "eng" + IntegerToString(e) + "_signals", IntegerToString(g_sig[e]));
      FileWrite(h, "eng" + IntegerToString(e) + "_accepted", IntegerToString(g_acc[e]));
      FileWrite(h, "eng" + IntegerToString(e) + "_rejected", IntegerToString(g_rej[e]));
      FileWrite(h, "eng" + IntegerToString(e) + "_pnl", DoubleToString(engPnL[e], 2));
     }

   FileClose(h);

   // one result file per optimisation pass, named by its parameters
   string tag = StringFormat("X13_Opt_%d_%d_%d_%d_%d",
                             (int)InpSlPts, (int)InpTpPts, (int)InpMinEdgePts,
                             (int)(InpMinConsensus * 100), InpMaxPositions);
   int ho = FileOpen(tag + ".csv", FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(ho != INVALID_HANDLE)
     {
      FileWrite(ho, "sl", "tp", "edge", "cons", "maxpos", "net", "trades",
                "win", "pf", "ddpct", "final");
      FileWrite(ho,
                DoubleToString(InpSlPts, 0), DoubleToString(InpTpPts, 0),
                DoubleToString(InpMinEdgePts, 0), DoubleToString(InpMinConsensus, 2),
                IntegerToString(InpMaxPositions),
                DoubleToString(TesterStatistics(STAT_PROFIT), 2),
                DoubleToString(TesterStatistics(STAT_TRADES), 0),
                DoubleToString(100.0 * TesterStatistics(STAT_PROFIT_TRADES) /
                              MathMax(TesterStatistics(STAT_TRADES), 1), 1),
                DoubleToString(TesterStatistics(STAT_PROFIT_FACTOR), 3),
                DoubleToString(TesterStatistics(STAT_EQUITYDD_PERCENT), 2),
                DoubleToString(TesterStatistics(STAT_INITIAL_DEPOSIT) +
                              TesterStatistics(STAT_PROFIT), 2));
      FileClose(ho);
     }

   PrintFormat("X13 FINAL native report -> %s", f);
   return TesterStatistics(STAT_PROFIT);
  }
//+------------------------------------------------------------------+
