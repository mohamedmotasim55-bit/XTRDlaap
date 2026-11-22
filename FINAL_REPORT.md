# XTRD OMIGA - stress test report

Account profile: JustMarkets Standard, `XAUUSD`, spread 25-35 points, no
commission, 100 USD deposit, 1:100 leverage, 15 ms execution delay.

Shipped build: `XTRD_OMIGA_FINAL.mq5` (best measured iteration, 4 of 8).

## 1. Test rig

`.github/workflows/backtest.yml` runs on `windows-latest`:

1. Downloads and silently installs the JustMarkets MT5 terminal, cached under a
   stable key so only the first run pays the install cost.
2. Purges `Common/Files`, `Tester` and `MQL5/Files` so a cached install cannot
   leak the previous run's ledger into the next report.
3. Compiles the expert with `metaeditor64.exe` and fails on any compile error.
   The exit code is ignored because MetaEditor returns 1 even on success; the
   gate reads the log and requires the produced `.ex5`.
4. Resolves the broker's gold symbol by having a probe EA dump the terminal
   symbol tree. This broker lists gold as `XAUUSD.m`, not `XAUUSD`.
5. Builds `tester.ini` with `Model=4` (every tick from real ticks),
   `ExecutionMode=15`, `Deposit=100`, `Leverage=1000`, `ShutdownTerminal=1`,
   and runs `terminal64.exe /config:tester.ini`.
6. Uploads the report, `X13_Omega_Telemetry.csv`, `X13_Omega_Ledger.csv`,
   `X13_Omega_Summary.csv`, the compile log and the terminal log.

`tools/analyze_backtest.py` parses those artifacts into one metrics record and
ranks iterations. `tools/mql5_lint.py` validates the source locally so a typo
does not cost a CI round trip.

## 2. Defects found and fixed

| # | Defect | Evidence | Fix |
| --- | --- | --- | --- |
| 1 | Expert had never compiled | `MqlTradeTransaction` has no `request_id` | Attribution falls back to the position ticket |
| 2 | Symbol `XAUUSD` does not exist | Tester aborted: `symbol XAUUSD not exist` | Symbol discovery, resolves `XAUUSD.m` |
| 3 | No HTML report in headless mode | Report writer produced nothing | EA writes `X13_Omega_Summary.csv` from `TesterStatistics` |
| 4 | Every signal rejected | 44,519,586 / 44,519,586 at the intensity gate | Percentile gates against the live distribution |
| 5 | Intensity had no variance | `p70 = 0.951`, ratio pinned near 1.0 | Current tick rate over a slow EWMA (~50 s) |
| 6 | Every order rejected | 1,630 / 1,630 died in `ValidateTradeRequest` | `OrderCheck` is advisory, hard blockers kept |
| 7 | Stop unaffordable at the minimum lot | 356 pt stop = 3.56% risk at 0.01 lot, cap 3% | Stop clipped to `MaxAffordableStopPts()` |
| 8 | Winners cut below the spread | 3 wins averaging +12 pts vs a 296 pt stop | BE triggers are fractions of the stop, locks above the round trip |
| 9 | No ledger, no telemetry | `OnTradeTransaction` never delivered deals in the tester | Deals reconciled from history on a timer |
| 10 | Confidence gate unreachable | 1.3M signals, almost none above 0.56 | Floor tracks the 60th percentile (hard floor 0.42) |
| 11 | 44.9 pts of slippage per fill | Terminal log: `avg_slip=44.86` vs 26 pt spread | Reversion strategies enter with limits |
| 12 | Target unreachable | 712 pt target, 143-205 pt measured excursion | Stop 0.25 ATR, target 1.25x stop |
| 13 | Cached run state contaminated results | Ledger and state files accumulated across runs | Purge step before every run |

## 3. Measured results

Real ticks, 2026.10.07 to 2026.11.21, 100 USD, 1:100, 15 ms delay, 26 pt spread.

| iter | trades | net USD | PF | max DD | note |
| --- | --- | --- | --- | --- | --- |
| 0 | 0 | 0.00 | - | 0.00% | pipeline only |
| 1 | 0 | 0.00 | - | 0.00% | intensity wall |
| 2 | 0 | 0.00 | - | 0.00% | displacement / confidence wall |
| 3 | 0 | 0.00 | - | 0.00% | `OrderCheck` wall |
| **4** | **4** | **-1.20** | **0.231** | **2.31%** | best measured |
| 5 | 5 | -2.43 | 0.233 | 3.98% | BE ladder rescaled |
| 6 | 4 | -4.41 | 0.066 | 4.98% | confidence floor |
| 7 | 5 | -7.37 | 0.028 | 7.37% | passive entries |
| 8 | 3 | -3.00 | 0.065 | 3.47% | geometry resized |

## 4. Honest assessment

The expert is now structurally sound: it compiles, it trades, every decision
path is instrumented, and no gate is silently unreachable. It is **not yet
profitable** on this account.

Three measured facts explain why:

1. **Opportunity is thin.** About 400 signals per 45 days clear the spread
   gate. With one position at a time (0.01 lot at 1:100 consumes 40% of a
   100 USD account's margin) the system can only take a handful of trades.
2. **Cost per trade is large relative to the move.** 26 pt spread, and 44.9
   pts of measured slippage on market fills, against a typical 143-205 pt
   excursion.
3. **The sample is far too small.** Three to five trades cannot separate a
   real edge from noise; a binomial confidence interval on four trades spans
   most of the unit interval.

Iteration 4 scored best and is therefore shipped as `XTRD_OMIGA_FINAL.mq5`,
as required by the "keep the best performing iteration" rule. It still
contains the tight BE ladder that iteration 5 identified as a leak; the
later, structurally better versions remain on `main` for the next experiment.

## 5. Next experiments, in order

1. Extend the window to 12 months and re-run iterations 4 and 8 head to head.
   Only then do the trade counts carry any statistical weight.
2. Trade the `ExecutionMode=0` variant as a control to measure how much of the
   loss is the 15 ms stress delay rather than the strategy.
3. Let the margin ladder allow two positions on a 100 USD account (0.01 lot
   each) once the win rate is established, so a stalled position does not
   block the next signal.
4. Raise `InpMaxTradeAgeSec` back above the typical excursion time once
   passive entries are proven to fill.
