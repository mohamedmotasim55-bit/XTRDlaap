# XTRD OMIGA — structural diagnosis for JustMarkets Standard XAUUSD

Target profile: XAUUSD, spread 25-35 points, zero commission, deposit 100 USD,
leverage 1:1000, stress test with 15 ms execution delay on real ticks.

Unit convention used throughout: 2-digit gold, `point = 0.01`, contract size 100 oz,
so **1 point on 0.01 lot = 0.01 USD**, and a 30-point spread costs 0.30 USD per
0.01 lot per round trip (0.30 % of a 100 USD account).

## 1. Why the original geometry cannot work on this account

`tools/geometry_model.py` solves the barrier problem for a fixed spread. For a long
entry at ask `A`, spread `c`, mid `M = A - c/2`:

- the TP price `A+T` is reached when the mid reaches `A+T+c/2`, i.e. `T + c/2` away;
- the SL price `A-S` is reached when the mid reaches `A-S+c/2`, i.e. `S - c/2` away;
- P/L relative to the entry price is exactly `+T` or `-S`, so the break-even hit
  rate is `p* = S/(S+T)`;
- a driftless random walk hits the upper barrier first with probability
  `p0 = (S - c/2)/(S + T)`;
- the signal must therefore supply `p* - p0 = (c/2)/(S+T)` of real edge.

```
spread=30 pts  lot=0.01  equity=100 USD
round-trip spread cost per trade: 0.30 USD (0.30% of equity)

configuration                             RR      p*      p0    edge  spread bleed
----------------------------------------------------------------------------------
v2.23 baseline (SL 32 / TP 45)          1.41   41.6%   22.1%   19.5%         30.0%
v2.23 stretched (SL 48 / TP 70)         1.46   40.7%   28.0%   12.7%         30.0%
v2.30 spread floors (SL 180 / TP 270)   1.50   40.0%   36.7%    3.3%         30.0%
v2.30 wide (SL 240 / TP 360)            1.50   40.0%   37.5%    2.5%         30.0%
```

The original `SL 32 / TP 45` needs **19.5 percentage points of hit-rate skill**;
the spread-aware geometry needs **3.3**. That is the whole ballgame: the original
EA is not badly tuned, it is asking the signal to be six times better than it can be.

## 2. Defect list

Severity: **F** = fatal (guaranteed loss or no trading), **H** = high, **M** = medium.

