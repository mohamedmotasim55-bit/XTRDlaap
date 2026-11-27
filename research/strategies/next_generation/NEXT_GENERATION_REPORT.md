# Next-Generation Strategy Report

Capital fixed **10 USD**. events=24626 disc/val/oos=14623/5499/4482.
Families: ['COMPRESSION_BREAK', 'IMPULSE', 'SESSION', 'SWEEP']. Spread ~26 pts.

POSITIVE cells: 0 | POSITIVE in OOS: 0

## Ranking

rank,family,best_side,best_horizon,n,mean_net,verdict,oos_positive
1,COMPRESSION_BREAK,SELL,1800s,689,46.62,inconclusive,no
2,SWEEP,SELL,1800s,2691,37.21,inconclusive,no
3,IMPULSE,SELL,1800s,3363,0.53,inconclusive,no
4,SESSION,SELL,600s,465,-15.93,inconclusive,no

## Family best (discovery)

- COMPRESSION_BREAK SELL 1800s: n=689 mean_net=46.62 inconclusive
- SWEEP SELL 1800s: n=2691 mean_net=37.21 inconclusive
- IMPULSE SELL 1800s: n=3363 mean_net=0.53 inconclusive
- SESSION SELL 600s: n=465 mean_net=-15.93 inconclusive

## Decision
**No next-generation family produced a positive-expectancy cell out-of-sample after real cost.** No EA delivered. Cross-asset data missing - next step is to collect DXY/silver/news and re-test.

## CRITICAL FINDING: the 1800s "SELL edge" is a PERIOD DRIFT artifact

At 1800s the raw per-family table showed SELL cells positive (COMPRESSION_BREAK +46.6, SWEEP +37.2). Reverse-baseline + clustering test:

| family | BUY net (1800s, clustered) | SELL net (1800s, clustered) |
|---|---:|---:|
| COMPRESSION_BREAK | -76.23 | +33.06 |
| IMPULSE | -78.61 | +5.29 |
| SWEEP | -60.21 | +23.78 |
| SESSION | -38.71 | -4.40 |

**BUY is strongly negative and SELL positive for EVERY family** -> the market drifted DOWN ~50 pts per 30 min over the 59-day sample (2026-09-28..11-25). The SELL "profit" is the market drift, not conditional information. If the drift reverses, SELL loses. Reverse-signal baseline confirms: BUY loses ~the mirror of SELL.

Additional disqualifiers for the 1800s cells:
- CIs include 0 (inconclusive) due to huge variance (moves of 100-200+ pts).
- 30-min holding on $10 / 0.01 lot: a 100-pt move = $1 = 10% equity -> unacceptable risk.
- SWEEP SELL: validation NEGATIVE (-49.8) -> unstable.
- Overlapping events inflate naive significance; clustering confirms drift explanation.

## CROSS-ASSET
Not tested: no DXY / XAGUSD / bond-yield / news data exists in the MT5 XAUUSD.m tick feed. Documented in CROSS_ASSET_RESULTS.csv as NOT_TESTED. This is the single biggest missing information source.

## DECISION: no strategy adopted
0 POSITIVE cells in discovery and 0 in OOS after real cost. All apparent edges are either (a) smaller than the 26-pt spread or (b) a period-wide downward drift that is not repeatable. No EA delivered.

## Highest-value next step
Collect external data and re-test cross-asset / news conditioning:
- DXY (or EURUSD proxy) and XAGUSD 1-min bars, timestamped to broker time.
- Economic calendar with release times.
Then test whether gold's post-impulse direction is conditioned by USD/silver moves and news windows - the only untested information source that could plausibly exceed the 26-pt cost.
