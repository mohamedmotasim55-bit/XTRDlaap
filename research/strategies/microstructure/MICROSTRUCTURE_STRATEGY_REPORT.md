# Microstructure Strategy Development (Phase 2)

Capital fixed **10 USD**. Decisions: 59147. Split 34894/13233/11020 (embargo 10s).
Signal: |imb250ms| >= q70=1.000 (and q85=1.000). Cost: 26.0 pts spread.

Discovery cells tested: 448 | POSITIVE in discovery: 0 | POSITIVE in OOS: 0

## Best discovery cells (top by mean_net)

| signal | condition | horizon | side | n | mean_net | verdict |
|---|---|---|---|---:|---:|---|
| imb250_strong_BUY | session:H15 | 10s | BUY | 298 | -8.55 | inconclusive |
| imb250_strong_BUY | session:H16 | 10s | BUY | 262 | -14.74 | negative |
| imb250_strong_SELL | session:H15 | 10s | SELL | 302 | -16.99 | negative |
| imb250_strong_SELL | session:H15 | 2s | SELL | 302 | -19.32 | negative |
| imb250_strong_SELL | session:H15 | 1s | SELL | 302 | -19.57 | negative |
| imb250_strong_BUY | session:H01 | 10s | BUY | 481 | -19.85 | negative |
| imb250_strong_SELL | session:H15 | 500ms | SELL | 302 | -19.88 | negative |
| imb250_strong_BUY | session:H16 | 1s | BUY | 262 | -19.93 | negative |
| imb250_strong_SELL | session:H19 | 10s | SELL | 350 | -20.55 | negative |
| imb250_strong_BUY | session:H16 | 2s | BUY | 262 | -20.61 | negative |

## OOS check of best cells

imb250_strong_BUY,session:H15,10s,BUY,oos,100,12.45,-13.55,46.0,inconclusive
imb250_strong_BUY,session:H16,10s,BUY,oos,69,27.39,1.39,52.2,small sample
imb250_strong_SELL,session:H15,10s,SELL,oos,87,-26.06,0.06,52.9,small sample
imb250_strong_SELL,session:H15,2s,SELL,oos,87,-6.95,-19.05,28.7,small sample
imb250_strong_SELL,session:H15,1s,SELL,oos,87,-7.33,-18.67,13.8,small sample
imb250_strong_BUY,session:H01,10s,BUY,oos,137,5.38,-21.24,36.5,negative
imb250_strong_SELL,session:H15,500ms,SELL,oos,87,-4.43,-21.57,6.9,small sample
imb250_strong_BUY,session:H16,1s,BUY,oos,69,10.71,-15.29,23.2,small sample
imb250_strong_SELL,session:H19,10s,SELL,oos,83,-1.0,-25.0,34.9,small sample
imb250_strong_BUY,session:H16,2s,BUY,oos,69,12.25,-13.75,39.1,small sample
imb250_strong_SELL,session:H19,5s,SELL,oos,83,-8.4,-17.6,33.7,small sample
imb250_strong_BUY,session:H05,10s,BUY,oos,110,-1.96,-27.96,32.7,negative

## Cost stress (best cell, OOS)

signal,condition,horizon,spread_pts,slippage_pts,n,mean_gross,mean_net,pctpos
imb250_strong_BUY,session:H15,10s,26,0,100,12.45,-13.55,46.0
imb250_strong_BUY,session:H15,10s,26,1,100,12.45,-14.55,45.0
imb250_strong_BUY,session:H15,10s,26,2,100,12.45,-15.55,44.0
imb250_strong_BUY,session:H15,10s,26,5,100,12.45,-18.55,43.0
imb250_strong_BUY,session:H15,10s,20,0,100,12.45,-7.55,49.0
imb250_strong_BUY,session:H15,10s,20,1,100,12.45,-8.55,48.0
imb250_strong_BUY,session:H15,10s,20,2,100,12.45,-9.55,47.0
imb250_strong_BUY,session:H15,10s,20,5,100,12.45,-12.55,46.0
imb250_strong_BUY,session:H15,10s,15,0,100,12.45,-2.55,49.0
imb250_strong_BUY,session:H15,10s,15,1,100,12.45,-3.55,49.0
imb250_strong_BUY,session:H15,10s,15,2,100,12.45,-4.55,49.0

## Decision
**Option B: No economic strategy proven.** Predictable moves stay below execution cost; no conditional cell is positive out-of-sample after cost.

## DETAILED FINDINGS

### BUY / SELL independent (strong imbalance, |imb250ms|>=q70=1.0)
| side | horizon | n | mean_gross | mean_net | %pos | verdict |
|---|---|---:|---:|---:|---:|---|
| BUY | 1s | 8456 | +2.24 | -23.77 | 5.3 | negative |
| BUY | 10s | 8456 | +2.36 | -23.65 | 24.1 | negative |
| SELL | 1s | 8304 | -2.13 | -23.87 | 5.5 | negative |
| SELL | 10s | 8304 | -1.84 | -24.17 | 23.9 | negative |

The imbalance signal is correctly signed (BUY gross +, SELL gross -) but the move is ~2 pts, far below the 26-pt spread.

### Regime / interaction search
Tested: volatility regime (LOW/MID/HIGH), tick-rate regime, spread state, momentum sign, 24 sessions, and joint vol x rate cells, at 7 horizons, BUY and SELL separately. **0 cells reached POSITIVE (CI lower bound > 0) in discovery.**

### Best cell and its OOS failure
The single best discovery cell was `imb250_strong_BUY x session H15 x 10s`:
| segment | n | mean_gross | mean_net | verdict |
|---|---:|---:|---:|---|
| discovery | 298 | +17.53 | -8.55 | inconclusive |
| validation | 125 | +5.84 | -20.42 | negative |
| OOS | 100 | +12.45 | -13.55 | inconclusive |

It is NOT stable (gross swings 17.5 -> 5.8 -> 12.5) and net is negative in every segment at the real spread.

### Cost stress (best cell, OOS)
| spread | slippage | mean_net | %pos |
|---:|---:|---:|---:|
| 26 | 0 | -13.55 | 46.0 |
| 20 | 0 | -7.55 | 49.0 |
| 15 | 0 | -2.55 | 49.0 |
| 10 | 0 | +2.45 | 51.0 |

The cell only turns positive at a hypothetical 10-pt spread, which JustMarkets Standard does not offer for XAUUSD.m.

## WHERE THE HYPOTHESES FAIL (Option B justification)
1. **Magnitude gap**: even the best session-conditioned cell averages ~12-17 pts gross, still < 26-pt cost. Most cells ~2 pts.
2. **Instability**: the strongest discovery cells do not hold across validation/OOS (sign and magnitude swing).
3. **Multiple testing**: 448 hypotheses tested; the few borderline cells (n<100, e.g. H16 OOS +1.39 with n=69) are within expected false-positive count and fail sample-size/OOS rules.
4. **Cost floor**: profitability requires spread < ~10-12 pts; the broker offers ~26.

## DECISION: OPTION B
No economic microstructure strategy is proven. The directional information is real (confirmed in Phase 1) but the predictable move stays below the executable cost at JustMarkets XAUUSD.m Standard. No EA is delivered. The hypothesis that "imbalance + conditions unlocks a >26pt move" is **rejected** on this data.

## What would change the verdict (not tested here)
- A broker/account with XAUUSD spread <= ~8-10 pts.
- Longer holding where the session-conditioned drift compounds (H15 gross 17.5 at 10s suggests a session drift worth a separate, longer-horizon study).
- Cross-asset or news conditioning to raise the conditional move above cost.
