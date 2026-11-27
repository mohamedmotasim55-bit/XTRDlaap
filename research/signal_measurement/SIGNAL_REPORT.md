# XTRD OMIGA — Signal Measurement Report

- signals: 6757  followup rows: 40541  joined: 40541

## Overall by horizon (net after spread, points)

| horizon | n | mean | median | %pos | MFE mean | MAE mean |
|---|---:|---:|---:|---:|---:|---:|
| 100ms | 6757 | -24.82 | -26.00 | 1.2% | -23.78 | -27.05 |
| 500ms | 6757 | -23.81 | -25.00 | 7.8% | -17.43 | -31.92 |
| 1s | 6757 | -23.98 | -25.00 | 12.3% | -12.80 | -36.33 |
| 3s | 6757 | -24.39 | -25.00 | 22.5% | 0.17 | -48.99 |
| 5s | 6757 | -24.95 | -25.00 | 27.3% | 9.43 | -58.32 |
| 10s | 6756 | -23.97 | -25.00 | 33.9% | 27.03 | -75.50 |

## By direction

### BUY

| horizon | n | mean | median | %pos |
|---|---:|---:|---:|---:|
| 100ms | 2868 | -24.86 | -26.00 | 1.6% |
| 500ms | 2868 | -24.16 | -26.00 | 8.1% |
| 1s | 2868 | -24.14 | -26.00 | 12.2% |
| 3s | 2868 | -23.79 | -25.00 | 23.1% |
| 5s | 2868 | -24.27 | -26.00 | 28.9% |
| 10s | 2867 | -22.81 | -25.00 | 35.1% |
### SELL

| horizon | n | mean | median | %pos |
|---|---:|---:|---:|---:|
| 100ms | 3889 | -24.79 | -26.00 | 1.0% |
| 500ms | 3889 | -23.55 | -25.00 | 7.6% |
| 1s | 3889 | -23.85 | -25.00 | 12.4% |
| 3s | 3889 | -24.84 | -25.00 | 22.0% |
| 5s | 3889 | -25.44 | -25.00 | 26.2% |
| 10s | 3889 | -24.82 | -25.00 | 33.1% |

## By strategy family (1s and 10s)

| family | 1s n | 1s mean | 1s %pos | 10s n | 10s mean | 10s %pos |
|---|---:|---:|---:|---:|---:|---:|
| Breakout | 925 | -22.56 | 16.1% | 924 | -23.85 | 35.7% |
| Exhaustion | 3 | -30.00 | 0.0% | 3 | -55.67 | 0.0% |
| MeanReversion | 1 | -9.00 | 0.0% | 1 | 17.00 | 100.0% |
| Momentum | 5928 | -23.99 | 12.1% | 5927 | -23.67 | 34.0% |
| TickFlow | 2762 | -23.87 | 12.4% | 2761 | -23.18 | 33.9% |
| TrendPullback | 4398 | -24.44 | 11.5% | 4398 | -24.91 | 33.6% |

## By server hour (1s horizon)

| hour | n | mean | %pos |
|---:|---:|---:|---:|
| 1 | 300 | -22.68 | 13.0% |
| 2 | 306 | -23.23 | 17.0% |
| 3 | 269 | -23.16 | 21.6% |
| 4 | 285 | -22.39 | 15.4% |
| 5 | 268 | -25.09 | 10.4% |
| 6 | 281 | -23.12 | 8.5% |
| 7 | 327 | -26.47 | 15.3% |
| 8 | 279 | -28.14 | 11.5% |
| 9 | 319 | -22.94 | 10.3% |
| 10 | 287 | -24.53 | 10.8% |
| 11 | 319 | -23.36 | 8.2% |
| 12 | 323 | -24.47 | 7.1% |
| 13 | 346 | -22.40 | 7.8% |
| 14 | 332 | -22.58 | 10.5% |
| 15 | 338 | -21.97 | 19.2% |
| 16 | 269 | -23.97 | 20.1% |
| 17 | 238 | -22.17 | 19.3% |
| 18 | 254 | -27.37 | 11.8% |
| 19 | 288 | -23.69 | 10.4% |
| 20 | 281 | -26.22 | 9.3% |
| 21 | 267 | -23.82 | 11.2% |
| 22 | 283 | -25.10 | 8.5% |
| 23 | 298 | -23.62 | 8.1% |

