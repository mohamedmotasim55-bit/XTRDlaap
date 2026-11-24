# Opportunity Rejection Intelligence - first measurement

Run: density3, October 2026, XAUUSD.m, $10, 1:3000, real ticks.
Configuration: independent execution, 10 concurrent positions, edge floor 0,
pyramiding on, drawdown halt 95%.

## Measurement integrity

| Check | Result |
|---|---|
| Deal-history sum | -9.33 |
| TesterStatistics(STAT_PROFIT) | -9.33 |
| Mismatch | **0.0000** |

The EA's own per-engine P&L and the terminal's native statistics agree to the
cent. Measurement is trustworthy.

## Result

34 trades, 11 wins, 23 losses, 32.4% win rate, net -9.33, drawdown 94.6%.

## Rejection audit (every rejected opportunity replayed with real costs)

Reason codes: 1 spread, 2 signal quality, 8 margin/minimum lot.

| Engine | Reason | Rejected | Would win | Would lose | Net if taken |
|---|---|---|---|---|---|
| BURST | 8 margin | 18 | 9 | 9 | **+2.52** |
| MOMENTUM | 8 margin | 13,357 | 4,401 | 8,909 | -3,552.65 |
| MOMENTUM | 1 spread | 8 | 3 | 5 | -0.01 |
| REVERSION | 8 margin | 6,147 | 2,411 | 3,734 | -1,804.15 |
| REVERSION | 1 spread | 4 | 3 | 1 | +4.72 |
| TICKFLOW | 8 margin | 4,516 | 1,709 | 2,807 | -982.88 |
| TICKFLOW | 2 quality | 183 | 71 | 112 | -33.54 |
| TICKFLOW | 1 spread | 1 | 0 | 1 | -1.58 |
| EXHAUSTION | 8 margin | 1,368 | 545 | 823 | -289.97 |
| EXHAUSTION | 1 spread | 1 | 0 | 1 | -1.69 |
| **Total** | | **25,603** | **9,152** | **16,402** | **-6,659.23** |

## What this proves

1. **99.2% of rejections are margin-driven**, not quality-driven. 25,406 of
   25,603 rejections are the lot engine refusing a size below the broker
   minimum on a $10 account.

2. **The rejected opportunities were losing propositions.** Taking all 25,603
   would have lost $6,659 on a $10 account. The filters were not hiding
   winners; they were blocking losers.

3. **Only BURST's rejected set was positive** (+$2.52 over 18 cases), which is
   noise at that sample size.

4. Win rates of the rejected populations: MOMENTUM 33%, TICKFLOW 38%,
   REVERSION 39%, EXHAUSTION 40%, BURST 50%.

## The 600 trades/day and 95% win rate target

With TP = 30 points and SL = 50 points at a 26-point spread:

EV = 0.95 x 30 - 0.05 x 50 - 26 = 28.5 - 2.5 - 26 = **0.00**

A 95% win rate at those exits yields exactly zero profit per trade. To make
any profit at all the win rate must exceed 95%:

30p - 50(1-p) - 26 > 0  ->  80p > 76  ->  **p > 95.0%**

At 600 trades a day the spread alone costs $156 a day, which is 15.6 times the
account. The break-even win rate rises with every point of spread.

For a random walk, the probability of touching +30 before -50 is
50/(30+50) = 62.5%. The measured win rates are 32-50%. Reaching 95% requires a
directional edge that no measurement in this project has found.
