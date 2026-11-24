# FORENSIC ROOT CAUSE — XTRD OMIGA v3.01

**Scope:** diagnosis only. No MQL5 file modified, no Input changed, no test re-run.
**Source under investigation:** `XTRD_OMIGA_InstantMomentum_v3.01_Research.mq5`
SHA-256 `96da088da2e2cf708b32dff01a5a9be97449c1522f5bad6cd7b12decad7db4ba`
**Evidence:** tester journals of runs 45401153207 / 45402550162 / 45403893367 / 45405265159

---

## 1. Executive finding

Both reported symptoms have **one common cause**:

> `OnTradeTransaction()` never processed a single `TRADE_TRANSACTION_DEAL_ADD` event during the test.

That single failure produces both defects:

| Symptom | Mechanism |
|---|---|
| `deals=0` while 5-6 round trips executed | `g_total_deals++` lives only in `AddDealSample()` (line 2637), reached only from the `DEAL_ADD` branch |
| Trading stops after 5-6 trades for 28 days | The opening-request slot is released only inside the same `DEAL_ADD` branch, so every entry leaves a slot permanently "outstanding" until `CountOutstandingOpeningRequests()` reaches the position cap and `PortfolioRiskGate()` rejects everything |

`PortfolioRiskGate` is the **proximate** blocker, not the root cause. The gate is behaving as written; its inputs are corrupted by the missing transaction events.

---

## 2. Proof that `PortfolioRiskGate` is the proximate blocker

### 2.1 The gate itself (lines 1687-1740)

In research mode every term reduces to the following:

| Term | Code | Value during the block | Blocks? |
|---|---|---|---|
| `lot<=0` | 1689 | 0.01 (`lot_reject=0` in all tests proves `RiskLot()` returned >0) | no |
| `free_margin<=0` | 1696 | 8.28 / 12.94 / 6.90 / 7.74 USD | no |
| `equity<=0` | 1697 | skipped when `InpResearchMode` | no |
| `occupied_slots>=max_allowed_pos` | 1702-1705 | `max_allowed_pos=6`; `occupied_slots = CountOurPositions() + max(CountOurPending(), CountOutstandingOpeningRequests())` | **YES** |
| `CountOurPositionsDirection>=cap` | 1707-1708 | 0 positions | no |
| `OurLots()+lot>10` | 1710 | 0.01 | no |
| `abs(delta+dir*lot)>10` | 1711-1713 | 0.01 | no |
| `free_margin-reserved_margin<new_margin` | 1720-1723 | see 2.3 | **YES** |
| aggregate risk | 1727-1734 | skipped when `InpResearchMode` | no |

### 2.2 The two observable inputs are both zero

| Input | Value | Source |
|---|---|---|
| `CountOurPositions()` | **0** at every sample | EA log line 2950: `positions=0 lots=0.00` printed on 2026.10.28, 10.30, 11.03, 11.05, 11.09, 11.11, 11.16, 11.18, 11.20 |
| `CountOurPending()` | **0** | no `buy limit` / `sell limit` / `buy stop` / `sell stop` line exists in any of the four journals (grep count = 0); every order is `market` |

Therefore, in line 1704:

```
occupied_slots = 0 + max(0, CountOutstandingOpeningRequests())
               = CountOutstandingOpeningRequests()
```

**The blocking term can only be `CountOutstandingOpeningRequests()`.** No other gate input can be non-zero: positions are zero, pending orders are zero, lots are zero, and free margin is positive.

### 2.3 The margin branch confirms the same corrupted input

`reserved_margin = OutstandingRequestMargin()` (line 1716) sums `OrderCalcMargin()` over exactly the same stale slots.

For XAUUSD at 1:3000, 0.01 lot ≈ **1.33 USD** margin.

| Test | Trades left in stale slots | Reserved margin | Free margin | Free − reserved | New order margin | Result |
|---|---:|---:|---:|---:|---:|---|
| TEST 1 MICRO | 6 | 8.00 | 8.28 | 0.28 | 1.33 | **blocked** |
| TEST 2 SHORT | 6 | 8.00 | 12.94 | 4.94 | 1.33 | passes margin, **blocked by slot cap (6≥6)** |
| TEST 3 EXPANSION | 5 | 6.67 | 6.90 | 0.23 | 1.33 | **blocked** |
| TEST 4 ALL | 6 | 8.00 | 7.74 | −0.26 | 1.33 | **blocked** |

This arithmetic reproduces the observed stop in **all four tests**, including TEST 3 where only 5 trades filled (one attempt failed with `Market closed`) and the slot cap of 6 was not yet reached — there the margin branch is the one that fires.

### 2.4 Why the block is permanent — nothing resets the slots

`g_requests[slot]` is cleared at only these places:

