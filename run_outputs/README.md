# V2_0_2 run outputs

Run: workflow 45642354612, tag `EDGE_LAB_V202E`, headSha `dbf4231`,
XAUUSD.m M1, real ticks, 2026-11-19 -> 2026-11-21.

| File | Rows | What it is |
|---|---:|---|
| `Run_Summary.csv` | 19 | counters, effective inputs, last reference values |
| `H3_Stall_Audit.csv` | 858 | every H3 candidate that reached the reclaim stage: penetration, sigma60, eff_stall, rate_stall, rate_ref, weight, score, verdict |
| `Signals.csv` | 541 | emitted H1 (528) and H2 (13) signals with all features |
| `RND_Baseline.csv` | 2,730 | seeded control sample (seed 20261125), separate file |
| `Market_Ticks.csv.zip` | 1,349,273 | raw tick archive (zip inside this folder, 12.7 MB) |

`V2_0_2_run_outputs.zip` bundles all five.

## Column notes

`Signals.csv` / `RND_Baseline.csv`

- `wave_id` = `NA` by design (no causal wave model exists).
- `raw_velocity_pts_s` = `NA` for control rows, never 0 as a substitute.
- `raw_vol_percentile` = `INSUFFICIENT_HISTORY` until 20 reference samples exist.
- `raw_move_window_ms` is the measured elapsed time of the move, not an assumed duration.

`H3_Stall_Audit.csv`

- `pass = eff/0.30 + rate/rate_ref <= 1` (equivalent to score >= 0.50 at weight 0.50).
- `verdict` is one of `EFF_REJECT`, `SCORE_REJECT`, `PASS`.

`Market_Ticks.csv`

- ordered by `(tick_time_msc, tick_seq)`; `tick_seq` is unique and monotonic.
