# XTRD OMIGA v2.26 — Technical Audit and Fix Design

Scope: read-only. Original file untouched. No live trading. No risk increase.
All figures are hypotheses to verify, not confirmed results.

## 1. Equations verified in code

| Item | Function | Line | Code |
|---|---|---|---|
| edge init | BuildSignal | 1131 | `double edge=0.0;` |
| micro edge | BuildSignal | 1146,1152 | `(p-0.5)*2.0*atr*InpMicroTargetATR` |
| momentum edge | BuildSignal | 1172,1178 | `(p-0.5)*2.0*atr*InpMomentumTargetATR` |
| exhaustion edge | BuildSignal | 1198,1204 | `(p-0.5)*2.0*atr*0.60` |
| pullback edge | BuildSignal | 1220 | `(pt-0.5)*2.0*atr*InpPullbackTargetATR` |
| min edge gate | BuildSignal | 1224 | `if(edge<InpMinEdgePts) return false;` |
| spread gate | BuildSignal | 1225 | `if(!SpreadGate(edge,spread)) return false;` |
| SL | BuildSignal | 1229 | `ClampD(atr*InpSL_ATR_Multiplier,InpMinSLPts,InpMaxSLPts)` |
| TP | BuildSignal | 1235 | `ClampD(MathMin(atr_target,edge_target),InpMinSLPts,InpMaxSLPts*2.0)` |
| TP ratio gate | BuildSignal | 1236 | `if(s.tp_pts < s.sl_pts*0.85) return false;` |

## 2. Is TP modified after calculation?

No. `s.tp_pts` is written once (1235) and only read afterwards:
- 1236 ratio gate
- 1914 `StopDistancesValid(s.sl_pts,s.tp_pts)`
- 1916 market order price
- 1973 limit order price

Hard bounds: floor `InpMinSLPts`=32, ceiling `InpMaxSLPts*2`=2400.
No account-limit clamp exists on TP; the account constraint acts through lot size, not TP.

## 3. The 0.85 gate and the 31-point figure

- Line 1236: `if(s.tp_pts < s.sl_pts*0.85) return false;`
- The 31 points are NOT from this line. They come from `SpreadGate`, line 941:
  `ratio_floor = spread_pts * MathMax(1.0, InpEdgeToSpreadMin)` = 26 x 1.20 = 31.2
  checked at line 942.
- Application path: both gates sit after all four strategy branches (1224-1236),
  so they apply identically to MICRO, MOMENTUM, EXHAUSTION, PULLBACK.

## 4. Why three engines never reach their gates — algebraic proof

Not inferred from counters. Derived from lines 1146-1236.

With ATR=160, SL=128, spread=26:
- SpreadGate requires edge >= 31.2
- TP gate requires min(160, edge*0.8) >= 108.8, i.e. edge >= 136

| Engine | edge at minimum p | p needed for SpreadGate | p needed for TP gate |
|---|---|---|---|
| MICRO | 5.76 | 0.717 | **1.444** |
| MOMENTUM | 28.80 | 0.608 | **0.972** |
| EXHAUSTION | 7.68 | 0.662 | **1.208** |
| PULLBACK | 11.20 | 0.639 | **1.107** |

p is a probability, so p<=1. MICRO, EXHAUSTION and PULLBACK can never pass
line 1236 at any ATR. MOMENTUM needs p>=0.972.

Root cause: `MathMin(atr_target, edge_target)` makes TP follow the smaller
term, and edge is a fraction of ATR (0.036-0.18 ATR), so TP lands at
7-18% of SL and the 0.85 test rejects it.

The absence of counters for codes 6-23 is therefore NOT used as evidence.
The algebra is the evidence. A per-strategy counter (variant C) is still
required to measure how often each engine is even evaluated.

## 5. Break-even and expectancy

SL=128 points, measured win rate 43.5%.

| RR | TP | BE @26 | E @26 | BE @36 | E @36 | BE @46 | E @46 |
|---|---|---|---|---|---|---|---|
| 1.25 | 160.0 | 53.47% | -28.72 | 56.94% | -38.72 | 60.42% | -48.72 |
| 1.8 | 230.4 | 42.97% | +1.90 | 45.76% | -8.10 | 48.55% | -18.10 |
| 2.0 | 256.0 | 40.10% | +13.04 | 42.71% | +3.04 | 45.31% | -6.96 |
| 2.2 | 281.6 | 37.60% | +24.18 | 40.04% | +14.18 | 42.48% | +4.18 |

