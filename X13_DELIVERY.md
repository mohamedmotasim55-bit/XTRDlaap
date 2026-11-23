# X13 GLOBAL — delivery

## What was built

| File | Role |
|---|---|
| `X13_GLOBAL_TREND.mq5` | **Final EA.** H4/H1 Donchian breakout + EMA50 pullback, ATR stop, 3R target, risk-based sizing, capital floor |
| `X13_EXPORT.mq5` | Data agent: dumps M1 bars + real spread for research |
| `tools/strategy_lab.py` | M1 screening harness (8 families, IS/OOS split) |
| `tools/strategy_lab_htf.py` | H1/H4 screening harness |
| `X13_EXPERIMENT_LOG.md` | All 9 experiments, both phases, with numbers |

The six earlier builds (`X13_MICRO_10`, `X13_GROWTH_10`, `X13_TREND_10`,
`X13_EDGE_10`, `X13_HFT_10`, `X13_RUNNER_10`) are kept as the failure record.

## Installation

1. Copy `X13_GLOBAL_TREND.mq5` to `MQL5/Experts/`.
2. Compile in MetaEditor (F7). Result: 0 errors, 0 warnings.
3. Attach to `XAUUSD` on **M1** (the EA reads H4 internally).
4. Enable algorithmic trading.

## Parameters

| Input | Default | Meaning |
|---|---|---|
| `InpTF` | H4 | signal timeframe |
| `InpBreakBars` | 20 | Donchian lookback |
| `InpFastEMA` / `InpSlowEMA` | 50 / 200 | trend filter |
| `InpSlATR` | 2.0 | stop = ATR × 2 |
| `InpTpMult` | 3.0 | target = stop × 3 |
| `InpRiskPct` | 2.0 | equity risk per trade |
| `InpMaxPositions` | 1 | concurrency |
| `InpHaltPct` | 30.0 | stop trading after this loss |

`InpRiskPct` must be raised to 6 on a $1,000 account, because one trade with
a 5,400-point stop needs $54.

## Measured performance

October 2026, deposit $1,000, risk 6%, real ticks:

| Metric | Value |
|---|---|
| Trades | 6 |
| Win rate | 66.7% |
| Profit factor | 5.73 |
| Net | +$537.69 (+53.8%) |
| Max drawdown | 6.0% |
| Recovery factor | 8.96 |

Screening across 23 months (2025–2026) shows the same family positive in both
halves: H4 breakout +3,678 pts/trade, H4 pullback +4,834 pts/trade.

## Known limitations

1. **Requires ≥ $900.** At $10 the stop alone risks 540% of the account.
2. **Low frequency.** 6–10 trades per month. Not an HFT system; the HFT
   families measured zero gross edge across 322,000 trades.
3. **Trend dependent.** The edge comes from directional gold markets. A long
   ranging year is untested.
4. **Two years of data.** Enough for an IS/OOS split, not enough for a
   multi-cycle proof.

## Safe operation

- Demo only until forward results match the backtest.
- Never raise `InpRiskPct` above 10.
- Keep `InpHaltPct` at 30 or lower.
- One position maximum on a sub-$5,000 account.
