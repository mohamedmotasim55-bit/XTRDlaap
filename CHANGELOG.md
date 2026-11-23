# XTRD OMIGA — iteration changelog

Target account: JustMarkets Standard, XAUUSD, spread 25-35 points, no commission,
deposit 100 USD, leverage 1:1000. Stress test: real ticks, 15 ms execution delay.

Scoring: `score = net_profit * min(profit_factor, 3) - 0.5 * equity_dd_rel`.
An iteration is reverted when its score is below the best previous score.

## Iteration 0 - pipeline bring-up (no trades)

**Backtest:** 2026.10.07 -> 2026.11.21, `XAUUSD.m`, M1, real ticks, 15 ms
execution delay, 100 USD, stress spread 26 pts (matches the live quote).

| metric | value |
| --- | --- |
| net profit | 0.00 |
| trades | 0 |
| profit factor | n/a |
| max equity DD | 0.00% |
| telemetry rows | 0 |

### Findings

1. **`XAUUSD` does not exist on this broker** - gold is `XAUUSD.m`
   (`Metals M\XAUUSD.m`). The tester aborted with `symbol XAUUSD not exist`.
   The workflow now reads the terminal symbol tree and picks the name.
2. **The expert had never compiled** - `MqlTradeTransaction` has no
   `request_id` field. Fixed, and the CI gate now trusts the compiler log plus
   the produced `.ex5` (`metaeditor64.exe` returns 1 even on success).
3. **The expert never traded.** 44.5M signal evaluations, 0 orders. The logged
   state shows `intensity` 0.88-0.99 and `persist` 0.50-0.65, while the gates
   demanded `intensity >= 2.5` (micro) / `>= 2.0` (momentum, exhaustion) and
   `persist >= 0.80`. The constants were calibrated for a different tick
   stream, so every strategy was unreachable.
4. **The HTML report is not written in headless mode.** Added
   `X13_Omega_Summary.csv` written by the EA from `TesterStatistics`, so the
   metrics no longer depend on the terminal's report writer.

### Changes

- Percentile gates: intensity, persistence, acceleration and displacement are
  compared against the live distribution of the instrument (rolling 512 s
  window, 1 s sampling) with absolute floors, instead of fixed constants.
- Rejection counters for all 12 gates, dumped to the summary CSV and to the
  periodic log, so the next iteration is measurement driven.
- Exhaustion and momentum no longer require an unreachable regime label.

## High-frequency phase (30 day windows, leverage 1:3000)

| run | configuration | trades | net USD | PF | DD | avg win | avg loss |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A | tight gates p60, old ladder, 10 slots | 7 | -0.09 | 0.97 | 3.04% | 0.64 | -1.64 |
| B | gates p30, ladder at 1.0/1.3 R, 200 ms | 101 | **+2.41** | **1.03** | 13.34% | **1.94** | -1.58 |
| C | gates p20, 120 ms | - | - | - | - | - | - |
| D | p30 + deal watermark fix, 6 slots | pending | | | | | |

### The two defects that decided the outcome

**1. The ladder, not the strategy, was the loss.** Run A won 5 of 7 trades and
still lost money, because stage 1 armed at 78 pts and locked 31 pts: every
winner exited at 0.35R while every loser paid 1.0R. Moving stage 1 to 1.00x the
stop and stage 2 to 1.30x took the average win from 0.64 to 1.94 USD and the
run from -0.09 to +2.41.

**2. Deal accounting was multiplied by 18.** The processed-deal cache was a
64 slot ring while the sync rescanned 30 days of history every 30 s. The ring
overflowed after a few hundred deals, so every rescan replayed them: 1,832
ledger rows for 101 trades, and the daily loss and drawdown guards were fed a
loss figure 18 times too large. Deal tickets are monotonic, so a watermark is
correct and O(1).

### The law the measurements expose

Win rate and frequency move in opposite directions:

| selectivity | win rate | R:R | expectancy per trade |
| --- | --- | --- | --- |
| p60 | ~71% | 0.4R (old ladder) | negative |
| p30 | 45.5% | 1.23 | +0.02R |
| p20 | 31% | 1.23 | negative |

Hundreds of trades per day is mechanically reachable, but on a 26 pt spread
each trade pays 17% of R to enter, so the entry edge has to carry that cost.
Loosening the gates buys trade count and spends the edge.

## Iteration log

Every row is a real-tick run on `XAUUSD.m`, M1, 2026.10.07 -> 2026.11.21,
100 USD, 1:100, 15 ms execution delay, 26 pt spread.

| iter | change under test | trades | net USD | PF | max DD |
| --- | --- | --- | --- | --- | --- |
| 0 | pipeline bring-up | 0 | 0.00 | - | 0.00% |
| 1 | percentile gates replace fixed constants | 0 | 0.00 | - | 0.00% |
| 2 | tick intensity rebuilt as rate / EWMA | 0 | 0.00 | - | 0.00% |
| 3 | rejection counters through the send path | 0 | 0.00 | - | 0.00% |
| **4** | **OrderCheck advisory, affordable stop** | **4** | **-1.20** | **0.231** | **2.31%** |
| 5 | BE ladder scaled to the stop, deal sync | 5 | -2.43 | 0.233 | 3.98% |
| 6 | probability floor self-calibrated | 4 | -4.41 | 0.066 | 4.98% |
| 7 | passive entries for reversion | 5 | -7.37 | 0.028 | 7.37% |
| 8 | stop/target sized to measured excursions | 3 | -3.00 | 0.065 | 3.47% |