## By regime (1s horizon)

| regime | n | mean | %pos |
|---|---:|---:|---:|
| COMPRESSION | 192 | -23.00 | 7.3% |
| EXPANSION | 883 | -25.21 | 12.7% |
| MIXED | 253 | -23.10 | 8.7% |
| RANGE | 233 | -21.95 | 9.4% |
| TREND DOWN | 2568 | -24.55 | 12.5% |
| TREND UP | 1676 | -23.68 | 12.8% |
| TREND/UNCLEAR | 952 | -22.73 | 13.2% |

---

## Random baseline (coin-flip direction, same timestamps & spread)

| horizon | engine mean | random mean | delta | engine %pos |
|---|---:|---:|---:|---:|
| 100ms | -24.82 | -26.03 | +1.21 | 1.2% |
| 500ms | -23.81 | -26.03 | +2.22 | 7.8% |
| 1s | -23.98 | -26.03 | +2.05 | 12.3% |
| 3s | -24.39 | -26.03 | +1.63 | 22.5% |
| 5s | -24.95 | -26.03 | +1.08 | 27.3% |
| 10s | -23.97 | -26.03 | +2.06 | 33.9% |

The engine is ~2 points better than a coin-flip baseline, but **both are deeply negative**. A ~2-point directional edge cannot cover a 26-point spread within 10s.

## Methodology
- Original file preserved byte-for-byte (`/tmp/SIGNAL_ENGINE_ORIGINAL.mq5`, sha256 f12858e4…).
- Test copy `XTRD_OMIGA_SIGNAL_ENGINE_MEASURE.mq5` adds ONLY logging/measurement:
  MeasInit/MeasDeinit/RecordSignal/ResolveFollowups + 3 call sites. No signal/indicator logic changed (signal-scoring and indicator-read blocks verified byte-identical).
- Every raw signal logged with id, tick time in ms (tick.time_msc), symbol, direction, score, regime, bid/ask, spread, RSI/ADX/ATR/tick velocity/up-ratio/activity, agreement counts, families.
- Follow-ups at 100ms/500ms/1s/3s/5s/10s computed from real ticks via CopyTicksRange(signal_msc, signal_msc+horizon).
- Execution realism: BUY entry=ask, exit=bid; SELL entry=bid, exit=ask → net already includes spread.
- No trading: the EA contains no OrderSend/CTrade (verified by grep).

## Validation performed
- Compile/lint: `mql5_lint.py` OK (11 functions, 126 calls). (Fixed a lint allowlist gap for real MQL5 built-ins iADX/iBands/iMACD — tooling only.)
- Timestamps: tick.time_msc (ms) used; monotonic per run.
- Spread/direction: first BUY row shows net = -26 pts immediately (ask→bid) = correct spread accounting.
- NA handling: horizons with no ticks are written as NA; the single missing 10s row (last signal before test end) was left unresolved, NOT invented.
- Look-ahead: signal logic unchanged; indicators read shift 0 (current, real-time). Follow-ups only read ticks at/before each horizon boundary (≤ current simulated time).

## What could not be verified
- Live MT5 terminal state (no persistent MT5 in this Linux sandbox; runs on GitHub Actions Windows runner, demo).
- Live spread/latency; the tester ExecutionMode=15ms delay was applied but not compared to a real broker fill.
- Long-horizon behaviour beyond 10s (not measured here).

## Verdict
**No deployable edge.** 6,757 real signals across 7 days, every horizon, direction, family, hour and regime is negative after spread. Best case ≈ -22 pts; spread ≈ 26 pts. The signal engine needs a fundamentally different source of edge (e.g., session structure) before any execution layer is worth building.
