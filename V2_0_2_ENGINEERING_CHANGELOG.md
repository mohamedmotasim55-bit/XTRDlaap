# V2_0_2_ENGINEERING_CHANGELOG

Scope: engineering review and correction of `XTRD_OMIGA_EDGE_LAB_v2_0_1.mq5`.
No trading logic was added. The program remains a research-only collector.

Sources of truth used: `XTRD_OMIGA_EDGE_LAB_v2_0_1.mq5`,
`XTRD_XAUUSD.m_Market_Ticks.csv` (2,078,308 rows),
`XTRD_XAUUSD.m_Signal_Snapshot.csv` (7,090 rows), `backtest-EDGE_LAB_V201B.zip`.

---

## 1. Root cause analysis of the observed defects

### RC-1 `raw_velocity_pts_s` was zero in 7,084 of 7,090 rows

| Caller | v2.0.1 code | Effect |
|---|---|---|
| `DetectH3` | `EmitSignal(..., move, 0, eff, ...)` | literal `0` passed as velocity |
| `DetectRandom` | `EmitSignal("RND_BASE",dir,r,0,0,0,vol,qr,sl)` | move, velocity and efficiency all literal `0` |
| `DetectH1` | `impUp/15.0` | fixed 15 s divisor, not the measured impulse duration |
| `DetectH2` | `(r.mid-hi)/point/3.0` | fixed 3 s divisor |

Root cause: velocity was a formatting constant for two detectors and a
fixed-duration approximation for the other two. The elapsed time of the actual
move was never measured, and the move window was never recorded.

Fix: every detector now measures `raw_move_window_ms` from the tick where the
move started to the trigger tick, and `raw_velocity_pts_s = move_pts / (window_ms/1000)`.
A control sample has no move, so it writes `NA` plus
`data_quality_flag=VELOCITY_NA_CONTROL`. Zero is never written as a substitute
for "not applicable".

### RC-2 `raw_vol_percentile` was `NA` in 100% of rows

`EmitSignal` contained the literal string `"NA"` in that column. No percentile
was ever computed anywhere in v2.0.1.

Fix: a causal reference distribution is built from `sigma300` samples taken once
per minute (`InpRefSampleSeconds=60`, ring of `InpRefCapacity=60` samples).
`RefPercentile()` returns the share of reference samples <= the current value.
Below `InpRefMinSamples=20` samples the field is written as
`INSUFFICIENT_HISTORY` (string, not a number) and `raw_vol_ref_samples` records
the actual sample count. H2 now uses the percentile (<= 25) instead of the
constant `boxVol > refVol*0.65` proxy.

### RC-3 `wave_id` was 0 in 100% of rows

`EmitSignal` wrote the literal `0`. No wave model exists.

Decision: `wave_id` is an *analytic* classification, not a causal one. It is
left explicitly unset (`NA`) and documented. Inventing identifiers would create
a false grouping.

### RC-4 H1 produced zero signals

Four independent defects, each sufficient to block the detector:

1. Pullback measured against `RangeLow(t-45000, t-3000)`. That window contains
   the impulse itself, so the "pullback" low was the pre-impulse low and the
   ratio was ~1.0, always outside the 0.25-0.55 band.
2. Trigger required `r.mid > RangeHigh(t-3000, t)`. The current tick is inside
   that range, so the condition can only be true on a brand-new extreme.
3. Impulse duration was never checked (the 5-20 s requirement was absent).
4. No efficiency, volatility-decay or pullback-duration gate existed.

Fix: the impulse is located by argmax/argmin inside `[t-20 s, t-5 s]`, its
duration is checked against 5-20 s, displacement against
`max(2 x median spread60, 1.8 x sigma60)`, efficiency >= 0.60, the pullback is
measured from the impulse extreme to the subsequent extreme (25-55%, <= 45 s),
volatility must decay during the pullback, the trigger breaks the last 3 s
extreme, spread <= 1.2 x median spread60, and the stop sits behind the pullback
extreme with a 0.25 sigma margin.

### RC-5 H2 produced six signals

The compression test used a fixed ratio (`boxVol > refVol*0.65` -> reject) with
no percentile, and the quote-rate reference was the whole 300 s box. The gate
combination was therefore both arbitrary and rarely satisfied.