| # | Sev | Defect | Where | Consequence | Fix applied in v2.30 |
| --- | --- | --- | --- | --- | --- |
| 1 | F | `InpMinSLPts = 32` and `SL = 0.8*ATR(M1)`; M1 gold ATR is 20-60 pts | `BuildSignal`, `RepairPositionStops` | Stop sits 1.0-1.6x the spread; with a 30-pt spread the stop is ~2 pts below the bid and is hit on the next down tick | `SL = max(0.55*ATR(M5), 6*spread)`, floor 150 pts |
| 2 | F | `TP = 1.2*ATR(M1)` = 45-70 pts against a 30-pt spread | `BuildSignal` | Only 15-40 pts of the target is capturable; required hit rate 42 % vs 22 % achievable | `TP = max(1.10*ATR(M5), 9*spread)`, at least 1.25x SL |
| 3 | F | BE stage 1 at `+5.5` pts locking `+1.8` pts | `ManagePositions` | The lock is inside the spread: every "protected" trade is closed at about `-spread` | Stages at `2.2*spread` / `4*spread`, locks at `0.6*spread` / `1.8*spread` |
| 4 | F | `InpSpreadExpansionMaxPts = 30` used as an absolute spread cap | `SpreadGate` | On a 25-35 pt account the shield rejects most valid entries; the EA barely trades | Cap is now `baseline + 15` (relative to the account) |
| 5 | F | `edge >= spread * 1.10 * 0.5` (0.475x) | `SpreadGate` | Entries were allowed when the expected capture was half the round-trip cost | `edge >= 1.5 * spread` |
| 6 | H | `edge = (2p-1) * ATR * targetATR` — not a price distance | `BuildSignal` | The edge gate never measured the tradable move; `InpMinEdgePts = 3` was meaningless | `edge = (2p-1) * TP` in points, floor 25 |
| 7 | H | ATR taken on M1 while the spread is a fixed 25-35 pts | `OnInit` (`iATR(PERIOD_M1)`) | A volatility measure smaller than the cost cannot size anything | `InpATRTimeframe = PERIOD_M5` |
| 8 | H | 15 concurrent positions, 6 per direction, portfolio risk 10 % | inputs | Spread bleed multiplied by 15 on a 100 USD account | 4 positions, 2 per direction, 6 % portfolio risk |
| 9 | H | `InpMaxTradeAgeSec = 240` | `ManagePositions` | A 45-70 pt target rarely forms in 4 minutes, so trades were cut flat at a loss | 900 s; stall exit only below `-1*spread` |
| 10 | M | Partial close at 50 % of TP for 60 % of volume | `ManagePositions` | Pays the spread twice; cannot split a 0.01 lot at all | Disabled by default |
| 11 | M | No volatility floor | `BuildSignal` | Trades taken in dead tape where the target cannot clear the spread | Skip when `ATR(M5) < 3*spread` |
| 12 | M | Trailing floor `InpMinSLPts` (32 pts) | `ManagePositions` | Trail sits inside the spread | Trail floor `2*spread` |
| 13 | M | Risk-sized lot falls below the 0.01 minimum on 100 USD with a 150+ pt stop | `RiskLot` | Silent zero-trade account | Minimum-lot fallback, used only while the resulting risk stays inside the risk cap |
| 14 | M | No strategy attribution for SL/TP exits in the HTML report | `OnTradeTransaction` | The loop cannot tell which strategy loses | Per-trade ledger `X13_Omega_Ledger.csv` |

## 3. Resulting parameter profile (v2.30)

- SL 180 / TP 270 points at a 30-point spread (6x / 9x the spread), RR 1.5.
- Break-even hit rate 40 %, random-walk hit rate 36.7 % → 3.3 points of required edge.
- Risk 1.5 % per trade; with 180-point stops that is 0.01 lot on 100 USD, i.e.
  1.8 % real risk per trade including the spread.
- At most 3 concurrent positions on 100 USD (portfolio risk cap 6 %, 1.8 USD each).
- Spread bleed at 100 trades: 30 % of the account. **Trade count must fall**; the
  spread-aware geometry naturally reduces it because targets are 6x larger.

## 4. What has not been measured

No backtest was executed. Two blockers, both outside the code:

1. **No write access to the repository.** The available GitHub credential returns
   `403 Resource not accessible by integration` for `contents` writes, so the
   workflow file cannot be pushed and no run can be started.
2. **No MT5 credentials.** `MT5_LOGIN`, `MT5_PASSWORD`, `MT5_SERVER` are not set in
   the repository; without them the terminal cannot log in, cannot download XAUUSD
   real-tick history, and the tester cannot run.

Consequently the numbers in section 1 are arithmetic, not measurements. The
iteration loop is fully wired (`tools/run_iteration.sh`, `tools/analyze_backtest.py`)
and produces the measured table in `CHANGELOG.md` as soon as those two blockers are
removed.

## 5. Residual risks in v2.30

- The M5 ATR floor (`3x spread`) may block trading in quiet sessions; if the trade
  count is too low the first measurement should test `InpMinATRSpreadMultiple = 2.0`.
- The probability model (`ConditionalScore`) was never calibrated on data, so
  `p >= 0.583` (needed for `edge >= 1.5*spread` at a 30-pt spread) may be rare.
  If the run produces too few trades, the honest fix is to lower
  `InpEdgeToSpreadMin` to 1.2 and measure, not to widen the targets again.
- `GMT_Hour()` shifts `TimeCurrent()` by a fixed -2 h in the tester, which is wrong
  during the server's DST half-year. The session router and the news windows are
  therefore approximate.
- The EA still requires a hedging account (`InpRequireHedgingAccount`). On a netting
  account `OnInit` returns `INIT_FAILED` and the run produces zero trades.
