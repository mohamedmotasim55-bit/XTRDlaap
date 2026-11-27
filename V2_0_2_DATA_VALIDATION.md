# V2_0_2_DATA_VALIDATION

Run validated: `EDGE_LAB_V202D`, workflow run 45634943880, `windows-latest`,
JustMarkets MT5, real ticks (`Model=4`), XAUUSD.m, M1, balance 10 USD (the
program never touches the account), period 2026-11-19 -> 2026-11-21.

Artifacts used: `XTRD_XAUUSD.m_Market_Ticks.csv`,
`XTRD_XAUUSD.m_Signal_Snapshot.csv`, `XTRD_XAUUSD.m_RND_Baseline.csv`,
`XTRD_XAUUSD.m_Signal_Diagnostics.csv`, `XTRD_XAUUSD.m_Run_Summary.csv`.

---

## 1. Compilation

Real `metaeditor64.exe` log (`V2_0_2_COMPILE_LOG.txt`):

```
Result: 0 errors, 0 warnings, 1271 ms elapsed, cpu='X64 Regular'
```

Static lint (`tools/mql5_lint.py`): `OK (33 functions, 292 calls checked)`.

Trading-function scan: no `OrderSend`, `OrderSendAsync`, `OrderCheck`,
`OrderCalcMargin`, `CTrade`, `PositionOpen`, `PositionModify`, `PositionClose`
appears anywhere in the source. The only account-related call is
`AccountInfo*`, and it is not used at all.

---

## 2. Raw tick archive integrity

| Check | Result |
|---|---|
| Rows written | **1,349,273** |
| `tick_seq` unique | yes |
| `tick_seq` monotonic increasing | yes |
| `(time_msc, tick_seq)` strictly increasing | **yes, 0 duplicates** |
| `bid <= ask` on every row | yes |
| `mid == (bid+ask)/2` (tolerance 1e-9) | yes |
| Re-computed spread equals stored spread | yes |
| `tick_time_msc` non-decreasing | yes |
| Backward time steps | **0** |
| Duplicate timestamps kept | 45 (`ticks_equal_timestamp=45`) |
| Rejected quotes | 0 |
| Ticks lost between receive and write | **0** (`received == written == 1,349,273`) |
| Largest forward gap | 3,721 s (session boundary) |

`ticks_trimmed_from_ram = 1,162,056` — these are ticks evicted from the RAM
window **after** being written to disk, and only when they are older than
`max(900 s, 3600 s) + 120 s`. The 60-minute reference window was never evicted:
the buffer never held fewer than the last 62 minutes (see
`TrimIfNeeded`; `keep_from = IdxGE(t - need_ms)`).

---

## 3. Signal file integrity

| Check | Result |
|---|---|
| H1 rows | 528 |
| H2 rows | 13 |
| H3 rows | 0 (see section 6) |
| Control rows (separate file) | 2,730 |
| `wave_id` values | 100% `NA` (no invented identifiers) |
| `raw_velocity_pts_s == 0` | **0 rows** |
| `raw_vol_percentile` non-numeric | 13 rows, all `INSUFFICIENT_HISTORY` with `raw_vol_ref_samples < 20` |
| `data_quality_flag` | `OK` 528, `REF_INSUFFICIENT` 13, `VELOCITY_NA_CONTROL` 2,730 (control file) |
| Signals dropped for missing structural stop | 0 |

The 13 `REF_INSUFFICIENT` rows are the H2 signals that fired during the first
20 minutes of the run, before the reference ring reached `InpRefMinSamples=20`.
They are labelled, not silently written as a number.

---

## 4. Independent recomputation of the emitted features

300 randomly sampled H1/H2 signals were recomputed in Python directly from the
raw tick archive, joining on `trigger_tick_seq`.

| Feature | Mismatches | Max absolute difference |
|---|---|---|
| `entry_bid` / `entry_ask` | **0 / 300** | 0 |
| `entry_spread_pts` | **0 / 300** | 0.000000 |
| `raw_velocity_pts_s` vs `raw_move_pts / (raw_move_window_ms/1000)` | **0 / 300** | 0.000497 (3-decimal storage rounding) |

The velocity column is therefore arithmetically consistent with the move size
and the measured window, and it is no longer a hardcoded value.

---

## 5. Causality (lookahead) audit

| Detector | Windows used | Ends at or before trigger? |
|---|---|---|
| H1 | impulse `[t-20 s, t-5 s]`, trigger range `[t-3 s, t-1 tick]` | yes |
| H2 | box `[t-300 s, t-1 s]`, rate/efficiency `[t-3 s, t]` | yes |
| H3 | level `[t-900 s, t-10 s]`, sweep `[t-15 s, t]`, BOS `[t-3 s, t-1 tick]` | yes |
| Reference | `sigma300` samples pushed **before** the detectors run for the current tick | yes |

