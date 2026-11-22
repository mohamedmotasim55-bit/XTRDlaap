# XTRD OMIGA — iteration changelog

Target account: JustMarkets Standard, XAUUSD, spread 25-35 points, no commission,
deposit 100 USD, leverage 1:1000. Stress test: real ticks, 15 ms execution delay.

Scoring: `score = net_profit * min(profit_factor, 3) - 0.5 * equity_dd_rel`.
An iteration is reverted when its score is below the best previous score.

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
