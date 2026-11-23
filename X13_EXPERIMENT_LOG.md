# X13 — Experiment log, $10 XAUUSD account

Broker: JustMarkets demo · Symbol: XAUUSD.m · M1 · Model 4 (real ticks)
Period: 2026.10.23 → 2026.11.22 (11,275,252 ticks) · Deposit $10 · Leverage 1:3000
Spread: 26 pts (99.85% of the month) · Commission 0 · Execution delay 50 ms

## Structural constants

| Quantity | Value |
|---|---|
| Minimum volume | 0.01 lot (1 oz) |
| Value of 1 point at 0.01 lot | $0.01 |
| Minimum risk per trade at 100 pt stop | **$1.00 = 10% of equity** |
| Minimum risk per trade at 200 pt stop | **$2.00 = 20% of equity** |
| Spread cost per round turn | **$0.26 = 2.6% of equity** |
| Losses that wipe $10 at 20% risk | **~5** |

Key consequence: at $10 the position size cannot be scaled down. Every trade risks a
fixed 10–30% of the account, so the account is destroyed by any ordinary losing streak
before compounding can act.

## Experiments

| # | Build | Entry logic | Exit | Slots | Trades | Win | Final | Return |
|---|---|---|---|---|---|---|---|---|
| 1 | X13_GROWTH_10 | M5 breakout, pyramiding | ATR SL/TP + trail | 4 | 6 | 2 | $2.63 | −74% |
| 2 | X13_TREND_10 | M5 breakout + H1 bias | 1 ATR stop, 12 ATR target, trail | 2 | 2 | 0 | $4.30 | −57% |
| 3 | X13_EDGE_10 | M5 pullback to EMA21, overlap | 110 pt SL / 220 pt TP | 3 | 4 | 1 | **$8.81** | **−12%** |
| 4 | X13_HFT_10 | M1 burst, 24 h, dynamic risk | 200/200 pt fixed | 3 | 5 | 0 | −$0.21 | **−102%** |
| 5 | X13_RUNNER_10 | 20-bar breakout, 24 h | 120-140 pt stop + trail | 1 | 3 | 0 | $5.61 | −44% |

Twenty closed trades, four wins → 20% win rate. Spread alone consumed 52% of the account.

All runs compiled with 0 errors. All numbers are MT5 tester output.

### Why experiments 2 and 3 stopped trading

After equity fell, the minimum lot risk exceeded the risk cap and the EA correctly
refused further entries:

```
equity $2.63 · stop 184 pts · 0.01 lot → minimum risk $1.84 = 70% of equity
cap was 45%  →  every later entry blocked
```

This is protection working as designed, not a bug.

## Monte Carlo requirement

For $10 → $50,000 (5000×) the required edge, simulated over 400 trades:

| Risk/trade | Win rate | RR | P(reach $50k) | P(ruin) |
|---|---|---|---|---|
| 10% | 45% | 2.0 | 69.7% | 0.03% |
| 10% | 50% | 2.0 | 99.4% | 0.00% |
| 20% | 45% | 2.0 | 75.1% | 9.40% |
| 30% | 45% | 2.0 | 42.3% | 48.6% |

The target is arithmetically reachable, but only with a **≥45% win rate at RR 2**
sustained over ~400 trades.

## Measured edge

Across the four builds the realised win rate on gold M5 entries was **25–33%**,
below the 33.4% break-even for RR 2 and far below the 45% the target requires.

Nineteen closed trades in total is a small sample, but the direction is consistent
with the spread: 26 points of cost against a 110-point stop consumes 24% of the
risk budget before the market moves at all.

## Conclusion

The blocker is not the code and not the platform. It is:

1. **No identifiable edge** in the tested M5/M1 families on this data.
2. **Fixed minimum lot** forcing 10–30% equity risk per trade at $10.
3. **26-point spread** eating a quarter of every stop.

Reaching $50k from $10 needs a strategy that wins 45%+ at RR 2 across hundreds of
trades. The evidence gathered here does not support that, so the target is not
delivered and is not claimed.

## Best artifact

`X13_EDGE_10.mq5` — the only build that survived the month with a controlled loss
(−12%), fixed risk per trade, and no runaway position sizing.

## Cost arithmetic (binding constraint)

At 0.01 lot one point is $0.01, so a round turn at the 26-point spread costs
**$0.26 = 2.6% of a $10 account**. The position cannot be scaled below 0.01,
so the ratio is fixed.

