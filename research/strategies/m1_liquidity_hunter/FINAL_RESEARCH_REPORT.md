# M1 Liquidity Hunter - Final Research Report

Capital fixed **10 USD**. events=11137 disc/val/oos=6777/2299/2028. Spread ~26 pts.
POSITIVE cells: 0 | POSITIVE in OOS: 0

## Ranking

rank,kind,best_side,best_horizon,n,mean_net,verdict
1,SWEEP_SW_HIGH,SELL,60m,1468,71.83,inconclusive
2,SWEEP_PD_HIGH,SELL,30m,217,42.77,inconclusive
3,WICK_HIGH,SELL,60m,1433,12.2,inconclusive
4,SWEEP_PD_LOW,BUY,5m,236,-26.35,inconclusive
5,SWEEP_SW_LOW,BUY,10m,1910,-28.3,negative
6,WICK_LOW,BUY,1m,1513,-32.25,negative

## Decision
**No liquidity-hunting cell produced positive expectancy out-of-sample after real cost.** No EA delivered. The 26-pt spread exceeds the predictable post-sweep move at all tested horizons/confirmations.

## DATA
- 11,137 events over 59 real-tick days: WICK_HIGH 2518, SWEEP_SW_LOW 3149, WICK_LOW 2478, SWEEP_SW_HIGH 2376, SWEEP_PD_HIGH 240, SWEEP_PD_LOW 383.
- Split discovery/val/oos = 6,777 / 2,299 / 2,028 (3600s embargo).

## RESULTS
### Sweep detection (best cell per kind, discovery)
| kind | side | horizon | n | mean_net | verdict |
|---|---|---|---:|---:|---|
| SWEEP_SW_HIGH | SELL | 60m | 1468 | +71.83 | inconclusive |
| SWEEP_PD_HIGH | SELL | 30m | 217 | +42.77 | inconclusive |
| WICK_HIGH | SELL | 60m | 1433 | +12.20 | inconclusive |
| SWEEP_PD_LOW | BUY | 5m | 236 | -26.35 | inconclusive |
| SWEEP_SW_LOW | BUY | 10m | 1910 | -28.30 | negative |
| WICK_LOW | BUY | 1m | 1513 | -32.25 | negative |

### CRITICAL: the SELL "edge" is period drift again
SELL sweeps positive, BUY sweeps negative, at long horizons -> same downward market drift (~50 pts/30m) as the previous generation. Reverse-signal baseline confirms. Not conditional information.

### Exit 2R/1R first-passage (discovery)
| scope | side | n | mean_pnl | win% |
|---|---|---:|---:|---:|
| ALL | BUY | 3659 | -37.58 | 21.4 |
| ALL | SELL | 3118 | -16.68 | 23.4 |

Win rate 21-24% < 33% breakeven for 2R/1R. Negative expectancy even before considering the stop sits close to the 26-pt spread.

### Confirmation ablation
MSS, displacement, momentum flags did not produce any POSITIVE subset. Adding confirmations reduced sample size without turning expectancy positive.

### Opportunity density
~189 events/day total; the fraction with |5m gross| > spread is small; economically valid opportunities are rare AND unprofitable after cost.

## DECISION: OPTION B (no EA)
No liquidity-hunting cell produced positive expectancy out-of-sample after real cost. Conditions for EA build (requirement 9) are NOT met:
1. net expectancy > 0 after cost: FAILED
2. stable in validation/OOS: FAILED
3. beats baselines: FAILED (it IS the drift baseline)
4. sufficient sample/CI: FAILED (inconclusive)
5. slippage/latency tolerance: FAILED

**Therefore XTRD_M1_LIQUIDITY_HUNTER.mq5 and its reports are intentionally NOT produced.** Per the task's own rule: "لا تنتقل إلى التنفيذ قبل إثبات الميزة."

## What the data proves
On XAUUSD.m JustMarkets Standard (26-pt spread), M1 liquidity sweeps (prev-day, local-swing, wick) do not produce post-sweep moves large enough, consistently enough, to beat execution cost. The only apparent profits are the sample-wide downward drift, which is not repeatable and is symmetric to the losses on the opposite side.
