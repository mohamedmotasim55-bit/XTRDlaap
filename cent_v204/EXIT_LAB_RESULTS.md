# V2.0.5 H2 Exit Lab — full results

Symbol XAUUSD, real ticks (Model 4), execution 15 ms, leverage 1:3000, deposit 1000,
risk 0.25%, box cap 60 points, stop 40-70 points, spread 26 points.

Compile after fixing one missing `)` in the `OnInit` `LogMsg` call: 0 errors, 0 warnings.

## 1. Exit ladder — window 2026.10.24 .. 2026.11.23

| Target | Trades | Net | Net % | PF | Win rate | Avg win | Avg loss | Payoff | Break-even WR | Expectancy | Max DD |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1.5R (A) | 245 | -124.60 | -12.46% | 0.65 | 30.20% | 3.15 | -2.09 | 1.51 | 39.9% | -0.51 | 13.73% |
| 2.0R (B) | 244 | -86.05 | -8.61% | 0.77 | 27.87% | 4.18 | -2.10 | 1.99 | 33.4% | -0.35 | 10.26% |
| 2.5R (C) | 243 | -69.61 | -6.96% | 0.82 | 25.10% | 5.14 | -2.11 | 2.44 | 29.1% | -0.29 | 8.53% |
| 3.5R | 238 | -12.31 | -1.23% | 0.97 | 22.27% | 7.36 | -2.17 | 3.39 | 22.8% | -0.05 | 4.53% |
| 4.0R | 237 | **+36.46** | **+3.65%** | **1.09** | 21.94% | 8.81 | -2.28 | 3.86 | 20.6% | +0.15 | 4.68% |
| 2.5R + BE at 1R (D) | 249 | -118.26 | -11.83% | 0.66 | 22.49% | 4.09 | -1.80 | 2.27 | 30.6% | -0.47 | 12.29% |
| 2.5R + 45 s time exit (E) | 259 | -118.97 | -11.90% | 0.60 | 30.89% | 2.21 | -1.65 | 1.34 | 42.8% | -0.46 | 13.32% |

Reference (v2.0.4, harvest 35 points): 240 trades, -119.89 (-11.99%), PF 0.53, win 46.25%,
payoff 0.62, break-even WR 61.9%.

### What the ladder says

* Cutting winners early (35 points, 1.5R, 2.0R, 2.5R) is what destroys the system.
  The shorter the exit, the larger the loss.
* Break-even (D) and time decay (E) both make the 2.5R variant worse: they convert
  would-be runners into flat trades.
* The edge, if any, lives in the tail. Only targets of 3.5R and above get close to zero.

## 2. Out-of-sample check at 4.0R

| Window | Trades | Net | Net % | PF | Win rate | Avg win | Avg loss | Max DD |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 2026.08.25 .. 09.23 | 54 | -53.30 | -5.33% | 0.50 | 11.11% | 9.02 | -2.24 | 7.41% |
| 2026.09.24 .. 10.23 | 59 | -92.72 | -9.27% | 0.42 | 13.56% | 8.43 | -3.14 | 10.41% |
| 2026.10.24 .. 11.23 (tuning) | 237 | +36.46 | +3.65% | 1.09 | 21.94% | 8.81 | -2.28 | 4.68% |

Three months combined: 350 trades, **-109.56 (-3.65% per month)**, 40 winning trades in 350.

The winning month is not a repeatable edge:

* it produced **4.4x** the trade count of the other two months (237 vs 54 and 59),
* its win rate was 21.9% against 11-13% elsewhere,
* 4R needs a ~260 point run after entry, which only a trending month supplies.

The point estimate +3.65% has t = 0.50 (237 trades, per-trade sigma 4.59): not
distinguishable from zero even inside the month it was found in.

## 3. Conclusion

Seven exit settings, three box widths and three months all point to the same thing:
the H2 compression breakout on a 26-point spread has no measurable edge. Gross capture
before cost is about +10 points against a 26-point spread, so the signal recovers only
38% of its own transaction cost. Exit engineering moves the win rate and the payoff in
opposite directions and leaves the expectancy near -0.3 to -0.5 per trade.