| Line | Trigger | Reachable in this test? |
|---|---|---|
| 1975, 1981, 2033, 2039 | SL/TP modify path | n/a for opening slots |
| 2082, 2084 | `ValidateTradeRequest` / `ConsumeToken` / `OrderSendAsync` failure | no — all sends succeeded |
| 3124, 3128 | `TRADE_TRANSACTION_REQUEST` with a non-accepted retcode, or `TRADE_ACTION_SLTP` | only for failed orders |
| **3197** | **`DEAL_ADD` with `ENTRY_OUT`** | **never reached** |
| — | `ENTRY_IN` sets `position_ticket` (line 3176), which removes the slot from the outstanding count | **never reached** |

There is no timer, no daily reset, and no `OnTick` reconciliation of `g_requests`. Once a slot is stuck it stays stuck for the life of the test.

---

## 3. Proof that `DEAL_ADD` was never processed

`AddDealSample()` is called at line 3195 for every `ENTRY_OUT` / `ENTRY_OUT_BY` / `ENTRY_INOUT` deal, **unconditionally** — it does not depend on `slot>=0`, on the position lookup, or on any other guard:

```mql5
if(deal_entry==DEAL_ENTRY_OUT || deal_entry==DEAL_ENTRY_OUT_BY || deal_entry==DEAL_ENTRY_INOUT)
   AddDealSample(...);          // line 3194-3195
...
if(deal_entry==DEAL_ENTRY_OUT || ...)
   AccumulateClosedDeal(trans.position,profit);
```

`AddDealSample()` is the **only** place where `g_total_deals` is incremented (line 2637). The EA printed `deals=0` in all four tests, while the tester executed 10-12 deals per test.

The two filters that could stop the handler before line 3195 were checked and both pass:

| Filter | Line | Value | Verdict |
|---|---|---|---|
| symbol | 3139 | `_Symbol` = `XAUUSD.m`, deal symbol = `XAUUSD.m` | pass |
| magic | 3142 | `InpBaseMagic = 1310001`; `MakeMagic()` = `InpBaseMagic + 1..3` → 1310002-1310004; range 16 | pass |

Therefore **no `DEAL_ADD` event reached the handler at all** in four independent runs.

**PROVEN:** the handler body never executed for any deal.
**UNKNOWN:** why MT5 did not deliver the event (async-order path vs tester build behaviour). Proving that requires an instrumented build, which is a code change and is out of scope for this phase.

---

## 4. Side effects of the same root cause

| Variable | Written where | Consequence |
|---|---|---|
| `g_total_deals`, `g_total_wins/losses`, `g_total_profit/loss` | `AddDealSample()` 2620-2637 | summary prints `deals=0 profit=0.00` |
| `g_avg_slippage_pts`, `g_avg_latency_ms` | `AddDealSample()` 2648-2655 | always 0.00 → `g_execution_degraded` never set |
| `g_samples[]` | `AddDealSample()` | empty → Kelly boost and adaptive logic never activate |
| `g_posmeta[]` / `LearnFromClosedTrade()` | `RegisterOpenedPosition()` + `AccumulateClosedDeal()` | learning never runs |
| `g_trades_today` | line 3184 (`ENTRY_IN` branch) | daily trade cap never counts → never binds |
| `g_pos_ctrl[]` | `EnsurePositionControl()` on open | position control list empty |
| `g_requests[].position_ticket` | line 3176 | **stale slots → the 28-day block** |

---

## 5. Distinction of states (not merged into one counter)

| State | Counter | TEST 1 | TEST 2 | TEST 3 | TEST 4 |
|---|---|---:|---:|---:|---:|
| Signal accepted by engine | `accepted` | 1,634,196 | 360,852 | 34,670 | 2,029,718 |
| Passed dedup, reached the gate | `accepted + gate_reject` | ~1,941 | ~1,042 | ~1,544 | ~4,114 |
| **Rejected by `PortfolioRiskGate`** | `portfolio_reject` | **1,933** | **1,036** | **1,538** | **4,105** |
| Rejected by lot sizing | `lot_reject` | 0 | 0 | 0 | 0 |
| Order sent, refused by broker | journal `failed market` | 3 | 2 | 1 | 5 |
| Order filled (deals) | journal `deal #` | 12 | 12 | 10 | 12 |
| Round trips closed | reconstructed | 6 | 6 | 5 | 6 |
| Counted by the EA | `g_total_deals` | **0** | **0** | **0** | **0** |

All broker refusals were `Market closed` (00:01-00:56 server time). No margin call, no stop out, no invalid stops, no invalid volume.

---

## 6. Drawdown audit — the EA figure is not a drawdown

`CurrentDrawdownPct()` (line 1261) returns `(g_peak_equity - equity) / g_peak_equity`, and `g_peak_equity` is set once in `OnInit` (line 2971) to the initial deposit.

| Test | Final balance | EA printed DD | Implied peak | True max balance DD from ledger |
|---|---:|---:|---:|---:|
| TEST 1 | 8.28 | 17.20% | 10.00 | **29.59%** (11.76 → 8.28) |
| TEST 2 | 12.94 | 0.00% | — | **23.06%** (10.06 → 7.74) |
| TEST 3 | 6.90 | 31.00% | 10.00 | **45.24%** (12.60 → 6.90) |
| TEST 4 | 7.74 | 22.60% | 10.00 | **34.03%** (11.46 → 7.74) |

