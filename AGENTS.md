# AGENTS.md — repository memory

## Purpose
This repository is an MT5 backtest laboratory. It contains no trading bots by design.
The owner supplies one EA file at a time; only that EA is tested.

## Infrastructure
- `.github/workflows/backtest.yml` — installs JustMarkets MT5 on windows-latest,
  compiles the EA (fails on any compile error), runs the strategy tester, and
  uploads artifacts (report HTML, telemetry, summary, logs).
- `tools/SymbolScan.mq5` — utility EA used by the workflow to enumerate symbols.
- `tools/analyze_backtest.py`, `tools/mql5_lint.py` — used by the workflow.

## How to run a backtest
```
gh workflow run backtest.yml --ref <branch> -f ea=<EAName> -f deposit=<usd> -f days=<n> -f tag=<label>
```
Optional: `-f spread_pts=<n>` forces a fixed spread; `-f extra_inputs="InpA=1,InpB=2"`.

The EA file must sit in the repository root as `<EAName>.mq5`.

## Locked test conditions
- Broker: JustMarkets, Standard account
- Symbol: XAUUSD.m, M1, Model=4 (every tick based on real ticks)
- Leverage 1:3000, no commission, spread ~26 points
- Verified data coverage (from dataprep run 45383070437):
  - real ticks: 2025.11.24 -> 2026.11.24, 85,471,198 ticks (1 year)
  - M5: from 2025.06.27, M15: 2022.08.25, M30/H1/H4/D1: 2011.11.02
  - M1 via CopyRates caps at 100,000 bars (chart limit); the tester loads
    641,830 M1 bars from 2025.01.02 on its own
  - data size 0.61 GB, cached under key mt5data-XAUUSD.m-365-v1

## Rules
- Never modify the user's EA beyond fixing trivial compile errors.
- Never enable min-lot override or raise risk without explicit approval.
- Run only the EA the user names.
