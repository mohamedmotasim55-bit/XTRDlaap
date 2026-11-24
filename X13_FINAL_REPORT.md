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
