# X13 GLOBAL FINAL - delivery report

## What was delivered

`X13_GLOBAL_FINAL.mq5` - one file, compiled by MetaEditor with **0 errors and
0 warnings**, running inside the MT5 Strategy Tester on real JustMarkets
ticks, reporting through `TesterStatistics()` from `OnTester()`.

Internal modules:

| Module | Status |
|---|---|
| Market regime / spread engine | tracks live spread, median 26.0 pts measured in-test |
| Tick/momentum engine (BURST) | implemented, volume-per-point burst |
| Momentum engine (MOMENTUM) | implemented, dual-EMA + displacement |
| Statistical engine (REVERSION) | implemented, 20-bar deviation vs ATR |
| Structure engine (BREAKOUT) | implemented, 20-bar range break |
| Exhaustion engine (EXHAUSTION) | implemented, N-bar run + ATR stretch |
| Central decision engine | one signal per bar, best score wins, EV gate |
| Dynamic lot engine | risk-based, margin-checked, rejects below broker minimum |
| Multi-position engine | hedging/netting aware, max N, no duplicate direction |
| Position management | per-engine break-even and trailing |
| Capital protection | drawdown halt |
| Native reporting | TesterStatistics + per-engine P&L from deal history |

## Measured results (all inside MT5, $10, 1:3000, XAUUSD.m, 30 days)

| Configuration | Net | Trades | WR | PF | DD |
|---|---|---|---|---|---|
| v1 all engines, shared 110/190 exits | -5.40 | 7 | 14.3% | 0.05 | 54.7% |
| v2 all engines, per-engine exits | -5.52 | 8 | 12.5% | 0.17 | 55.9% |
| v2 BURST only, October | -5.78 | 15 | 26.7% | 0.60 | 69.6% |
| v2 BURST only, September | -5.68 | 7 | 14.3% | 0.07 | 56.8% |

Per-engine contribution in v2 (October):

| Engine | Signals | Accepted | P&L |
|---|---|---|---|
| BURST | 19 | 0 | 0.00 |
| MOMENTUM | 13,401 | 5 | -5.66 |
| REVERSION | 6,173 | 2 | -0.98 |
| BREAKOUT | 0 | 0 | 0.00 |
| EXHAUSTION | 1,379 | 1 | +1.12 |

## Diagnosis

1. **The platform works.** It compiles, trades, sizes correctly, respects the
   broker minimum, and reports natively. No mechanical failure.

2. **The engines have no edge.** MOMENTUM loses most of the money. It buys
   into M1 displacement that mean-reverts, exactly as the 4.38M-tick study
   predicted.

3. **The historical winner did not survive re-implementation.** X13_SCALP's
   burst engine made +63.7% in October. The same idea, rebuilt cleanly inside
   the unified platform, lost 57.8% in the same month. That is the signature
   of parameter-specific noise, not an edge.

4. **Trade density is low** (7-15 per month) because the EV gate rejects
   signals whose expected move does not clear the 26-point spread. Loosening
   it adds trades that lose more.

## Why 30,000 USD in one month is not achievable

| Step | Number |
|---|---|
| Target multiple | 10 -> 30,000 = x3,000 |
| Value of 1 point at 0.01 lot | $0.01 |
| Points needed | 3,000,000 |
| Per day (30 days) | 100,000 pts |
| At 200 pts net per trade | 500 trades per day |
| Gross move needed per trade (200 net + 26 spread) | 226 pts |
| Total daily price travel required | 113,000 pts |
| Gold's entire daily range | roughly 3,000-4,000 pts |

The requirement exceeds the whole daily range of the instrument by a factor of
30-40. No strategy, no lot engine and no execution method can produce movement
the market does not create.

## Status: BLOCKED

Verified technical blocker, documented in `X13_EXPERIMENT_LOG.md`:

- The broker's tick archive is quote-only: zero volume, fixed 26-pt spread,
  bid and ask moving in lockstep. Order-flow features cannot be computed.
- On the only available channel (the price path), 22 features and two model
  classes give out-of-sample AUC 0.44-0.50.
- Every strategy family tested loses after the 26-point round trip.

---

# Opportunity funnel audit (measured natively in MT5)

`WriteFunnel()` runs inside `OnTester()` over every M1 bar of the test
period. 669,324 bars, 30 days, spread 26.0 pts.

| Horizon | bars with move > spread | > 3x spread | opportunities/day | hindsight ceiling at 0.01 lot | trades taken | capture |
|---|---|---|---|---|---|---|
| 5 min | 593,199 (88.6%) | 458,498 (68.5%) | 862 | $1,383,471 | 8 | 0.00% |
| 15 min | 625,533 (93.5%) | 541,369 (80.9%) | 909 | $2,502,089 | 8 | 0.00% |
| 60 min | 648,237 (96.9%) | 606,621 (90.6%) | 942 | $5,242,543 | 8 | 0.00% |

