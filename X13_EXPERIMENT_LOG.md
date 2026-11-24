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

---

# Phase 3 — Scalping war loop

## Experiment S1: tick-activity scalper (`X13_SCALP.mq5`)

Signal: volume-per-point burst (tick volume / bar range) above 2x the 50-bar
baseline, body above 0.4 ATR. Exit: SL 90, TP 150, break-even at 60,
trail 60 from 100, time exit 30 bars. One position, min lot, real ticks.

### Why this family

`tools/scalp_lab.py` measured **gross** expectancy (before spread) for every
M1 family over 23 months:

| Family | TP40 | TP80 | TP150 | TP300 |
|---|---|---|---|---|
| micro_burst | −10.8 | −8.4 | −5.1 | −0.6 |
| **tick_activity** | −5.2 | **+0.6** | **+3.1** | **+6.6** |
| micro_break5 | −10.9 | −8.7 | −6.3 | −5.1 |
| micro_pullback | −9.6 | −6.8 | −4.0 | −3.1 |
| micro_reversion | −10.4 | −6.9 | −2.6 | **+1.1** |
| exhaustion | −12.0 | −9.3 | −8.1 | −8.5 |
| vol_expand | −14.6 | −14.4 | −12.7 | −9.6 |

Mean spread over the sample: **22.3 points**. Only tick_activity produces a
positive gross edge, and its best value (+6.6) is 15.7 points below the cost.

### Three-month validation (real ticks, $10, JustMarkets)

| Month | Trades | Win% | PF | Net | Final |
|---|---|---|---|---|---|
| 2026-10 | 20 | 55.0 | 1.85 | **+63.7%** | $16.37 |
| 2026-09 | 26 | 23.1 | 0.56 | **−62.6%** | $3.74 |
| 2026-06 | 12 | 16.7 | 0.36 | **−57.0%** | $4.34 |

October detail: 11W / 9L, avg win $1.26, avg loss $0.83, expectancy $0.32,
max drawdown $2.53 (25.3%).

### Significance test

October expectancy $0.318 with standard deviation $1.15 over 20 trades:
t = 1.24. The 5% threshold for n=20 is 2.09. **October is statistically
indistinguishable from zero.** Combined across the three months, 58 trades
average −$0.096 per trade.

### Verdict: REJECTED

Failure category: signal edge below transaction cost. Not an exit-logic
problem, not a sizing problem, not a session problem. The gross edge is
smaller than the spread, so every trade starts behind.

## Structural conclusion

| Quantity | Value |
|---|---|
| Mean spread | 22.3 pts |
| Best measured gross edge (M1, any family) | +6.6 pts |
| Required gross edge to break even | > 22.3 pts |
| Deficit | 15.7 pts per trade |

At 0.01 lot the cost is fixed at 2.2% of a $10 account per round turn. No
sizing, trailing or concurrency design changes that number.

## What is proven to work

Only one configuration has survived out-of-sample testing: H4 breakout and
pullback with ATR stops (+53.8% on $1,000, PF 5.73, 6% drawdown). It is
excluded by the current brief, which requires intraday scalping. If the
constraint is relaxed, that engine is ready in `X13_GLOBAL_TREND.mq5`.

## What would make scalping viable

| Change | Effect on cost |
|---|---|
| Raw account, 8-10 pt spread | 22.3 → 9 pts, deficit closes |
| Cent account (0.001 lot) | risk per trade 9% → 0.9% |
| Zero-spread account | edge +6.6 becomes profitable |

These are account-type decisions, not code decisions.

---

# Phase 4 — Root-cause repair

## Cost audit (section 4 of the brief)

| Check | Result |
|---|---|
| Spread counted once per round turn | yes |
| Bid/ask direction correct | yes (buys fill at ask, sells at bid) |
| Double counting | none |
| Points vs price | 1 point = 0.01 USD, 1.00 move = 100 pts |
| Commission | 0 on this account |
| Verified against real fills | buy 4023.18 / sell 4023.75 = +57 pts; without cost +79 pts → cost 22 pts |
| Strategy entering on widened spread | 13-24 entries rejected by the spread filter, correctly |

The cost model is correct. 22.3 pts = $0.22 per round turn at 0.01 lot = 2.2%
of a $10 account.

## Failure map

| Horizon | Entry | Stops | Gross expectancy | Verdict |
|---|---|---|---|---|
| M1 | 7 families, 322k trades | fixed | −28 to +6.6 pts | below cost |
| M5 | breakout20 | fixed 75-900 | −38 to −3 pts | below cost |
| M15 | breakout20 | fixed | −72 to +0.4 pts | below cost |
| H1 | brk20/55 | ATR | +1,204 / +2,508 | positive |
| H4 | brk20 / pullback | ATR | +3,678 / +4,834 | positive |

Live months, `X13_SCALP` v1, $10, real ticks:

| Month | Trades | Win% | Net |
|---|---|---|---|
| 2026-10 | 20 | 55.0 | +63.7% |
| 2026-09 | 26 | 23.1 | −62.6% |
| 2026-06 | 12 | 16.7 | −57.0% |

All three months were downtrends of similar size (net −284 / −293 / −514,
ADR 2,382 / 2,872 / 3,388). The hypothesis that October trended while the
others ranged is **false**. October is variance.

## Repair R1 — higher-timeframe context filter

`X13_SCALP2.mq5`: trade only in the M15 EMA50 direction.
June: 9 trades, 11.1% win, −$5.30 (baseline −$5.66). No repair.

