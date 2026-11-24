# v3.02 Research Repair — Change Report

**Original preserved:** `XTRD_OMIGA_InstantMomentum_v3.01_Research.mq5` — untouched
**New build:** `XTRD_OMIGA_InstantMomentum_v3.02_Research_Repair.mq5`
**SHA-256:** see `SHA256SUMS.txt`
**Compile:** 0 errors, 1 warning (pre-existing `OrderSendAsync` return check, line 2526)

---

## 1. Strategy protection — verified, not assumed

| Guard | Verification |
|---|---|
| Every `input` line | `diff` of all input declarations: **IDENTICAL** |
| `BuildSignal()` | body hash identical |
| `PassSignalStage()` | body hash identical |
| `RiskLot()` | body hash identical |
| `ComputeSLTP()` (SL/TP) | body hash identical |
| `StrategyDuplicateGate()` | body hash identical |
| Trailing / BE / partial-close parameters | untouched |
| Research lot, test settings | untouched |

Nothing in this build changes an entry rule, an exit rule, a threshold, a filter, or a risk parameter.

---

## 2. Corrected root cause of the v3.01 failure

The forensic phase concluded "the handler never executed" and left the *why* as UNKNOWN.
With instrumentation in place the answer is now measured:

> `OnTradeTransaction()` **was** called — 422 events in TEST 1 — but the `DEAL_ADD` branch returned
> early because it reads deal properties from history **without calling `HistorySelect()` first**.
> `HistoryDealGetString(deal, DEAL_SYMBOL)` therefore returned an empty string, the
> `!= _Symbol` filter rejected the event, and the handler exited before
> linking the position or counting the deal.

Direct evidence from the new diagnostic line:

```
OMEGA2 TT | type=6 deal=2 order=2 position=2 symbol=XAUUSD.m magic=0 entry=0 volume=0.00 price=0.00000
```

`magic=0, entry=0, volume=0.00, price=0.00000` on a live deal event proves the history read returned
nothing. `symbol` is populated only because it comes from `trans.symbol`, not from history.

Consequences in v3.01: `deals=0`, no `position_ticket` link, no slot release, and after the position cap
was reached the portfolio gate blocked every signal for the rest of the test.

---

## 3. Fix 1 — Transaction diagnostics

Added at the top of `OnTradeTransaction()`:

- counters per transaction type (`g_tt_count[]`) and a total (`g_tt_total`)
- first 300 events logged with type, deal, order, position, symbol, magic, entry, volume, price, retcode, request_id
- summary line `OMEGA2 REPAIR | tt_events=… tt_deal_add=…`

Measured: 422 / 267 / 218 / 42 events in the four tests — the callback is alive.

## 4. Fix 2 — Self-reconciliation of request slots

`CountOutstandingOpeningRequests()` and `OutstandingRequestMargin()` no longer trust the slot alone.
For each active, unlinked slot:

1. `HistoryOrderSelect(order_ticket)` → read `ORDER_STATE`
2. `FILLED`/`PARTIAL` → resolve the position via `HistoryDealGetInteger(DEAL_POSITION_ID)`, link it, register meta
3. `CANCELED`/`REJECTED`/`EXPIRED` → release the slot
4. filled but position already closed → release the slot
5. no order and no artifact after 3 ticks → release and log `unresolved`

`ReconcileRequests()` additionally frees a slot as soon as its position disappears.
Occupancy is therefore measured from live broker artifacts, never from stale bookkeeping.
Measured: `unresolved_released = 0` in all four tests, and trades continued for the whole period.

## 5. Fix 3 — Trade statistics from history

`ReconcileTradeStats()` (every 200 ticks) walks `HistoryDealsTotal()`/`HistoryDealGetTicket()`:

- deduplicated by deal ticket (`g_stats_last_ticket`)
- `deals_all` counts every deal, `closed_deals` counts `OUT/OUT_BY/INOUT`, `closed_trades` counts fully closed positions
- counters `g_total_deals / wins / losses / profit / loss` are written **only here**, so the event path can never double count
- `AccumulateClosedDeal()` is fed from history, restoring learning and execution statistics

## 6. Fix 4 — Portfolio gate diagnostics

Every rejection now logs: time, engine, reason code, positions, pending, in-flight, free margin,
reserved margin, required margin, equity.

- journal: first 200 rejections (`OMEGA2 GATE | …`)
- CSV: `X13_PortfolioGate_Rejections.csv` (Common/Files, up to 50,000 rows)
- summary: per-reason totals (`OMEGA2 GATE REASON | …`)

Gate **conditions were not changed**. Only the occupancy input was corrected (Fix 2).

## 7. Fix 5 — Drawdown

New tracker sampled every 20 ticks, separate from the strategy's own `CurrentDrawdownPct()`:

| Metric | Meaning |
|---|---|
| `balance_max` | maximum drawdown of balance from its running peak |
| `equity_max` | maximum drawdown of equity from its running peak |
| `balance_now` / `equity_now` | current drawdown from peak |
| `peak_balance` / `peak_equity` | the tracked peaks |

The legacy `CurrentDrawdownPct()` is **deliberately unchanged**: it feeds the strategy's drawdown
kill switch, and altering it would change entry behaviour. Its old value is still printed for comparison.

---

## 8. Acceptance criteria

| # | Criterion | Result | Evidence |
|---|---|---|---|
| 1 | Compile without errors | **PASS** | `compile_v3.02.log` — 0 errors, 1 pre-existing warning |
| 2 | Trade events appear in the log | **PASS** | 422/267/218/42 `OMEGA2 TT` events |
| 3 | Slot released after the order cycle | **PASS** | `unresolved_released=0`; `OMEGA2 RECON` release lines; 60/38/31/6 trades |
| 4 | No double counting | **PASS** | `closed_deals == closed_trades == ea_total_deals`; `deals_all == 2 × closed` |
| 5 | EA counters match the execution log | **PASS** | journal deals 120/76/62/12 = EA 120/76/62/12; trades 60/38/31/6 |
| 6 | Entries continue after closes | **PASS** | 60, 38, 31, 6 round trips across the period |
| 7 | Test covers the whole period | **PASS** | 2026.10.24 → 2026.11.22, 10,755,156 ticks |
| 8 | No strategy parameter changed | **PASS** | inputs identical, strategy bodies identical |

**All eight criteria pass.**

---

## 9. What the repair reveals

With the bookkeeping fixed, the engines trade for the full period instead of stopping after day one.
The measured outcome is strongly negative on this account size:

| Test | v3.01 trades | v3.01 net | v3.02 trades | v3.02 net | v3.02 final |
|---|---:|---:|---:|---:|---:|
| MICRO | 6 | -1.72 | 60 | -9.73 | 0.27 |
| SHORT | 6 | +2.94 | 38 | -9.02 | 0.98 |
| EXPANSION | 5 | -3.10 | 31 | -10.19 | -0.19 |
| ALL | 6 | -2.26 | 6 | -8.98 | 1.02 |

The v3.01 numbers were produced by a system that stopped trading after ~6 entries; they were not a
measurement of the strategy. v3.02 measures it, and the result is a near-total loss of a 10 USD
account in every configuration.

No strategy optimisation was performed and none is proposed here — that is a separate phase.

## 10. Residual limitation

The `DEAL_ADD` branch still returns early on its history read (the same missing `HistorySelect`).
It is left as-is on purpose: the reconciliation layer is now the single source of truth, and making
the event path also write statistics would double count unless every writer is guarded. The event
path remains diagnostic only. This is documented, not hidden.
