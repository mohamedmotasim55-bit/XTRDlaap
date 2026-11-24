# XTRD OMIGA v3.01 — Full Strategy Testing Cycle

**EA** `XTRD_OMIGA_InstantMomentum_v3.01_Research.mq5`
**SHA-256** `96da088da2e2cf708b32dff01a5a9be97449c1522f5bad6cd7b12decad7db4ba` — verified before the run
**Code modified** no · **Thresholds** unchanged · **Filters** unchanged

**Market** XAUUSD.m · M1 · 10 USD · 1:3000 · every tick based on real ticks · 2026.10.24 → 2026.11.23
**Execution** research mode ON, 0.01 lot fixed, signal-only OFF, trading ON · spread 26 pts real · commission 0 · swap 0

---

## 1. Master comparison

| Metric | TEST 1 MICRO | TEST 2 SHORT | TEST 3 EXPANSION | TEST 4 ALL |
|---|---:|---:|---:|---:|
| Total trades | 6 | 6 | 5 | 6 |
| Total deals | 12 | 12 | 10 | 12 |
| Net profit | **-1.72** | **+2.94** | **-3.10** | **-2.26** |
| Gross profit | 2.68 | 6.13 | 4.56 | 2.22 |
| Gross loss | -4.40 | -3.19 | -7.66 | -4.48 |
| Profit factor | 0.61 | **1.92** | 0.60 | 0.50 |
| Win rate | 33.33% | 66.67% | 40.00% | 33.33% |
| Average win | 1.34 | 1.53 | 2.28 | 1.11 |
| Average loss | -1.10 | -1.59 | -2.55 | -1.12 |
| Expected payoff | -0.29 | **+0.49** | -0.62 | -0.38 |
| Max balance DD | 29.59% | 23.06% | 45.24% | 34.03% |
| Max equity DD (EA) | 17.20% | 0.00% | 31.00% | 22.60% |
| Max consecutive wins | 2 | 3 | 1 | 1 |
| Max consecutive losses | 3 | 1 | 2 | 3 |
| Average duration | 0.8 min | 1.7 min | 2.5 min | 2.5 min |
| Spread cost | 1.56 | 1.56 | 1.30 | 1.56 |
| Commission | 0.00 | 0.00 | 0.00 | 0.00 |
| Swap | 0.00 | 0.00 | 0.00 | 0.00 |
| Slippage (avg pts) | 0.00 | 0.00 | 0.00 | 0.00 |
| Final balance | 8.28 | **12.94** | 6.90 | 7.74 |

## 2. Signal counts per engine

| Test | Engine | Signals accepted | Lot reject | Portfolio reject |
|---|---|---:|---:|---:|
| 1 | MICRO_MOM | 1,634,196 | 0 | 1,933 |
| 2 | SHORT_MOM | 360,852 | 0 | 1,036 |
| 3 | EXPANSION | 34,670 | 0 | 1,538 |
| 4 | MICRO_MOM | 1,634,196 | 0 | 1,451 |
| 4 | SHORT_MOM | 360,852 | 0 | 1,446 |
| 4 | EXPANSION | 34,670 | 0 | 1,208 |

`lot_reject = 0` in every test: research mode bypassed balance sizing as designed, and the broker accepted 0.01 lot.

## 3. Findings

### 3.1 Every test stopped trading after the first day

All four tests executed their trades on **2026-10-26 only** (between 01:04 and 12:59), then opened nothing for the
remaining 28 days of the period, despite 1,000-1,900 further signals being rejected by `PortfolioRiskGate`.

Consequence: the 30-day period behaves as a **one-day sample**. Trade counts of 5-6 are not enough to measure edge.

### 3.2 The EA's own summary line is unreliable

`OnDeinit` printed `deals=0 DD=.. profit=0.00` in every test while the tester filled 5-6 round trips.
The internal deal counter is not connected to the tester's trade transactions. All figures in this report come from
the tester journal, not from that line.

### 3.3 Execution quality

| Item | Result |
|---|---|
| Filled orders | 12 / 12 / 10 / 12 |
| Failed orders | 3 / 2 / 1 / 5 — **all "Market closed"** (00:01-00:56 server time) |
| Margin call | none |
| Stop out | none |
| Orders without SL | none — every open deal carried SL and TP |
| Duplicate entries | none — each open deal matched exactly one close |
| Slippage | 0.0 pts average |

### 3.4 Per-engine quality

**MICRO** — 6 trades, 33% win rate, average win 1.34 vs average loss 1.10. Reward is larger than risk per trade
but frequency of wins is too low; 3 consecutive losses at the end. Net negative after 1.56 USD of spread cost.

**SHORT** — 6 trades, 67% win rate, PF 1.92, expected payoff +0.49. The only test with a positive payoff and the
lowest drawdown (23%). Average duration 1.7 min. Still a 6-trade sample on one day.

**EXPANSION** — 5 trades, 40% win rate, PF 0.60, worst drawdown (45%). Average win 2.28 is the largest of the three
but average loss 2.55 exceeds it. It fires 47x fewer signals than MICRO and still produced the largest loss.

**ALL ENGINES** — 6 trades, PF 0.50, worst profit factor of the four. Combining the engines did not diversify; the
combined run lost more than MICRO alone and less than EXPANSION alone.

### 3.5 Answers to the required questions

1. **Best net profit** — SHORT (+2.94).
2. **Best profit factor** — SHORT (1.92).
3. **Best expected payoff** — SHORT (+0.49).
4. **Lowest drawdown** — SHORT (23.06% balance, 0.00% equity by the EA's own measure).
5. **Best trade-count vs cost balance** — SHORT: 6 trades, spread cost 1.56 against 6.13 gross profit (25%).
   MICRO spends the same 1.56 against 2.68 gross (58%). EXPANSION spends 1.30 against 4.56 (29%).
6. **All engines together vs single engines** — **No.** TEST 4 (PF 0.50, -2.26) is worse than TEST 2 alone and
   worse than the average of the three single runs.
7. **Statistical edge** — **Inconclusive for all four.** 5-6 trades on a single day cannot separate edge from noise.
   No out-of-sample or walk-forward validation has been performed, so no engine may be declared profitable.

## 4. Classification

| Engine | Classification | Reason |
|---|---|---|
| MICRO | **Inconclusive** (negative direction) | n=6, one day, PF 0.61 |
| SHORT | **Inconclusive** (positive direction) | n=6, one day, PF 1.92 — needs out-of-sample |
| EXPANSION | **Inconclusive** (negative direction) | n=5, one day, PF 0.60, DD 45% |
| ALL | **Inconclusive** (negative direction) | n=6, one day, PF 0.50 |

## 5. Data integrity

- `report.htm` is **not emitted** by this MT5 build in `/config` mode; the workflow's report collection step
  confirmed its absence. The HTML files in this folder are generated from the Strategy Tester journal
  (`logs_20261124.log`), which records every deal with timestamp and price.
- Validation: the reconstructed net profit reproduces the tester's final balance exactly in all four tests
  (8.28 / 12.94 / 6.90 / 7.74 USD). No figure was estimated or interpolated.
- No test was re-run to obtain a better result; each of the four tests ran once.

## 6. What must happen before any conclusion

1. Fix the post-day-1 entry block (`PortfolioRiskGate` rejecting ~50 signals/day) — otherwise every future test
   measures a single day.
2. Fix the EA's internal deal counter so its summary matches the tester.
3. Re-run the same four tests on a period that is not used for development, then compare.
