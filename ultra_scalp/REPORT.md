# XAUUSD ULTRA SCALPING — autonomous discovery report

Data: 30,796,521 ticks (bid/ask), JustMarkets XAUUSD, spread **constant 26 points** (p1 = p99 = 26).

* dev = 2026.08.25–09.23 + 2026.09.24–10.23 (18.1M ticks)
* out-of-sample = 2026.10.26–11.20 (10.8M ticks, never used for tuning)

Costs: 26-point spread on every round trip, 2-point slippage on stop exits.
No lookahead: every entry uses only data up to that second.

---

## 1. Market microstructure — the decisive measurement

| lag | 1 s | 2 s | 5 s | 10 s | 30 s | 60 s |
|---|---:|---:|---:|---:|---:|---:|
| autocorrelation of mid returns | +0.038 | +0.002 | +0.004 | +0.004 | +0.001 | 0.000 |

| condition | n | E[next 1 s] | E[next 5 s] |
|---|---:|---:|---:|
| \|move\| ≥ 10 pts in 1 s | 637,511 | −0.0 | −0.1 |
| \|move\| ≥ 40 pts in 1 s | 96,279 | −0.1 | −0.7 |
| \|move\| ≥ 80 pts in 1 s | 17,107 | −0.4 | −3.5 |

| condition | n | E[reversion over 10 s] |
|---|---:|---:|
| \|move\| ≥ 30 pts in 5 s | 631,848 | −0.9 |
| \|move\| ≥ 120 pts in 5 s | 48,429 | −3.3 |
| \|move\| ≥ 250 pts in 5 s | 4,746 | −2.6 |

At sub-minute horizons the mid is a martingale. The best conditional edge is 3.5 points
against a 26-point cost.

---

## 2. Full strategy grid — 54 configurations, all negative

Three signal families (spike fade, spike momentum, 60 s range breakout), targets 30/50/80,
stops 30/50/80, time limits 60/180 s, both directions, dev months.

* every one of the 54 configurations lost money
* best: fade, T = 80, S = 30, H = 60 s → **−13.5 points per trade**

## 3. Best configuration, fully simulated on all three months

| month | trades | wins | losses | WR | net pts | wins/day | avg duration | avg win | avg loss |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 2026.08.25–09.23 | 3,185 | 530 | 2,655 | 16.6% | −43,607 | 24.1 | 7 s | +77.9 | −32.0 |
| 2026.09.24–10.23 | 2,430 | 416 | 2,014 | 17.1% | −32,357 | 18.9 | 7 s | +76.9 | −32.0 |
| 2026.10.26–11.20 (OOS) | 2,609 | 412 | 2,197 | 15.8% | −38,017 | 20.6 | 7 s | +78.1 | −31.9 |
| **total** | **8,224** | **1,358** | **6,866** | **16.5%** | **−113,981** | | **7 s** | +78.2 | −32.0 |

* Profit factor **0.481**, max drawdown **−113,949 pts**, t-stat **−30.7**
* per-trade edge by month: **−13.69 / −13.32 / −14.57** — a structural constant, not noise
* break-even win rate needed: 32 / (80 + 32) = **28.6%**; achieved **16.5%**

### Exit breakdown

| exit | trades | net pts | avg |
|---|---:|---:|---:|
| stop | 6,852 | −219,264 | −32.0 |
| take profit | 1,284 | +102,720 | +80.0 |
| time | 88 | +2,563 | +29.1 |

---

## 4. Wrong-direction analysis

* 6,866 losing trades → only **1,309 (19.1%)** would have won with the opposite direction
* 1,358 winning trades → **100%** would have lost if flipped

Flipping the direction is worse than keeping it. The signal has a little information,
but 19% against the 28.6% needed leaves a 9.5-point deficit that no exit rule can close.

---

## 5. Missed opportunities (oracle ceiling, not executable)

Zigzag on the 1-second mid, minimum leg 106 points (80 target + 26 cost):

| month | perfect scalps | avg size | median duration |
|---|---:|---:|---:|
| 2026.08.25–09.23 | 34,156 | 237 pts | 28 s |
| 2026.09.24–10.23 | 26,725 | 219 pts | 37 s |
| 2026.10.26–11.20 | 30,670 | 227 pts | 28 s |
| **total** | **91,551** | 227 pts | 28 s |

Total if every leg were captured: **20,909,184 points** (= 209,092 USC at 0.01 lots).

The system captured **1,358 winners = 1.48%** of them, and paid for 6,866 losers.
File: `missed_opportunities.csv` (91,551 rows with entry/exit time, price, direction, size).

---

## 6. Lot size table — 1,000-cent account (1 oz per lot, 1 pt = 1 USC per lot)

| lots | margin USC | loss at SL (32 pts) | % of 1,000 | 3 losses | net over 3 months |
|---:|---:|---:|---:|---:|---:|
| 0.01 | 1.17 | 0.32 | 0.03% | 0.96 | −1,140 USC |
| 0.02 | 2.33 | 0.64 | 0.06% | 1.92 | −2,280 |
| 0.03 | 3.50 | 0.96 | 0.10% | 2.88 | −3,419 |
| 0.04 | 4.67 | 1.28 | 0.13% | 3.84 | −4,559 |
| 0.05 | 5.83 | 1.60 | 0.16% | 4.80 | −5,699 |
| 0.06 | 7.00 | 1.92 | 0.19% | 5.76 | −6,839 |
| 0.07 | 8.17 | 2.24 | 0.22% | 6.72 | −7,979 |
| 0.08 | 9.33 | 2.56 | 0.26% | 7.68 | −9,118 |
| 0.09 | 10.50 | 2.88 | 0.29% | 8.64 | −10,258 |

Every lot size is margin-feasible on a cent account, and every lot size loses money.
At 0.01 lots the account is wiped (−114% of 1,000) before the third month ends.

### Same table on a standard 10 USD account (100 oz per lot)

| lots | margin USD | loss at SL | % of 10 USD | feasible |
|---:|---:|---:|---:|---|
| 0.01 | 1.17 | 0.32 | 3.2% | yes |
| 0.03 | 3.50 | 0.96 | 9.6% | yes |
| 0.05 | 5.83 | 1.60 | 16.0% | yes |
| 0.07 | 8.17 | 2.24 | 22.4% | marginal |
| 0.09 | 10.50 | 2.88 | 28.8% | **no — margin exceeds balance** |

---

## 7. Multiple concurrent positions

The per-trade edge is constant (−13.3 to −14.6 points across three independent months), so
P&L is strictly linear in trade count. Opening N positions in parallel multiplies the loss
rate by N. Concurrency cannot create profit from a negative edge; it only accelerates it.
Occupancy of the tested system is below 1% of the time (7-second average hold), so raising
concurrency from 1 to 5 multiplies the monthly loss from −13.9 to roughly −69 points per
signal, with the same negative expectancy.

---

## 8. Verdict

Ultra-fast scalping on XAUUSD at a 26-point spread is arithmetically impossible with this
cost structure:

* the entire conditional edge available at 1–60 s is **3.5 points**;
* the round-trip cost is **26 points**;
* therefore any sub-minute strategy pays 26 to capture 3.5 — a 7.4× deficit.

The only structure that showed a positive result in this data is multi-hour trend capture
(35-minute average hold, +68,110 points over 3 months, 73% of it from 10 trades), which is
not scalping and which fails in a non-trending month.