## Repair R2 — session filter

Hours 8-21 only. Hour 22 had produced 12 trades at 16.7% win rate, −$6.35.
September: 10 trades, 20.0% win, −$5.51 (baseline −$6.26). No repair.

## Statistical proof of the blocker

Best M1 family (`tick_activity`), 998 trades, 23 months:

```
gross expectancy = −4.34 pts   sd 226.2   se 7.16   t = −0.61
95% CI            = [−18.38, +9.69] pts
spread            = 22.3 pts
```

The upper confidence bound of the best available gross edge is **9.7 points**.
The cost is **22.3 points**. No exit design, sizing scheme, trailing rule or
concurrency model can close a gap of 12.6 points that exists before any trade
management is applied.

## Status: BLOCKED

The blocker is not capital, not leverage, not code. It is that no M1/M5/M15
signal family in this project has a gross edge that is statistically
distinguishable from zero, and the account's fixed cost per round turn is
2.2% of equity.

Repairs attempted and their measured results are recorded above. Two targeted
repairs (context, session) were implemented, tested on real ticks and did not
change the outcome.

## What is proven to work

H1/H4 breakout and pullback with ATR stops: +53.8% on $1,000 in October 2026,
PF 5.73, 6% drawdown, and positive in both halves of a 23-month screen.
That engine exists in `X13_GLOBAL_TREND.mq5`. It is excluded by the current
brief, which forbids trend engines as the core.

---

# Phase 5 — Raw tick research

## Data

`X13_EXPORT_TICKS.mq5` dumps the raw feed. Sample: **4,378,000 ticks over 10
days**, real ticks, same account.

| Field | Usable? |
|---|---|
| bid / ask | yes, both move on 79% of ticks |
| tick volume | yes |
| flags | yes |
| **last traded price** | **NO — 0 for 100% of ticks** |

The absence of a last price removes every classic microstructure feature:
trade-at-ask ratio, Lee-Ready classification, order-flow imbalance. This is a
feed limitation of the broker's XAUUSD.m, not a code issue.

## Opportunity analysis

| Horizon | mean abs move | P(abs move > 26 pt spread) |
|---|---|---|
| 1 s | 15.5 | 17.8% |
| 5 s | 37.1 | 47.6% |
| 10 s | 53.2 | 61.0% |
| 30 s | 93.4 | 77.0% |
| 60 s | 132.0 | 83.7% |
| 300 s | 295.2 | 92.8% |
| 900 s | 524.7 | 96.3% |

Opportunities are abundant: at 5 minutes, 92.8% of moments produce a move
larger than the spread. The cost is not the binding constraint at these
horizons. **Direction is.**

## Required directional accuracy

For a symmetric trade, break-even needs
`P(win) > 0.5 + cost / (2 x move)`:

| Horizon | Required P(win) | Measured P(up) |
|---|---|---|
| 60 s | 59.9% | 48.1% |
| 300 s | 54.4% | 45.4% |
| 900 s | 52.5% | 43.2% |

## Features tested (all past-only, all on bid/ask/timing)

| Feature | Windows | Result |
|---|---|---|
| short-term return | 1 s, 5 s, 30 s, 60 s, 300 s | no edge |
| uptick ratio | 5 s, 30 s | no edge |
| tick arrival rate | 5 s | no edge |
| acceleration | 1 s vs 2 s | no edge |
| spread state | rolling median | no edge |

Every cell was re-tested as a **non-overlapping event stream** because decile
analysis on overlapping ticks inflates significance. The decile study showed
several cells at +30 to +50 points; the event stream reduced all of them to
zero or negative. Example: `ticks5s LOW` showed +51.4 points in the decile
view and turned negative once overlaps were removed.

## Mean reversion vs momentum, hold 900 s

| Signal | n | net per trade | t |
|---|---|---|---|
| fade 30 s move >= 40 | 735 | −14.1 | −0.6 |
| fade 60 s move >= 80 | 729 | −35.1 | −1.5 |
| follow 300 s move >= 150 | 718 | −3.4 | −0.1 |
| uptick >= 0.4 | 720 | +10.7 | +0.4 |

Walk-forward on the best candidate split −12.6 (first 5 days) and −14.9
(last 5 days): consistent, consistently negative.

## A false positive I caught

An `imbalance` feature defined as `(last - mid) / spread` produced an
apparent edge of +156 points at t = +42.9. It was an artefact: `last` is
zero, so the feature was `-mid / spread`, i.e. a disguised price-level
variable. Discarded.

## Status: BLOCKED

The blocker is directional predictability, not cost. At the horizons where
scalping lives (5-300 s), the market produces moves 5 to 11 times the spread,
but no feature built from the available feed moves the win probability more
than one or two points away from 50%. The requirement is 52.5% to 59.9%.

Tested and failed: 7 M1 families (322k trades), M5/M15 breakout with fixed
stops, 5 live months of the burst scalper, 2 targeted repairs (context,
session), 4.4M ticks across 6 features, 9 horizons, mean reversion and
momentum, with non-overlapping execution and walk-forward splits.

## What is unavailable on this account

- Last traded price (removes order-flow features)
- Market depth / order book (removes liquidity imbalance)
- Cross-asset data such as DXY or US10Y inside the terminal
- Sub-100 ms latency for any news reaction

Any of these could contain the missing edge. None of them exist in this
environment.
