# MT5 Training Camp — Iteration 1

## Result (MT5 real ticks, 30 days, $10, 1:3000)
- Net: -$9.50 | PF 0.79 | Trades: 61
- Profit trades: 18 (29.51%) | Loss trades: 43 (70.49%)
- Avg win: $2.04 | Avg loss: -$1.07 (R:R 1.9:1)
- Break-even WR = 1.07/(2.04+1.07) = 34.4%
- Actual WR 29.5% -> 4.9% BELOW break-even
- Max consecutive losses: 7 (-$7.66)

## Diagnosis
The engine's reward:risk is fine (1.9:1) but WR is 5 points short.
Need to remove ~3 losers out of 61 without touching the 18 winners.

## Features logged per entry (telemetry)
atr, spread, c1, hh, ll, hour, pulse

## Next iteration
Learn a filter from the 43 losers: find feature ranges where WR < 25%.
Apply as EA gate, re-run MT5.

# Iteration 2 — learned filter (hours 15,21 + ATR>=200)
- Net: -$8.92 | PF 0.70 | Trades: 37 | WR 27.0% | DD $15.09 (93%)
- The per-hour WR from iter1 did NOT transfer: filtering changed the trade
  sequence, so historical hour-WR no longer applies.
- Conclusion: the FADE engine's edge is too weak (WR ~27-30% vs 34.4% break-even).
  Filters do not fix a weak base edge.
