# V2_0_2_FEATURE_DEFINITIONS

Every feature is computed **at or before the trigger tick**. No window ends after
the trigger. `t` is always the trigger `time_msc`.

## Notation

| Symbol | Meaning |
|---|---|
| `P` | `SYMBOL_POINT` (0.01 for XAUUSD.m) |
| `mid` | `(bid+ask)/2` |
| `spread_pts` | `(ask-bid)/P` |
| `sigma60` | stdev of tick-to-tick `mid` changes (points) over `[t-60s, t-1ms]`, refreshed once per minute |
| `sigma300` | same over `[t-300s, t-1ms]`, refreshed once per minute |
| `medspread60` | median `spread_pts` over `[t-60s, t-1ms]`, refreshed once per minute |
| `rate60` | ticks per second over `[t-60s, t-1ms]` |
| `path(a,b)` | `sum |mid[i]-mid[i-1]|` over the window, in points |
| `eff(a,b)` | `|mid[b]-mid[a]| / path(a,b)` |
| `ref[]` | ring of the last 60 `sigma300` samples (one per minute) |

The reference ring is pushed **before** the detectors run for the current tick,
so a signal at `t` can only see samples whose window ended at or before `t`.

---

## Signal columns

| Column | Definition | Notes |
|---|---|---|
| `signal_id` | sequential counter | per run |
| `wave_id` | **always `NA`** | causal wave model not implemented; no placeholder number is written |
| `hypothesis_type` | `H1_IMP_PB`, `H2_VOL_EXP`, `H3_SWEEP`, `RND_BASE` | |
| `direction` | `+1` long, `-1` short | |
| `signal_time_msc` | trigger tick time | |
| `trigger_tick_seq` | tick sequence of the trigger | joins to `Market_Ticks.csv` |
| `server_utc_offset_sec` | `TimeTradeServer() - TimeGMT()` at init | |
| `entry_bid` / `entry_ask` | quote at the trigger tick | |
| `entry_spread_pts` | `(ask-bid)/P` at the trigger | |
| `raw_move_pts` | size of the move that produced the signal, in points | H1: impulse displacement; H2: breakout distance; H3: sweep penetration; RND: `0` |
| `raw_move_window_ms` | elapsed ms from the move origin tick to the trigger tick | measured, never assumed |
| `raw_move_source` | `IMPULSE`, `BREAKOUT`, `SWEEP`, `NA` | |
| `raw_velocity_pts_s` | `raw_move_pts / (raw_move_window_ms/1000)` | **`NA`** for control samples |
| `raw_efficiency` | `eff` over the move window | |
| `raw_realized_vol_pts` | `sigma60` (H1/H3) or `sigma300` (H2) | the reference used by that hypothesis |
| `raw_vol_percentile` | `RefPercentile(sigma300)` | `INSUFFICIENT_HISTORY` when `ref_n < 20` |
| `raw_vol_ref_samples` | number of samples in the ring at the trigger | |
| `raw_quote_rate_s` | ticks per second over the relevant window | |
| `structural_sl_price` | stop level from the structural definition | |
| `structural_sl_pts` | distance from entry to that stop, in points | |
| `spread_is_static` | `1` when the spread stdev over the last ~600 ticks is `0` | |
| `collector_version` | `2.0.2` | |
| `feature_version` | `2.0.2` | |
| `data_quality_flag` | `OK`, `REF_INSUFFICIENT`, `VELOCITY_NA_CONTROL` | |

---

## H1 — Momentum continuation after pullback

```
iA, iB   = argmin/argmax of mid in [t-20s, t-5s]
           up  : iA = argmin, iB = argmax   (impulse goes up)
           down: iA = argmax, iB = argmin
disp     = |mid[iB] - mid[iA]| / P
dur      = (t[iB] - t[iA]) / 1000
```

| # | Condition | Threshold |
|---|---|---|
| 1 | history | >= 10 ticks in `[t-60s, t]` |
| 2 | impulse duration | `5 s <= dur <= 20 s` |
| 3 | displacement | `disp >= max(2 x medspread60, 1.8 x sigma60)` |
| 4 | efficiency | `eff(iA,iB) >= 0.60` |
| 5 | pullback ratio | `0.25 <= pb/disp <= 0.55`, `pb = |mid[iB]-mid[iPull]|/P` |
| 6 | pullback duration | `(t - t[iB])/1000 <= 45 s` |
| 7 | volatility decay | `sigma(iB,iPull) < sigma(iA,iB)` |
| 8 | trigger | up: `mid[t] > high[mid in [t-3s, t-1 tick]]` |
| 9 | spread gate | `spread_pts <= 1.2 x medspread60` |
| 10 | stop | up: `mid[iPull] - 0.25 x sigma60 x P` |

