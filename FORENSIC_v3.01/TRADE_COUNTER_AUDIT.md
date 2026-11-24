# TRADE COUNTER AUDIT — XTRD OMIGA v3.01

**Scope:** read-only. No source file modified.
**File:** `XTRD_OMIGA_InstantMomentum_v3.01_Research.mq5` (SHA-256 `96da088d…4ba`)

---

## 1. Where every trade counter is written

| Counter | Written at | Trigger | Counts |
|---|---|---|---|
| `g_total_deals` | line **2637** inside `AddDealSample()` | `OnTradeTransaction` → `TRADE_TRANSACTION_DEAL_ADD` → `DEAL_ENTRY_OUT/OUT_BY/INOUT` | **closed round trips only**, never opens |
| `g_total_wins` | line 2632 | same | profitable closes |
| `g_total_losses` | line 2636 | same | losing closes |
| `g_total_profit` / `g_total_loss` | 2633 / 2637 region | same | realized money |
| `g_trades_today` | line **3184** | `DEAL_ADD` → `DEAL_ENTRY_IN` | opens, used by the daily cap |
| `g_samples[]` | 2616-2624 | `AddDealSample()` | slippage / latency / profit samples |
| `g_posmeta[]` | `RegisterOpenedPosition()` (line 3181 call) | `DEAL_ADD` → `ENTRY_IN` | per-position realized P/L for learning |

## 2. Where open and close are detected

The EA has **exactly one** detection path for both events: `OnTradeTransaction()` (line 3087).

| Event | Code location | Action |
|---|---|---|
| Order accepted | 3093-3132 (`TRADE_TRANSACTION_REQUEST`) | sets `order_ticket`, clears the slot only if the request was rejected or was an SL/TP modify |
| **Open** | 3173-3185 (`DEAL_ADD` + `ENTRY_IN`) | `g_requests[slot].position_ticket = trans.position`, `RegisterOpenedPosition()`, `g_trades_today++` |
| **Close** | 3186-3197 (`DEAL_ADD` + `ENTRY_OUT/OUT_BY/INOUT`) | `AddDealSample()`, `AccumulateClosedDeal()`, `ClearRequest(slot)` |
| Partial close | 3187-3190 | `AccumulateClosedDeal()` returns early while `PositionSelectByTicket()` still succeeds, so a partial exit does not zero the meta record. **Correct.** |

There is **no** `OnTrade()` handler, no `HistoryDealsTotal()` reconciliation, and no `PositionsTotal()` delta accounting. If `DEAL_ADD` is not delivered, the EA is blind to every fill.

## 3. Root cause of `deals=0`

**PROVEN.** `g_total_deals` is incremented only at line 2637, which is reached only from the `DEAL_ADD` branch at line 3194. That branch is **unconditional** for closing deals — it does not require `slot>=0`, a successful position lookup, or any other guard.

Observed:

| Test | Deals in journal | `g_total_deals` printed | `g_total_profit+g_total_loss` |
|---|---:|---:|---:|
| TEST 1 | 12 | 0 | 0.00 |
| TEST 2 | 12 | 0 | 0.00 |
| TEST 3 | 10 | 0 | 0.00 |
| TEST 4 | 12 | 0 | 0.00 |

If the handler had run and reached line 3194 even once, the counter would be ≥ 1. It is 0 in four independent runs.

The only early exits before line 3194 are:

| Line | Condition | Actual value | Passes? |
|---|---|---|---|
| 3135 | `trans.type != TRADE_TRANSACTION_DEAL_ADD` | would be `DEAL_ADD` | — |
| 3137 | `trans.deal == 0` | deals 2..13 | passes |
| 3139 | deal symbol != `_Symbol` | both `XAUUSD.m` | passes |
| 3142 | magic outside `[1310001, 1310017]` | 1310002-1310004 | passes |

**Conclusion:** the function body never executed for any deal. The counter is not "miscalculating"; it is never reached.

**UNKNOWN:** why the terminal did not deliver the event. Establishing that requires instrumented logging (a code change), which this phase forbids.

## 4. Consequences beyond the counter

| Behaviour | Status because of this |
|---|---|
| Kelly / adaptive lot boost (`InpUseFractionalKellyBoost`) | never activates — `g_total_deals < InpStatsWarmupDeals` forever |
| Execution degradation flag (`g_execution_degraded`) | never set — `g_avg_slippage_pts` and `g_avg_latency_ms` stay 0.00 |
| Learning / `LearnFromClosedTrade()` | never runs — `g_posmeta[]` is never populated |
| Daily trade cap (`InpMaxTradesPerDay`) | never binds — `g_trades_today` stays 0 |
| Position control (`g_pos_ctrl[]`) | never populated on open, so `close_pending` and SL/TP throttling never apply |
| **Request-slot release** | **never happens → permanent gate block (§2.4 of the root cause report)** |
| Telemetry CSV (`QueueTelemetry`) | no `DEAL` rows written |

## 5. Report-integrity cross-check

| Source | TEST 1 | TEST 2 | TEST 3 | TEST 4 | Consistent? |
|---|---:|---:|---:|---:|---|
| Journal `order performed` | 12 | 12 | 10 | 12 | yes |
| Journal `deal #` | 12 | 12 | 10 | 12 | yes |
| Journal `failed market` | 3 | 2 | 1 | 5 | yes |
| Reconstructed round trips | 6 | 6 | 5 | 6 | yes (2 deals each) |
| Tester `final balance` | 8.28 | 12.94 | 6.90 | 7.74 | — |
| Reconstructed net P/L | -1.72 | +2.94 | -3.10 | -2.26 | **matches exactly** |
| EA `g_total_deals` | 0 | 0 | 0 | 0 | **NO** |
| EA `profit=` | 0.00 | 0.00 | 0.00 | 0.00 | **NO** |
| EA `avg_slip=` | 0.00 | 0.00 | 0.00 | 0.00 | unverifiable (no fill samples) |

The tester balance and the reconstructed ledger agree to the cent, so the trades are real and the accounting model used for the reconstruction is correct. Only the EA's own counters disagree, and they disagree because they were never written.

## 6. Missing data the audit could not obtain

| Required by the audit brief | Available? |
|---|---|
| Position ID per trade | Only in the journal (`deal #N`, no position id printed) — the EA never recorded one |
| Deal ticket | journal yes, EA no |
| Realized profit per trade | reconstructed from prices; the EA never recorded it |
| Partial closes | none occurred in these tests |
| Counted closed trades | journal 6/6/5/6 vs EA 0/0/0/0 |

## 7. Minimal fix proposal — NOT IMPLEMENTED

Replace the event-only accounting with a reconciliation pass, keeping `OnTradeTransaction` for latency/slippage telemetry:

```
OnTick (throttled) / OnTester:
  for i in 0..HistoryDealsTotal()-1:
     deal = HistoryDealGetTicket(i)
     if deal magic in range and DEAL_ENTRY in {OUT, OUT_BY, INOUT}
        and deal not already counted (keep last counted deal ticket)
        -> g_total_deals++, accumulate profit/wins/losses
```

Why this is the smallest safe change:

- It removes the dependency on event delivery entirely.
- It does not touch entries, exits, thresholds, or filters.
- It is idempotent (guarded by the last counted ticket), so it is safe with partial closes.
- It also gives the audit the deal ticket and position id it currently lacks.

Same fix addresses the slot-release defect if paired with §9-Fix 2(b) of the root cause report.
