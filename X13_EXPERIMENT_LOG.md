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