Cost 26 = spread only; 36 = spread + 5 pts slippage each side;
46 = spread + 10 pts slippage each side. Values in points per trade.

Only RR>=2.0 survives 10 points of round-trip slippage at 43.5% win rate.
RR=2.2 is the only one that survives 20 points.

## 6. Why rejected-sample win rates differ from executed-trade win rates

1. Selection bias: rejected signals failed a quality gate; executed ones passed.
2. The audit simulated a fixed ATR TP/SL, not the bot's real TP.
3. Simulation excluded spread and slippage.
4. Entry price was the detection price, not the fill price.
5. 60-bar horizon censors unresolved outcomes, so the win/loss ratio is
   computed only over resolved cases.
6. Overlapping signals count the same move many times (correlated samples).
7. 0.05% sampling is uniform in count, not in time.

Therefore 43.5% is an upper-bound estimate for a hypothetical trade set, not
the win rate of any configuration that will actually trade.

## 7. Variant design

A — control: v2.26 unchanged, all defaults.
B — decouple TP from edge:
    replace line 1235 with `s.tp_pts = ClampD(atr*InpRR_Target, InpMinSLPts, InpMaxSLPts*2.0)`
    and add input `InpRR_Target` (1.25 / 1.8 / 2.0 / 2.2). Nothing else changes.
C — B plus independent engine testing:
    add per-strategy counters (evaluated / built / rejected-by-gate / executed),
    add `InpOnlyStrategy` (0=all, 1..4=single) to run each engine alone,
    keep every other gate identical.

## 8. Validation protocol

Available real-tick history is short: the tester log reports real ticks from
2026.10.26, roughly 28 days. Consequences:
- In-sample / OOS on real ticks can only be 4 folds of 7 days.
- Longer history can be screened with M1 OHLC modelling, but results from it
  are screening only and must be confirmed on real ticks.

Folds: F1 10.26-11.01, F2 11.02-11.08, F3 11.09-11.15, F4 11.16-11.22.
Walk-forward: fix parameters on Fn, evaluate on Fn+1, never re-tune on the
evaluation fold. Out-of-sample: parameters chosen on F1+F2, evaluated on F3+F4.

Look-ahead prevention:
- The trading path reads only the tick ring buffer (past data).
- The rejection-audit simulation runs in OnDeinit and must never feed a
  decision. Keep it in the analysis copy only.
- Parameters are frozen before each fold; no optimization inside a fold.
- Report every fold separately; no pooled average that hides a failing fold.

## 9. RiskLot audit with real contract specs, no min-lot override

XAUUSD: contract 100 oz, point 0.01, 1 point = 1.00 USD per 1.0 lot,
volume min 0.01, step 0.01, stops level 0.
LossPerLotForType (line 1335) uses OrderCalcProfit — correct method.

| Item | Value |
|---|---|
| cash budget at 0.5% of 10 USD | 0.05 USD |
| loss per 1.0 lot at SL=128 | 128.00 USD |
| raw lot (line 1477) | 0.00039 |
| NormalizeVolume floor (line 1321) | 0.01 |
| result without override | **0.00 → no trade** |
| cash risk at 0.01 lot, SL=128 | **1.28 USD = 12.8% of equity** |
| max SL for 0.5% risk at 0.01 lot | **5 points** |
| max SL for 1.0% risk at 0.01 lot | **10 points** |

With a 26-point spread, an SL of 5-10 points is below the spread itself.
No risk-compliant trade exists on a 10 USD account at these settings,
independent of any strategy. This is arithmetic, not an opinion.

## 10. Change table

| # | Change | Hypothesis tested | Risk | Pass criterion | Reject criterion |
|---|---|---|---|---|---|
| 1 | B: TP = ATR x RR, RR=1.8 | TP gate stops rejecting everything | win rate falls as TP grows | >=30 trades, PF>1.0, BE beaten | PF<1.0 or <10 trades |
| 2 | B: RR=2.0 | higher RR covers 26-pt spread | win rate collapse | PF>1.15 | PF<1.0 |
| 3 | B: RR=2.2 | survives slippage | too few TP hits | PF>1.2 | <10 trades |
| 4 | C: per-strategy counters | which engines are actually evaluated | none (measurement) | counts > 0 per engine | engine never evaluated |
| 5 | C: single-engine runs | one engine may carry all edge | overfitting to one fold | positive on 2+ folds | positive on 1 fold only |
| 6 | Risk model (no override) | $10 cannot host a compliant trade | none | documented limit | n/a |

No change is adopted before the plan is approved.