The reference ring push happens in `UpdateReference(r.t)` which is called before
`DetectH1/H2/H3/Random` in `OnTick`, and the sample window ends at `t-1 ms`.
No window reads `t+1` or later. There is no forward-path field in any output
column, so no outcome information can leak into a feature.

---

## 6. Why H3 emitted zero signals (measured, not assumed)

`V2_0_2_SIGNAL_DIAGNOSTICS.csv` (26 condition counters, 148,904 evaluations):

| Stage | Passed / evaluated | Pass rate |
|---|---|---|
| history | 148,880 / 148,904 | 99.98% |
| sweep present | 17,961 / 148,880 | 12.06% |
| penetration bounds | 1,052 / 17,961 | 5.86% |
| reclaim | 858 / 1,052 | 81.56% |
| **stall efficiency < 0.30** | **5 / 858** | **0.58%** |
| quote-activity decay | 5 / 5 | 100% |
| **stall score >= 0.50** | **0 / 5** | **0%** |
| emitted | 0 | — |

Two findings:

1. After a confirmed reclaim the move is, by construction, mostly directional.
   Only 0.58% of reclaims have a stall efficiency below 0.30.
2. The feed's tick rate is almost flat. Measured over the same run: the ratio of
   the 3-second tick rate to the 300-second tick rate has median **0.99**,
   p99 **1.73**, and only **0.22%** of windows reach 2.0x. With an equal-weight
   StallScore the activity term is therefore ~0 and the maximum achievable score
   is 0.5, which the `>= 0.50` gate almost never clears.

This is a property of the hypothesis on this feed, not a code defect. The
conditions were **not** relaxed. `InpH3StallEffWeight` (default 0.50) exists so
the sensitivity can be studied explicitly, and its default preserves the
documented definition.

---

## 7. Why H2 emitted only 13 signals

| Stage | Passed / evaluated | Pass rate |
|---|---|---|
| history | 148,010 / 148,904 | 99.40% |
| compression percentile <= 25 | 45,816 / 148,010 | 30.95% |
| box valid | 45,814 / 45,816 | 100% |
| breakout | 1,283 / 45,814 | 2.80% |
| **quote rate >= 2x box rate** | **31 / 1,283** | **2.42%** |
| efficiency >= 0.70 | 13 / 31 | 41.94% |
| emitted | 13 | — |

The binding constraint is the 2x quote-rate expansion. As measured above, only
0.22% of 3-second windows on this feed show a 2x rate expansion, so a breakout
that coincides with one is rare. This matches the 6 signals produced by v2.0.1,
which means the rarity is real and was not caused by the v2.0.1 coding faults.

---

## 8. Why H1 emitted 528 signals (v2.0.1 emitted 0)

| Stage | Passed / evaluated | Pass rate |
|---|---|---|
| history | 148,899 / 148,904 | 100% |
| impulse window ready | 148,899 | 100% |
| impulse shape 5-20 s | 123,776 / 148,898 | 83.13% |
| displacement | 116,222 / 123,776 | 93.90% |
| **efficiency >= 0.60** | **19,194 / 116,222** | **16.51%** |
| pullback ratio 25-55% | 6,933 / 19,194 | 36.12% |
| pullback duration <= 45 s | 6,933 / 6,933 | 100% |
| volatility decay | 4,595 / 6,933 | 66.28% |
| **trigger** | **529 / 4,595** | **11.51%** |
| spread gate | 528 / 529 | 99.81% |
| emitted | 528 | — |

The two binding filters are impulse efficiency and the trigger break. Both are
specification values and were not tuned.

---

## 9. Control sample

`RND_Baseline.csv`: 2,730 rows, produced by `MathSrand(20261125)` and
`MathRand()%2`, one sample every 60 s after the reference matured.
`raw_move_pts=0`, `raw_move_source=NA`, `raw_velocity_pts_s=NA`,
`data_quality_flag=VELOCITY_NA_CONTROL`. Direction balance and the recorded seed
make the sample reproducible; the file is separate from the hypothesis results.

---

## 10. Reproducibility

Same source + same period + same inputs produce the same files. The only
non-deterministic element is the PRNG, which is seeded by an input and logged in
`Run_Summary.csv` and the journal.

Re-run command:

```
gh workflow run backtest.yml \
  -f ea=XTRD_OMIGA_EDGE_LAB_v2_0_2 -f deposit=10 -f days=2 -f to_date=2026-11-21
```

---

## 11. Throughput

v2.0.1 processed ~365 ticks/s (4.3 days of data in ~95 minutes).
v2.0.2 processed 1,349,273 ticks in under 7 minutes end-to-end including the
MT5 install, compile and artifact upload — roughly 20x faster, because detector
evaluation is now throttled to once per second and window scans are bounded.
