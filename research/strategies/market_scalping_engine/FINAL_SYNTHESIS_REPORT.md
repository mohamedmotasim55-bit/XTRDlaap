# Market-Only High-Density Scalping Engine — Discovery Report

Capital fixed **10 USD**. Spread 26 pts (real). recs=59147.
Families tested: 8. POSITIVE cells: 0 | POSITIVE in OOS: 0

## Min exploitable move (|gross| distribution)

horizon,p50_abs,p90_abs,p99_abs,pct_gt_spread,n
100ms,0.0,6.0,23.0,0.7,59147
250ms,2.0,14.0,42.0,3.1,59147
500ms,3.0,20.0,58.0,6.3,59147
1s,6.0,29.0,80.0,11.8,59147
2s,10.0,42.0,107.0,21.3,59147
5s,19.0,69.0,165.0,38.6,59147
10s,28.0,95.0,221.0,51.9,59147

## Cost-aware filter (breakeven win% by target)

target_x_spread,target_pts,cost_pts,breakeven_win_pct,note
1,26,26,50.0,need win>50% for EV>0
1.5,39,26,40.0,need win>40% for EV>0
2,52,26,33.3,need win>33% for EV>0
2.5,65,26,28.6,need win>29% for EV>0
3,78,26,25.0,need win>25% for EV>0
4,104,26,20.0,need win>20% for EV>0

## Best cells (all families)

| family | side | h | n/day | gross | net | verdict |
|---|---|---|---:|---:|---:|---|
| CONFLUENCE | BUY | 5s | 42 | - | -21.81 | negative |
| CONFLUENCE | BUY | 2s | 42 | - | -21.99 | negative |
| CONFLUENCE | BUY | 1s | 42 | - | -22.1 | negative |
| CONFLUENCE | SELL | 2s | 42 | - | -22.27 | negative |
| CONFLUENCE | BUY | 10s | 42 | - | -22.31 | negative |
| CONFLUENCE | SELL | 500ms | 42 | - | -22.4 | negative |
| CONFLUENCE | SELL | 1s | 42 | - | -22.5 | negative |
| CONFLUENCE | BUY | 500ms | 42 | - | -22.73 | negative |
| CONFLUENCE | BUY | 250ms | 42 | - | -22.98 | negative |
| CONFLUENCE | SELL | 250ms | 42 | - | -23.03 | negative |

## Decision
**No Market-only scalping family yields positive net expectancy after the real 26-pt spread, at any horizon 100ms-10s.** The min exploitable move test shows the predictable move never clears cost. No EA delivered.

## THE DECISIVE FINDING: predictability and move-size are inversely related

### Min exploitable move (|gross| distribution, all decisions)
| horizon | p50 | p90 | p99 | % moves > 26pt spread |
|---|---:|---:|---:|---:|
| 100ms | 0 | 6 | 23 | **0.7%** |
| 250ms | 2 | 14 | 42 | 3.1% |
| 500ms | 3 | 20 | 58 | 6.3% |
| 1s | 6 | 29 | 80 | 11.8% |
| 2s | 10 | 42 | 107 | 21.3% |
| 5s | 19 | 69 | 165 | 38.6% |
| 10s | 28 | 95 | 221 | 51.9% |

- At the horizon where the signal is most predictive (100-250ms, IG up to 0.022), only **0.7-3.1%** of moves exceed the spread.
- At the horizon where most moves exceed the spread (10s, 51.9%), directional predictability is ~0 (IG 0.0004) -> you cannot select which 52%.
- **The two requirements never coincide.** This is the fundamental, quantified reason no Market-only scalping family works on this feed.

### Best signal vs cost
- Best cell CONFLUENCE BUY 5s: mean_gross = **4.19 pts**, mean_net = **-21.81 pts**.
- The signal's expected move (~4 pts) is **~6.2x smaller than the 26-pt spread**.

### Families tested (all independent, BUY/SELL, 7 horizons)
IMB_Q50/Q70/Q85/Q95, TICKRATE_HI, VOL_HI, CONFLUENCE (imbalance x volatility), REVERSAL_HI.
- **POSITIVE cells: 0** (discovery) | **POSITIVE in OOS: 0**.
- Density: CONFLUENCE ~41.6 opportunities/day; all negative expectancy.

### Cost-aware filter (breakeven win% by target multiple)
| target x spread | target pts | cost pts | breakeven win% |
|---|---:|---:|---:|
| 1.0 | 26 | 26 | 50.0% |
| 1.5 | 39 | 26 | 40.0% |
| 2.0 | 52 | 26 | 33.3% |
| 2.5 | 65 | 26 | 28.6% |
| 3.0 | 78 | 26 | 25.0% |
| 4.0 | 104 | 26 | 20.0% |

To break even with a 1:1 (26pt target) you need >50% win rate; the signal delivers ~50% directional hit with ~0 edge, so EV<=0 at every target.

## VERDICT: no Market-only high-density scalping strategy is viable on this feed
Across 9 research missions, every family (tick momentum, wick rejection, pullback, sweep, exhaustion, volatility expansion, tick imbalance, confluence, regime switching) fails the same test: the predictable move is ~2-6 pts while the spread is 26 pts. The 6.2x gap is structural, not a parameter issue.

**No EA is delivered** because the task's adoption criteria (positive net expectancy, 95% CI, OOS stability, beat baseline, cost tolerance) are not met by any family.

## What would change the verdict (the only real levers)
1. **Spread <= 6-8 pts** (a different account/venue): the 4-pt expected move would then clear cost at 2:1+.
2. **External information (DXY / silver / news)** to raise the conditional expected move above 26 pts - the only untested information source.
3. **Longer-horizon session drift** (H15 showed ~17pt gross at 10s-30m) - but reverse-baseline showed it was sample drift, not signal.

Until one of these changes, additional code on the same 26-pt feed cannot produce positive expectancy. This is proven, not assumed.