Fix: compression is the true percentile test (sigma300 <= p25 of the 60-minute
reference), the box is `[t-300 s, t-1 s]`, the breakout threshold is
`0.35 x spread`, the quote rate of the last 3 s must be >= 2 x the box rate,
efficiency >= 0.70, and the stop is the box mid (opposite edge when the box is
narrower than two spreads).

### RC-6 H3 was an incomplete implementation

v2.0.1 used `eff < 0.90`, had no StallScore, no Micro-BOS, no penetration upper
bound, and treated a single tick back inside the level as a reclaim.

Fix: lookback 15 minutes excluding the last 10 s; sweep confined to 15 s;
penetration bounded by `[0.20 x spread, 1.5 x sigma60]`; StallScore =
`0.5 x (1 - min(1, eff/0.30)) + 0.5 x (1 - min(1, rate_stall/rate_ref))` with a
0.50 floor; stall efficiency < 0.30; reclaim confirmed; Micro-BOS = break of the
3 s extreme formed after the sweep extreme; stop behind the sweep tail plus one
spread.

### RC-7 The control sample was deterministic

`dir = ((sec/60) % 2 == 0 ? 1 : -1)` produced a strict alternation, not a random
control. There was no seed and no record of it.

Fix: `MathSrand(InpRandomSeed)` with the seed written to the log and stored in
`Run_Summary.csv`; direction drawn from `MathRand()`; samples are emitted only
after the reference is mature so the control shares the signal conditions; the
control rows are written to a separate file `RND_Baseline.csv`.

### RC-8 Every window function scanned the whole buffer

`RangeHigh`, `RangeLow`, `PathAbsMove`, `QuoteRate`, `RealizedVolPts` and
`MedianSpread` iterated `0..ArraySize(ticks)` on every call, and four detectors
called them once per second over up to 200,000 ticks. That is ~10^11 operations
for a 2 M-tick run and explains the ~365 ticks/s throughput.

Fix: binary search (`IdxLE` / `IdxGE`) locates window edges in O(log n); window
statistics then scan only the window. The 60-minute statistics are recomputed
once per minute into a cache (`g_sigma60`, `g_medspread60`, `g_quote_rate60`,
`g_sigma300`).

### RC-9 The RAM cap could delete the 60-minute reference

When the buffer filled, v2.0.1 kept the last half and dropped the rest,
regardless of the 60-minute lookback required by the reference.

Fix: `TrimIfNeeded` only removes ticks older than
`max(H3 lookback, 3600 s) + 120 s`. If that still leaves the buffer over the cap,
the buffer grows instead of losing the window, and the trim count is reported.

### RC-10 No data-quality reporting

Every row carried `OK`. There were no counters for rejected, out-of-order or
trimmed ticks, and `EmitSignal` silently dropped signals whose structural stop
was not computable.

Fix: `data_quality_flag` now carries `OK`, `REF_INSUFFICIENT` or
`VELOCITY_NA_CONTROL`; counters are printed at shutdown and written to
`Run_Summary.csv`; dropped signals are counted in `signals_dropped_no_stop`.

### RC-11 Equal timestamps and ordering

v2.0.1 accepted equal timestamps but had no explicit record of them, and it
silently skipped out-of-order ticks.

Fix: ticks are ordered by `(time_msc, tick_seq)` — the raw file carries both
columns, so downstream sorting is exact. Equal timestamps are counted
(`ticks_equal_timestamp`) and kept; out-of-order ticks are written to the raw
file, counted (`ticks_out_of_order`) and excluded from feature generation.


### RC-12 The detector throttle never advanced

`if(... r.time_msc-last_h3_sec<1000) return;` was followed by
`last_h3_sec=t;` **only inside the branch that emitted a signal**. When no
signal fired, the timestamp was never updated, so every detector ran on every
tick and each one scanned its whole window. This is the second cause of the
~365 ticks/s throughput (RC-8 is the first).

Fix: the throttle timestamp is advanced immediately after the throttle test, on
every evaluation. Detectors now run at most once per second.

### RC-13 H3 stall and reclaim were mutually exclusive (found in the first v2.0.2 draft)

The first corrected draft measured stall efficiency over the whole path
`[sweep extreme .. now]`, which already contains the reclaim move. A low
efficiency stall and a confirmed reclaim could therefore never coexist; the
diagnostics showed `reclaim 0 / 125`.