Iteration 4 is the best measured configuration and is shipped as
`XTRD_OMIGA_FINAL.mq5`.

### What each iteration proved

1. **Iteration 1** - 44,519,586 of 44,519,586 signals died at the intensity
   gate (`p70 = 0.951`). The gate was not strict, it was unreachable.
2. **Iteration 2** - `TickIntensity()` compared a window against a baseline
   built from the same window, so the ratio sat at 1.0 with almost no
   variance. Replaced by current tick rate over a slow EWMA (`max 7.47`,
   `p90 1.67`), which restored a usable distribution.
3. **Iteration 3** - 1,630 signals reached the send path and all 1,630 were
   killed by `ValidateTradeRequest`. `OrderCheck` is advisory in the tester.
4. **Iteration 4** - first trades. The 356 pt stop risked 3.56% of a 100 USD
   account at the 0.01 minimum lot, above the 3% cap, so stops are clipped to
   what the account can carry. Winners averaged +12 pts against a 296 pt
   stop: stage 1 armed at 19% of the stop distance and locked 15.6 pts, less
   than the 26 pt round-trip cost.
5. **Iteration 5** - deals reconciled from history (OnTradeTransaction never
   fired in the tester), which finally produced the ledger. It showed every
   trade reaching 143-205 pts of favourable excursion and still closing at
   the stop.
6. **Iteration 6** - 1.3M signals reached the confidence gate and almost none
   cleared the fixed 0.56 floor; the model's own confidence tops out near
   0.55 on this instrument.
7. **Iteration 7** - the terminal log reported `avg_slip=44.86` points per
   market fill against a 26 pt spread, 29% of the stop burned on entry.
   Reversion strategies now enter passively.
8. **Iteration 8** - the target sat at 712 pts while the measured excursion
   tops out near 205 pts, so the target was unreachable by construction.

<!-- METRICS:START -->
| iter | net USD | PF | trades | equity DD % | recovery | score | verdict |
| --- | --- | --- | --- | --- | --- | --- | --- |
<!-- METRICS:END -->

## Iteration notes

### Iteration 0 — baseline (v2.23)

Run of the original EA, unmodified except for the instrumentation needed to
attribute trades to strategies (per-trade ledger + strategy column in telemetry).

Expected structural failures, derived from the code before any run:

1. `InpMinSLPts = 32` and `SL = 0.8 * ATR(M1)`. Gold M1 ATR is 20-60 points, so the
   stop lands at 32-48 points, i.e. **1.0-1.6x the spread**. A buy entered at ask
   with a 32-point stop has its stop level at bid + (32 - spread); with a 30-point
   spread the stop sits 2 points below the bid and is hit on the next down tick.
2. `InpTP_ATR_Multiplier = 1.2` gives a 45-70 point target against a 30-point
   spread: only 15-40 points of the target is actually capturable.
3. Break-even stage 1 triggers at +5.5 points and locks +1.8 points — **inside the
   spread**, so every "protected" trade closes at roughly -spread.
4. `InpSpreadExpansionMaxPts = 30` is an absolute cap: on a 25-35 point spread
   account the shield rejects a large share of valid entries.
5. `SpreadGate` accepted `edge >= 0.475 * spread`, i.e. half the round-trip cost.
6. `InpMinEdgePts = 3` with `edge = (2p-1) * ATR * targetATR` is not a price
   distance at all, so the gate never measured the tradable edge.
7. 15 concurrent positions on a 100 USD account multiply the spread bleed by 15.
8. `InpMaxTradeAgeSec = 240` cuts trades long before a 45-70 point target can form.

### Iteration 1 — spread-aware geometry (v2.30)

Applied fixes:

- **ATR timeframe**: M1 -> M5 (`InpATRTimeframe`). M1 ATR is smaller than the
  spread on this account, so it cannot be used to size stops.
- **Geometry in spread multiples**: `SL = max(0.55*ATR_M5, 6*spread)`,
  `TP = max(1.10*ATR_M5, 9*spread)`, floors `InpMinSLPts = 150`.
- **Edge measured in points**: `edge = (2p-1) * TP`, gate `edge >= 1.5 * spread`.
- **Volatility floor**: no entries while `ATR_M5 < 3 * spread`.
- **Relative spread shield**: reject when `spread > baseline + 15`.
- **Break-even ladder in spread multiples**: stage 1 at `2.2*spread` locking
  `0.6*spread`, stage 2 at `4*spread` locking `1.8*spread`.
- **Trailing floor** `2*spread`; partial closes disabled (they pay the spread twice
  and cannot split a 0.01 lot anyway).
- **Position sizing**: 1.5% risk, 4 concurrent positions, 2 per direction,
  portfolio risk cap 6%, hard drawdown 15%. Added a small-account minimum-lot
  fallback that is only used while it stays inside the risk cap.
- **Hold time** 900 s, stall exit only below -1 spread.
- **Instrumentation**: per-trade ledger `X13_Omega_Ledger.csv` with strategy,
  entry/exit price, SL/TP distance, spread at entry, MFE/MAE, age, exit reason,
  ATR, regime and session.

Status: code changed, **not yet measured** — the backtest could not be executed
because the CI run needs `MT5_LOGIN`, `MT5_PASSWORD`, `MT5_SERVER` and write
access to the repository. See `docs/DIAGNOSIS.md`.