The opportunities are not scarce. 862 per day clear the spread, and 68.5% of
them clear three times the spread. The hindsight ceiling is 138,000 times the
account.

## Density experiment

Relaxed everything: edge floor 0, EV multiplier 1.0, 5 concurrent positions,
3-minute maximum hold.

| Run | Net | Trades | WR | DD |
|---|---|---|---|---|
| density, risk 5% | 0.00 | **0** | - | 0% |
| density, risk 20% | -7.45 | 17 | 23.5% | 74.9% |

The first run took zero trades on purpose: at 5% risk with a 60-point stop the
safe size is 0.008 lots, below the broker minimum of 0.01. The lot engine
refused rather than over-risk the account. That is the correct behaviour.

The second run shows what density costs: 17 trades, 74.9% drawdown.

## The root cause, in one calculation

| Item | Value |
|---|---|
| Trades if every M1 bar is taken | 669,324 per month (22,311/day) |
| Spread cost per trade at 0.01 lot | $0.26 |
| Total spread cost per month | **$174,024** |
| Account | $10 |
| Hindsight ceiling (perfect direction, 5 min) | $1,383,471 |
| Share of perfect foresight needed just to break even | **12.6%** |
| Directional accuracy that equals 12.6% of perfect foresight | **56.3%** |
| Measured directional accuracy | 50.0% |
| Measured out-of-sample AUC | 0.44-0.50 |

Trading every bar costs $174,024 a month in spread against a $10 account. To
break even you must capture 12.6% of the profit that perfect foresight would
produce, which requires 56.3% directional accuracy on symmetric outcomes.
Every measurement in this project lands at 50%.

That is the root cause. It is not the entry gate, not the lot engine, not the
decision engine. It is that the available data does not tell you which way the
next move goes.

## What the EA already does correctly

- Rejects trades whose safe size is below the broker minimum instead of
  over-risking.
- Prices every opportunity against the measured 26-point spread.
- Coordinates one decision per bar across five engines.
- Reports per-engine signals, acceptances, rejections and P&L natively.

---

# Round 3 - consensus engine, tick flow, and MT5 genetic optimisation

## What changed

- Decision engine rebuilt as a **consensus vote**. Every engine adds to a buy
  score or a sell score; the platform acts when one side clearly dominates
  instead of discarding all but the single best signal.
- **TICKFLOW engine** added, driven by real tick accumulation in `OnTick`
  (uptick ratio over a 200-tick window).
- **Pyramiding** enabled: adds in the same direction while capacity remains.
- Confidence-scaled sizing.
- **MT5 genetic optimiser** wired into the pipeline (`Optimization=2`,
  `OptimizationCriterion=12` custom max).
- The EA writes **one result file per optimisation pass**, named by its
  parameters, so every pass can be ranked.

## Training result: 378 passes inside MT5, September 2026

Search space: stop 40-100, target 70-170, edge floor 0-30, consensus 0.30-0.75,
max positions 1-5.

| Statistic | Value |
|---|---|
| Passes run | **378** |
| **Profitable passes** | **0** |
| Best net | -5.20 |
| Worst net | -6.30 |
| Median net | -5.80 |
| Best trade count | 14 |
| Median trade count | 8 |

Every one of the 378 parameter combinations lost money. The spread of results
is only 1.10 dollars wide, from -5.20 to -6.30.

## What that tight distribution means

The outcome is not driven by parameter choice. If parameters mattered, a
378-point search would produce a wide spread, with some passes winning. It
produced a narrow band centred on -5.80. That is the signature of a **fixed
cost per trade** dominating a signal that carries no directional information.

At 8 trades a month and -5.80, the loss per trade is about 0.72 dollars, which
is 72 points at 0.01 lot. The spread is 26 points, so the average trade also
loses about 46 points of direction. Parameters cannot fix direction.

## Why density stayed low

Median 8 trades per month even with the edge floor at 0. The binding
constraints are structural:

- The decision runs once per M1 bar, so the ceiling is 1,440 entries a day.
- A position blocks the same direction unless pyramiding adds are taken, and
  adds need fresh consensus each bar.
- Most bars produce no consensus because the engines disagree.

Pushing density to thousands a day requires entering on nearly every tick.
That was measured separately: 669,324 entries a month would cost **$174,024**
in spread against a $10 account.

## Verdict for this round

The platform now does what was asked - merged engines, one brain, tick flow,
concurrency, pyramiding, native training. MT5's own optimiser, given 378
tries, found zero profitable configurations. The blocker is unchanged and now
measured from a third independent direction: **no directional information in
the data, against a fixed 26-point cost.**
