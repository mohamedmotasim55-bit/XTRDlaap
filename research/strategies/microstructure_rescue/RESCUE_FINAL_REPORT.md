# Rescue Final Report

Capital fixed **10 USD**. recs=59142 disc/val/oos=34886/13231/11015.
|imb250|>=q70=1.000. Real spread 26 pts.

POSITIVE cells: regime=0 exit=0 OOS=0

## Holding horizons (all, discovery)

all,BUY,30s,34886,-0.83,-26.84,32.9,-27.8,-25.83,negative
all,BUY,60s,34886,-1.17,-27.18,37.3,-28.55,-25.84,negative
all,BUY,120s,34886,-2.32,-28.33,40.3,-30.95,-25.74,negative
all,BUY,300s,34886,-5.86,-31.87,43.0,-38.45,-25.95,negative
all,SELL,30s,34886,-0.83,-25.17,34.3,-26.19,-24.22,negative
all,SELL,60s,34886,-1.17,-24.83,39.2,-26.18,-23.48,negative
all,SELL,120s,34886,-2.32,-23.68,43.2,-26.27,-21.08,negative
all,SELL,300s,34886,-5.86,-20.14,46.6,-26.09,-13.56,negative

## Exit optimization (first-passage expectancy)

all,T2_S1,BUY,34886,-26.01,0.0,0.0,-26.01,-26.0,negative
all,T2_S1,SELL,34886,-26.01,0.0,0.0,-26.01,-26.0,negative
all,T3_S1,BUY,34886,-26.01,0.0,0.0,-26.01,-26.0,negative
all,T3_S1,SELL,34886,-26.01,0.0,0.0,-26.01,-26.0,negative
all,T3_S2,BUY,34886,-22.59,22.3,22.7,-23.17,-21.9,negative
all,T3_S2,SELL,34886,-20.89,23.6,24.0,-21.59,-20.23,negative

## Entry timing (strong imb)

immediate,BUY,60s,8452,-25.42,37.7,-27.82,-22.81,negative
immediate,BUY,120s,8452,-25.7,40.5,-29.22,-22.03,negative
delay1s_hold60s,BUY,-,8452,-27.54,36.7,-29.98,-24.99,negative
delay5s_hold60s,BUY,-,8452,-27.83,36.6,-30.48,-25.24,negative
delay1s_hold120s,BUY,-,8452,-27.74,39.6,-31.31,-24.2,negative
immediate,SELL,60s,8303,-23.81,39.2,-26.39,-21.51,negative
immediate,SELL,120s,8303,-22.7,43.1,-26.71,-18.78,negative
delay1s_hold60s,SELL,-,8303,-25.78,38.5,-28.37,-23.52,negative
delay5s_hold60s,SELL,-,8303,-26.02,38.5,-28.84,-23.75,negative

## OOS of best regime cells

SELL|HIGH_VOL|MID_RATE|120s,oos,301,-7.75,-18.25,45.8,inconclusive
SELL|MID_VOL|HIGH_RATE|120s,oos,227,-8.97,-17.03,46.7,inconclusive
BUY|HIGH_VOL|LOW_RATE|120s,oos,153,-7.01,-33.01,43.1,inconclusive
SELL|MID_VOL|LOW_RATE|300s,oos,190,-25.07,-0.93,49.5,inconclusive
SELL|HIGH_VOL|MID_RATE|300s,oos,301,-28.06,2.06,50.5,inconclusive
SELL|HIGH_VOL|MID_RATE|60s,oos,301,9.21,-35.21,39.2,negative
BUY|HIGH_VOL|MID_RATE|60s,oos,291,-11.0,-37.04,38.8,negative
BUY|HIGH_VOL|LOW_RATE|60s,oos,153,1.48,-24.52,41.2,inconclusive
BUY|HIGH_VOL|LOW_RATE|300s,oos,153,-10.35,-36.35,40.5,inconclusive
SELL|HIGH_VOL|HIGH_RATE|300s,oos,522,-1.1,-24.9,48.9,inconclusive

## Decision
**OPTION B: No economic strategy proven.** Longer horizons, delayed entry, and skewed first-passage exits all fail to beat the 26-pt spread out-of-sample. No EA delivered.

## KEY EVIDENCE (59 days, 59,142 decisions, discovery/val/oos=34,886/13,231/11,015)

### Holding horizons (all, discovery) - drift does NOT accumulate above cost
| side | 30s | 60s | 120s | 300s |
|---|---:|---:|---:|---:|
| BUY net | -26.84 | -27.18 | -28.33 | -31.87 |
| SELL net | -25.17 | -24.83 | -23.68 | -20.14 |
Gross at 300s: BUY -5.86 (mid drifts DOWN), SELL +5.86. Longer holding makes it WORSE, not better.

### First-passage exits (all, discovery)
| combo | side | mean_pnl | win% |
|---|---|---:|---:|
| T2_S1 | BUY | -26.01 | 0.0 |
| T3_S1 | BUY | -26.01 | 0.0 |
| T3_S2 | BUY | -22.59 | 22.3 |
| T3_S2 | SELL | -20.89 | 23.6 |

**Modeling insight:** with spread=26, a 1x-spread stop sits exactly at the entry bid (entry_ask - spread = entry_bid) and is triggered on the first tick -> 0% win. Only a >1x stop (T3_S2) is meaningful, and even then win rate 22-24% with mean PnL -21 to -22.6 pts.

### Entry timing (strong imbalance) - waiting does not help
Delayed entry (+1s/+5s) gives the same or worse net than immediate; the imbalance signal decays within ~1s, so waiting loses the edge and adds drift.

### Regime x imbalance, cost/latency stress
0 POSITIVE cells. At real spread 26 with any slippage/latency, net stays deeply negative. Only at hypothetical spread <=10 (unavailable) do some cells approach zero.

## ANSWERS
1. **Problem:** predictable move (2-25 pts) < executable cost (26 pts) at every horizon and regime tested.
2. **Solutions tested:** longer horizons, delayed entry, skewed T/S first-passage exits, vol x rate regimes, cost/latency stress.
3. **New hypotheses:** H1 (longer horizon) FAILED, H2 (delayed entry) FAILED, H3 (skewed exits) FAILED, H4 (regime) FAILED, H5 (cost tolerance) FAILED.
4. **Profitable strategy after real cost?** NO.
5. **Opportunities:** ample signals (~34k strong-imb events in discovery) but none economical.
6. **Avg net P/L:** best cell ~ -8 to -13 pts; typical -20 to -27 pts.
7. **PF / MaxDD:** not applicable - no positive-expectancy strategy to measure.
8. **Stable OOS?** No positive cell exists to be stable.
9. **Executable on $10?** N/A - no strategy.
10. **Next highest-value step:** obtain a broker/account with XAUUSD spread <= ~8-10 pts, OR test cross-asset/news conditioning to raise conditional move above 26 pts. On this broker/account the microstructure path is exhausted.

## DECISION: OPTION B
No economic strategy proven. The microstructure directional information is real but structurally smaller than the JustMarkets Standard XAUUSD.m spread. No EA delivered.