| Trades to target | Net/trade needed | + spread | Gross edge needed |
|---|---|---|---|
| 50 | 18.57% | 2.6% | 21.17% |
| 100 | 8.89% | 2.6% | 11.49% |
| 200 | 4.35% | 2.6% | 6.95% |
| 400 | 2.15% | 2.6% | 4.75% |
| 5000 | 0.17% | 2.6% | 2.77% |

The asymptote is 2.60%: every trade must earn more than 26 points gross,
forever. Measured win rate across the six builds was 20% against the 33%
break-even for a 1:2 payoff, so no build reached that threshold.

## Conditions that would make the target reachable

1. Spread ≤ 10 pts (Raw account) — cost per trade falls from 2.6% to 1.0%.
2. Cent account (0.001 lot) — risk per trade 1.2% instead of 12%.
3. At least 12 months of tick data for out-of-sample validation.
4. Deposit ≥ $500 so sizing has room to operate.

---

# Phase 2 — Strategy lab (23 months, real ticks)

Data: 669,324 M1 bars exported from MT5 with the real per-bar spread
(2025.01.02 → 2026.11.20). Screened in `tools/strategy_lab.py` and
`tools/strategy_lab_htf.py`, split in-sample 2025 / out-of-sample 2026.

## Result 1 — every M1 family has zero gross edge

| Family | Trades | Win% | Net expectancy | IS | OOS |
|---|---|---|---|---|---|
| mean_reversion | 10,541 | 43.2 | −19.9 pts | −24.9 | −14.4 |
| false_breakout | 32,748 | 37.3 | −19.5 | −24.0 | −14.5 |
| pullback | 41,384 | 31.0 | −21.8 | −26.6 | −16.3 |
| vol_expansion | 30,820 | 32.0 | −21.8 | −24.4 | −19.0 |
| momentum_burst | 102,327 | 30.7 | −24.9 | −26.6 | −23.0 |
| breakout_trend | 46,752 | 30.5 | −27.3 | −27.8 | −26.8 |
| compression_break | 28,333 | 26.4 | −27.7 | −25.4 | −30.1 |

322,000 trades. Every family loses approximately one spread per trade,
which means the signals carry **no predictive information** at M1 and the
P&L is exactly the transaction cost. This explains all six earlier builds.

## Result 2 — an edge exists on H4, but only with wide stops

| Config | Trades | Win% | Expectancy | IS | OOS |
|---|---|---|---|---|---|
| H4 brk20 + ATR stop | 257 | 44.0 | **+3,678 pts** | +3,344 | +4,066 |
| H4 pullback + ATR stop | 209 | 46.9 | **+4,834 pts** | +3,203 | +6,418 |
| H1 brk55 + ATR stop | 624 | 33.5 | **+2,508 pts** | +1,261 | +4,387 |
| H4 brk20, stop 400 pts | 257 | 19.8 | −87 pts | −29 | −155 |
| H4 pullback, stop 400 pts | 209 | 17.7 | −124 pts | −138 | −111 |
| H1 brk55, stop 400 pts | 624 | 23.6 | −29 pts | +15 | −95 |

The edge lives entirely in the wide ATR stop. Tightening the stop to what a
$10 account can afford destroys it, in both halves, on every family.

## Result 3 — MT5 confirmation

`X13_GLOBAL_TREND.mq5`, deposit $1,000, risk 6%, October 2026:

| Metric | Value |
|---|---|
| Trades | 6 |
| Win rate | 66.7% (4W / 2L) |
| Profit factor | 5.73 |
| Net profit | **+$537.69 (+53.8%)** |
| Max drawdown | $60.00 (6.0%) |
| Recovery factor | 8.96 |
| Expectancy | $89.62 / trade |

## Capital requirement (measured, not assumed)

A 0.01 lot trade with a 5,400-point stop risks **$54**. Therefore:

| Risk per trade | Minimum equity |
|---|---|
| 2% | $2,700 |
| 6% | $900 |
| 10% | $540 |

At $10 the same trade risks 540% of the account, so no position is possible.
This is the documented blocker: the strategy is real, the account is not.

## Path to $3,000

Starting at $1,000 with 6% risk and +53.8%/month measured:

| Month | Equity |
|---|---|
| 0 | $1,000 |
| 1 | $1,538 |
| 2 | $2,366 |
| 3 | $3,640 |

Three months to the $3,000 target, assuming the edge persists.