Fix: H3 is now modelled as four explicit phases - sweep, stall, reclaim,
micro-BOS. Stall efficiency and the stall score are computed on
`[sweep extreme .. reclaim tick]`, the reclaim must be at most
`InpH3MaxReclaimAgeSec` old, and the micro-BOS must break the 3 s extreme formed
after the reclaim.

### RC-14 Ordering inside H3 diagnostics

Efficiency was tested after the composite score, so a failing score hid a
failing efficiency. The order is now efficiency -> activity -> score and the
three are counted separately.

### Findings that are properties of the feed, not code defects

* H3 emitted 0 signals: only 0.58% of reclaims have stall efficiency < 0.30,
  and the tick rate is almost flat (3 s/300 s rate ratio median 0.99, p99 1.73),
  so the activity term of StallScore is ~0 and an equal-weight score tops out
  at 0.5. Conditions were not relaxed; `InpH3StallEffWeight` exposes the
  weighting with the documented default unchanged.
* H2 emitted 13 signals: the binding gate is the 2x quote-rate expansion, and
  only 0.22% of 3 s windows reach 2x the 300 s rate on this feed. v2.0.1 also
  produced only 6, so the rarity is real.
* H1 emitted 528 signals (v2.0.1: 0). The binding filters are impulse efficiency
  (16.5% pass) and the trigger break (11.5% pass), both specification values.

---

## 2. What was changed, file by file

| Area | v2.0.1 | v2.0.2 |
|---|---|---|
| Velocity | literal / fixed divisor | measured move window, `NA` for control |
| Vol percentile | literal `"NA"` | causal ring, `INSUFFICIENT_HISTORY` below 20 samples |
| wave_id | literal `0` | `NA`, documented as unimplemented |
| H1 | 4 blocking defects | full 10-condition implementation with diagnostics |
| H2 | fixed 0.65 proxy | percentile <= 25 |
| H3 | eff < 0.90, no stall/BOS | StallScore + Micro-BOS + bounded penetration |
| RND | deterministic alternation | seeded PRNG, separate file, seed recorded |
| Lookups | O(n) full scans | O(log n) binary search + window scans |
| 60-min stats | recomputed per call | cached, recomputed once per minute |
| Memory trim | dropped half the buffer | never inside the required lookback |
| Diagnostics | none | 26 condition counters -> `Signal_Diagnostics.csv` |
| Counters | none | received/written/rejected/out-of-order/trimmed/dropped |
| Shutdown | flush + close | flush + diagnostics + summary + close |

---

## 3. What was NOT fixed, and why

0. **H3 and H2 are structurally rare on this feed.** The diagnostics quantify
   exactly which condition fails (`V2_0_2_SIGNAL_DIAGNOSTICS.csv`); nothing was
   loosened to raise the counts.
1. **wave_id remains unset.** No causal wave definition has been validated.
   Writing `NA` is deliberate; a numeric placeholder would be a false feature.
2. **H1/H2/H3 thresholds are the specification values, not fitted values.**
   They were not tuned to increase signal counts.
3. **No order-book, volume or tick-volume data.** The feed carries bid/ask
   only, so "quote rate" is used as the activity proxy.
4. **The 60-minute statistics are cached and refreshed once per minute.**
   Within a minute they are up to 60 s stale. This is causal (never future
   data) but it is an approximation, and it is documented.
5. **The reference ring holds 60 samples (60 minutes).** A longer reference is
   a parameter change, not a code change.
6. **H2 compression reference is the box quote rate**, not a separate
   compression-window statistic. The specification says "quote rate during
   compression"; the box is used as that window.
7. **A full-month run is not practical in one CI job.** The raw tick archive is
   ~117 MB per 4.3 days; a 30-day run needs roughly 8 hours of tester time and
   must be split into chunks.

---

## 4. Verification performed

| Check | Method | Result |
|---|---|---|
| Compilation | real `metaeditor64.exe` on `windows-latest` | see `compile.log` |
| No trading calls | source scan for `OrderSend`, `OrderSendAsync`, `CTrade`, `PositionOpen`, `Trade` classes | none |
| Feature arithmetic | independent Python recomputation on the emitted tick file | see `V2_0_2_DATA_VALIDATION.md` |
| Lookahead | every window ends at or before the trigger tick; the reference ring is pushed before the signal | verified by construction and by the Python cross-check |
| Ordering | `(time_msc, tick_seq)` strictly non-decreasing in the stored buffer | verified on the emitted CSV |
| Memory pressure | trim only outside the required lookback | verified in code and by the trim counter |
