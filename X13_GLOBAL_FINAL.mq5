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

input group "=== Spread engine ==="
input int    InpMaxSpreadPts = 40;
input double InpMinEVmult    = 1.35;   // required expected move / cost

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

input group "=== Engine 4: breakout ==="
input bool   InpEngBreakout = true;
input int    InpBreakBars   = 20;

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

string   g_engName[6] = {"", "BURST", "MOMENTUM", "REVERSION", "BREAKOUT", "EXHAUSTION"};
int      g_slPts[6]  = {0, 60, 110, 90, 100, 80};
int      g_tpPts[6]  = {0, 90, 190, 120, 200, 110};
int      g_sig[6], g_acc[6], g_rej[6];

int      g_sigDir = 0, g_sigEng = 0;
double   g_sigScore = 0;

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

void Submit(int dir, int eng, double strength)
  {
   if(g_sigDir == 0 || strength > g_sigScore)
     {
      g_sigDir = dir;
      g_sigEng = eng;
      g_sigScore = strength;
     }
  }

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
   g_sig[1]++;
   Submit((body > 0) ? 1 : -1, 1, MathAbs(body) / atr);
  }

void EngMomentum()
  {
   if(!InpEngMomentum) return;
   double atr = ATRval();
   if(atr <= 0) return;
   double f = EmaF(), s = EmaS();
   if(f <= 0 || s <= 0) return;
   double c1 = iClose(_Symbol, PERIOD_M1, 1);
   double dF = c1 - iClose(_Symbol, PERIOD_M1, 1 + InpMomFast);
   double dS = c1 - iClose(_Symbol, PERIOD_M1, 1 + InpMomSlow);
   if(dF == 0 || dS == 0) return;
   int sF = (dF > 0) ? 1 : -1;
   int sS = (dS > 0) ? 1 : -1;
   if(sF != sS) return;
   if(sF > 0 && !(c1 > f && f > s)) return;
   if(sF < 0 && !(c1 < f && f < s)) return;
   if(MathAbs(dF) < atr * 0.5) return;
   g_sig[2]++;
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
   g_sig[3]++;
   Submit((dev > 0) ? -1 : 1, 3, MathAbs(dev) / atr);
  }

void EngBreakout()
  {
   if(!InpEngBreakout) return;
   double atr = ATRval();
   if(atr <= 0) return;
   double hh = -1e18, ll = 1e18;
   for(int k = 1; k <= InpBreakBars; k++)
     {
      hh = MathMax(hh, iHigh(_Symbol, PERIOD_M1, k));
      ll = MathMin(ll, iLow(_Symbol, PERIOD_M1, k));
     }
   double c1 = iClose(_Symbol, PERIOD_M1, 1);
   if(c1 > hh) { g_sig[4]++; Submit(1, 4, (c1 - hh) / atr + 1.0); }
   else if(c1 < ll) { g_sig[4]++; Submit(-1, 4, (ll - c1) / atr + 1.0); }
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
   g_sig[5]++;
   Submit((c1 > cN) ? -1 : 1, 5, move / atr);
  }

//===================== SIZING ===================//
double SizeLot()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = eq * InpRiskPct / 100.0;
   double lotByRisk = riskMoney / MathMax(g_slPts[MathMax(g_sigEng,1)] * g_volPerPt, 1e-9);

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

//===================== DECISION ===================//
void DecideAndExecute()
  {
   if(g_sigDir == 0) return;
   int dir = g_sigDir, eng = g_sigEng;
   double score = g_sigScore;
   g_sigDir = 0;
   g_sigScore = 0;

   if(g_halsted) { g_rej[eng]++; return; }
   if(CountPositions() >= InpMaxPositions) { g_rej[eng]++; return; }
   if(HasSameDir(dir)) { g_rej[eng]++; return; }
   if(!InpAllowHedging && HasOpposite(dir)) { g_rej[eng]++; return; }

   double sp = SpreadPts();
   if(sp > InpMaxSpreadPts) { g_rej[eng]++; return; }

   double atr = ATRval();
   if(atr <= 0) { g_rej[eng]++; return; }

   double expMove = MathMin((double)g_tpPts[eng], score * (atr / g_point));
   if(expMove < sp + 20.0) { g_rej[eng]++; return; }
   if(expMove < sp * InpMinEVmult) { g_rej[eng]++; return; }

   double lot = SizeLot();
   if(lot <= 0) { g_rej[eng]++; return; }

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
   else
     {
      g_rej[eng]++;
      if(InpVerbose) PrintFormat("X13 %s order failed %d", g_engName[eng], g_trade.ResultRetcode());
     }
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

   Manage();

   datetime bar = iTime(_Symbol, PERIOD_M1, 0);
   if(bar == 0 || bar == g_lastBar) return;
   g_lastBar = bar;

   g_sigDir = 0;
   g_sigScore = 0;
   EngBurst();
   EngMomentum();
   EngReversion();
   EngBreakout();
   EngExhaustion();
   DecideAndExecute();
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

   for(int e = 1; e <= 5; e++)
     {
      FileWrite(h, "eng" + IntegerToString(e) + "_name", g_engName[e]);
      FileWrite(h, "eng" + IntegerToString(e) + "_signals", IntegerToString(g_sig[e]));
      FileWrite(h, "eng" + IntegerToString(e) + "_accepted", IntegerToString(g_acc[e]));
      FileWrite(h, "eng" + IntegerToString(e) + "_rejected", IntegerToString(g_rej[e]));
      FileWrite(h, "eng" + IntegerToString(e) + "_pnl", DoubleToString(engPnL[e], 2));
     }

   FileClose(h);
   PrintFormat("X13 FINAL native report -> %s", f);
   return TesterStatistics(STAT_PROFIT);
  }
//+------------------------------------------------------------------+