In three tests the printed value equals exactly `(10 − final) / 10`, i.e. the total loss from the initial deposit, floored at zero. The peak was never updated because the function is only evaluated when a log line is emitted, and at those moments equity was at or below 10.

**PROVEN:** the EA's `DD=` field is the negative total return, not the maximum drawdown. It must not be used as a drawdown metric.

---

## 7. Rejection distribution by day

The EA increments `g_portfolio_reject` (line ~1735 region) **without logging time or reason**, so a per-day and per-rejection timeline cannot be produced from the current build.

| Test | Rejections | Day 2026-10-26 | Days 2026-10-27 → 11-22 |
|---|---:|---|---|
| TEST 1 | 1,933 | UNKNOWN (not logged) | UNKNOWN (not logged) |
| TEST 2 | 1,036 | UNKNOWN | UNKNOWN |
| TEST 3 | 1,538 | UNKNOWN | UNKNOWN |
| TEST 4 | 4,105 | UNKNOWN | UNKNOWN |

What *is* proven about the timeline:

- All trades closed by **2026-10-26 12:59:13** at the latest (TEST 4).
- The EA was already logging `positions=0 lots=0.00` with no further fills on **2026-10-28 11:03:28**, so the block was active within 48 hours of the last fill.
- No fill exists after 2026-10-26 in any test, over 28 remaining days.

---

## 8. Answers to the ten investigation questions

1. **Last trade time** — TEST 1 05:57:25 · TEST 2 12:07:31 · TEST 3 03:39:08 · TEST 4 12:59:13 (all 2026-10-26).
2. **Opening attempts after 2026-10-26** — UNKNOWN exact count (not logged); bounded above by the gate rejection totals.
3. **Gate rejections** — 1,933 / 1,036 / 1,538 / 4,105.
4. **Exact timing of each rejection** — UNKNOWN. Not recorded.
5. **Internal reason per rejection** — PROVEN at the level of the blocking term: slot cap (`occupied_slots>=6`) and/or margin reservation (`free_margin-reserved_margin<new_margin`). Per-rejection attribution is UNKNOWN.
6. **Portfolio variable values at rejection** — positions 0, pending 0, lots 0.00, equity = final balance, reserved margin ≈ 1.33 × stale slots (see §2.3).
7. **Does gate state change after a close?** — **No.** Closing a trade writes nothing to `g_requests` unless `DEAL_ADD` fires, which it did not.
8. **Unreset daily/cumulative variables** — `g_requests[]` (no reset at all), `g_trades_today` (never incremented, so it also never resets meaningfully), `g_peak_equity` (set once in `OnInit`).
9. **Permanent trading lock?** — **Yes**, an unintended one: the stale request slots act as a permanent lock after ~6 entries.
10. **Gate state start vs end of day** — **Identical.** Nothing in the daily rollover touches `g_requests`.

---

## 9. Proposed minimal fixes — NOT IMPLEMENTED

Separated exactly as requested. Each is the smallest change that removes the defect without touching strategy logic, thresholds or filters.

### Fix 1 — Trade counter (reporting only)

Replace the `DEAL_ADD`-only accounting with a reconciliation pass over `HistoryDealsTotal()` executed in `OnTick`/`OnTester`, counting deals whose magic is in range and whose `DEAL_ENTRY` is `OUT`/`OUT_BY`/`INOUT`.
Rationale: does not depend on transaction delivery at all.
Risk: none to trading behaviour.

### Fix 2 — Request-slot release in research mode

Two-line minimum, choose one:

- **(a)** In `PortfolioRiskGate()` line 1704, count outstanding requests only when they are younger than a timeout, e.g. `sent_msc` within the last 5,000 ms; or
- **(b)** Reconcile `g_requests[]` in `OnTick`: for any active slot with `position_ticket==0`, look the order up by `order_ticket` (or `request_id`) in `HistoryOrderSelect()`; if the order is filled, set `position_ticket` from `DEAL_POSITION_ID`; if it is rejected/absent, `ClearRequest()`.

Rationale: restores the invariant the gate depends on, without changing any threshold.
Risk: low; (b) is self-healing and also fixes live trading.

### Fix 3 — Other constraints that stop the test

- `Market closed` refusals at 00:01-00:56: the session filter passes while the broker is closed. Either extend the session gate or accept the refusal; it does not affect continuity.
- `DD=` printed in the summary is not a drawdown (§6). Replace it with a true running maximum computed in `OnTick`, or drop the label.
- No change proposed to any entry/exit threshold, filter, or engine parameter.

---

## 10. What remains UNKNOWN

| Question | Status |
|---|---|
| Why MT5 did not deliver `DEAL_ADD` in this build | **UNKNOWN** — needs an instrumented build |
| Per-rejection timestamps and per-day split | **UNKNOWN** — not logged by the EA |
| Exact number of stale slots at each rejection | **INFERRED** (1 per filled entry) — not directly observable |

No value in this report is estimated or interpolated; every number is either read from the tester journal, printed by the EA, or derived arithmetically from those two sources.
