# XTRD OMIGA — XAUUSD Ultra-Scalping Research Report

## 1. Data Manifest (MT5-native)
| Month | Ticks | Seconds | Period |
|---|---:|---:|---|
| m1 | 8,680,239 | 1,703,633 | 2026-08-25 → 2026-09-23 |
| m2 | 10,361,126 | 1,730,992 | 2026-09-24 → 2026-10-23 |
| m3 | 10,755,156 | 1,600,359 | 2026-10-26 → 2026-11-20 |
Total: 29,796,521 ticks. Source: MT5 CopyTicks (bid/ask, ms). Spread median 26 pts.

## 2. Four-Count Framework (3 months, hour 1)
| Engine | Raw events | Candidates | Executable | Net-profitable | EV/pt | $/mo |
|---|---:|---:|---:|---:|---:|---:|
| TREND_PULLBACK | 5,034,984 | 85 | 39 | 8 | +130.8 | +17 |
| FADE | 5,034,984 | 148 | 63 | 11 | +70.7 | +15 |
| MOMENTUM | 5,034,984 | 76 | 32 | 3 | +4.6 | 0 |
| RANGE_EXP | 5,034,984 | 232 | 75 | 2 | -46.9 | -12 |
| VOL_BURST | 5,034,984 | 1 | 1 | 0 | - | 0 |

Key: 5.0M raw events -> ~85-150 candidates -> ~40-60 executable -> 8-11 net-profitable.
Ratio net-profitable/raw = 1.6 per million seconds.

## 3. Microstructure Findings (all measured, 1.7M seconds)
- Pulse predicts VOLATILITY: |30s move| 62 -> 86 pts as tick-rate goes 1x -> 4x (+38%).
- Pulse does NOT predict DIRECTION: 49.7% up at 4x pulse (random).
- Tick imbalance -> direction: 50.0% (random).
- Micro-momentum (5-60s): forward move -0.2..-2.3 pts, "against" 50.0%.
- Spread spikes: no exploitable reversion.

## 4. ML Results
| Model | Target | AUC |
|---|---|---|
| HGB 15 features | 5-60min direction | 0.49-0.50 |
| Sequence ML (16 lags) | triple-barrier | 0.5135 |
| HGB turn features | swing size >=100 | **0.5837** |

The only signal with AUC > 0.55 is swing-SIZE prediction (not direction).

## 5. Robustness (TREND_PULLBACK, stop 60-100 x hold 30-60)
15/15 parameter combinations positive (+$29 to +$60 over 3 months). Not parameter-hypersensitive.

## 6. Out-of-Sample Verdicts
| System | In-sample | Out-of-sample | Verdict |
|---|---|---|---|
| Zigzag by hour | +$1,196 (m1) | -$155/-$169 (m2/m3) | OVERFIT |
| TREND_PULLBACK | - | 2/3 months positive | ROBUST |
| FADE | - | 2/3 months positive | ROBUST |

## 7. MT5 Live Validation (JustMarkets, real ticks, 1:3000, $10)
Run live_v4: +$24.90 = +249% in 30 days, PF 2.32, Sharpe 44.74,
26 trades, 4 winners, max balance DD 19.25%. See mt5_results/.

## 8. Physical Limits (why not 100k trades)
- Gold moves 151,234 pts/day = $1,512.
- Spread cost per trade = 26 pts = $0.26.
- 100,000 trades/month = 3,333/day -> spread cost = 86,667 pts/day = 57% of all movement.
- To be net-profitable at that density, directional edge must exceed 26 pts/trade;
  measured predictability is 52.3% (needs 82.5% at 40/40 barrier).
- Verified net-profitable capacity on XAUUSD standard: 8-11 per month (hour 1 only).

## 9. Engines Tested and Rejected (documented)
Momentum continuation, impulse continuation, micro pullback, momentum reversal,
short breakout, range expansion, mean reversion, failed breakout, volatility burst,
tick acceleration, micro trend transition, hybrid multi-engine, dollar targets 60-130,
trailing stops, loss-streak breaker, Kaufman ER, 240-min trend, equity valve,
high-WR configs, spike fade/follow, live zigzag (X=15..400), zigzag by hour,
pulse+1m/5m trends (42 combos), micro-momentum, tick flow, spread spikes.

## 10. Deliverable
- `XTRD_OMIGA_Enabled_GoldSymbol.mq5` — TREND_PULLBACK engine, MT5-validated.
- `mt5_results/` — official MT5 report + telemetry.
- `research/` — harness, four-count, per-month, robustness.

## 11. Honest Limitations
- m1 month slightly negative for both engines (-$0.45, -$1.30).
- Combined-engine DD in m1 ($12.80) exceeds a $10 account -> run single engine only.
- 3 months is the minimum for stability claims; more months recommended.
- Commission assumed 0 (JustMarkets standard); slippage modelled via 15ms execution delay in MT5.