`raw_move_pts = disp`, `raw_move_window_ms = t[iB]-t[iA]`.

---

## H2 — Volatility compression then expansion

| # | Condition | Threshold |
|---|---|---|
| 1 | reference maturity | `ref_n >= 20` |
| 2 | compression | `RefPercentile(sigma300) <= 25` |
| 3 | box | `hi/lo` over `[t-300s, t-1s]`, `hi > lo` |
| 4 | breakout | `mid[t] > hi + 0.35 x spread` or `mid[t] < lo - 0.35 x spread` |
| 5 | quote-rate expansion | `rate(last 3 s) >= 2 x rate(box)` |
| 6 | efficiency | `eff(last 3 s) >= 0.70` |
| 7 | stop | box mid, or the opposite edge when `box_width < 2 x spread` |

`raw_move_pts = distance beyond the box edge`, `raw_move_window_ms = 3000` (the
efficiency window).

---

## H3 — Failed breakout / liquidity sweep

| # | Condition | Threshold |
|---|---|---|
| 1 | history | >= 20 ticks in `[t-900s, t-10s]` |
| 2 | sweep present | `high[sweep] > hi` or `low[sweep] < lo`, sweep window `<= 15 s` |
| 3 | penetration | `0.20 x spread <= pen <= 1.5 x sigma60` |
| 4 | stall score | `>= 0.50`, which is equivalent to `eff/0.30 + rate_stall/rate60 <= 1` |
| 5 | stall efficiency | `eff(sweep extreme -> t) < 0.30` |
| 6 | reclaim | `mid[t] < hi - 0.15 x spread` (up sweep) |
| 7 | micro-BOS | `mid[t] < low[mid in [t-3s, t-1 tick]]` (up sweep) |
| 8 | stop | sweep extreme `+ 1.0 x spread` |

```
StallScore = w * (1 - min(1, eff_stall / 0.30))
           + (1 - w) * (1 - min(1, rate_stall / max(0.01, rate60)))     w = InpH3StallEffWeight (default 0.50)
rate_stall = ticks between the sweep extreme and the reclaim tick / elapsed seconds
```

**Passing `eff_stall < 0.30` and `rate_stall < rate60` is necessary but NOT
sufficient.** With `w = 0.50` the gate `StallScore >= 0.50` reduces to

```
eff_stall / 0.30 + rate_stall / rate60 <= 1
```

so the two normalised terms must sum to one or less. A candidate can satisfy
both sub-gates and still score below 0.50 (e.g. 0.253333/0.30 = 0.844 plus
2.893/3.593 = 0.805 sums to 1.65). See `V2_0_2_H3_STALL_AUDIT.md` for the
per-case arithmetic of every rejection in the audited run.

`raw_move_pts = pen`, `raw_move_window_ms = t - t[sweep extreme]`.

---

## RND — control sample

- Seeded PRNG: `MathSrand(InpRandomSeed)`; the seed is logged and stored in
  `Run_Summary.csv`.
- One sample per `InpRandomEverySeconds` (60 s), only after `ref_n >= 20` so the
  control shares the signal conditions.
- `direction = (MathRand() % 2 == 0) ? +1 : -1`.
- `raw_move_pts = 0`, `raw_move_source = NA`, `raw_velocity_pts_s = NA`,
  `data_quality_flag = VELOCITY_NA_CONTROL`.
- Written to a separate file `RND_Baseline.csv`.

---

## Data-quality flags

| Flag | Meaning |
|---|---|
| `OK` | every input to the row was available |
| `REF_INSUFFICIENT` | `RefPercentile` returned -1 because `ref_n < 20` |
| `VELOCITY_NA_CONTROL` | control sample; velocity is undefined by construction |

## Counters (`Run_Summary.csv`)

`ticks_received`, `ticks_written`, `ticks_rejected_bad_quote`,
`ticks_out_of_order`, `ticks_equal_timestamp`, `ticks_trimmed_from_ram`,
`signals_emitted`, `signals_dropped_no_stop`, `ref_samples`,
`sigma60_last`, `sigma300_last`, `median_spread60_last`, `utc_offset_sec`.
