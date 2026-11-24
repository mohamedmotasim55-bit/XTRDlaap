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
- Real-tick history starts 2026.10.26 (about 28 days) — OOS/WF must fit inside it

## Rules
- Never modify the user's EA beyond fixing trivial compile errors.
- Never enable min-lot override or raise risk without explicit approval.
- Run only the EA the user names.
