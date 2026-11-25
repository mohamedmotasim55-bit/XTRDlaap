# V2_0_2_H3_STALL_AUDIT — arithmetic proof of the StallScore rejections

Run audited: workflow run **45642354612**, tag `EDGE_LAB_V202E`,
`headSha = dbf423169e5f31f2ef91a21c19e0a88693728f87`.
Period 2026-11-19 -> 2026-11-21, XAUUSD.m, M1, real ticks, deposit 10 USD
(unused by the program).

---

## 1. Effective inputs

The workflow builds `[TesterInputs]` only when `INPUT_RISK`, `INPUT_POS` or
`INPUT_EXTRA` is non-empty. All three were empty in every run (the job log
prints `INPUT_RISK:`, `INPUT_POS:`, `INPUT_EXTRA:` with no value), so **no EA
input was overridden** and every parameter took its compiled default.

The program now writes the effective values into `Run_Summary.csv`
(`V2_0_2_RUN_SUMMARY.csv`):

| Input | Value |
|---|---|
| `InpH3StallEffWeight` | **0.50** |
| `InpH3MaxStallEfficiency` | 0.30 |
| `InpH3MinStallScore` | 0.50 |
| `InpH3ReclaimSpreadFrac` | 0.15 |
| `InpH3MaxReclaimAgeSec` | 30 |
| `InpH3LookbackSeconds` | 900 |
| `InpH3ExcludeLastSec` | 10 |
| `InpH3MaxSweepSeconds` | 15 |
| `InpH3MinPenetrationSpreadFrac` | 0.20 |
| `InpH3MaxPenetrationSigmaMult` | 1.5 |
| `InpH3StopSpreadMult` | 1.0 |
| `InpRefMinSamples` | 20 |
| `InpRandomSeed` | 20261125 |

---

## 2. The premise in the review is not algebraically correct

The documented score is

```
score = w * (1 - min(1, eff / 0.30)) + (1 - w) * (1 - min(1, rate / rate_ref))
```

With `w = 0.50` and both `min()` terms inactive (which is the case whenever
`eff < 0.30` and `rate < rate_ref`), the gate `score >= 0.50` becomes

```
0.5*(1 - eff/0.30) + 0.5*(1 - rate/rate_ref) >= 0.5
(1 - eff/0.30) + (1 - rate/rate_ref)            >= 1
eff/0.30 + rate/rate_ref                        <= 1        <-- the real condition
```

So passing `eff < 0.30` **and** `rate < rate_ref` guarantees only that each
normalised term is below 1. It does **not** guarantee that their **sum** is
below 1. When the sum exceeds 1 the score is below 0.50 and the candidate is
rejected — which is exactly what happened in all five cases.

`eff < 0.30` and `rate < rate_ref` are therefore **necessary but not
sufficient**. This is why `H3_05 = 5/858` and `H3_06 = 5/5` coexist with
`H3_07 = 0/5`; there is no contradiction and no defect in the accounting.

---

## 3. Manual recomputation of the five cases

All numbers below are read from `V2_0_2_H3_STALL_AUDIT.csv`, which the Expert
Advisor itself wrote during the run.

`e = eff/0.30`, `r = rate/rate_ref`, `t1 = 0.5*(1-e)`, `t2 = 0.5*(1-r)`.

| # | tick_seq | side | pen (pts) | eff_stall | e | rate_stall | rate_ref | r | t1 | t2 | **sum = e+r** | score | gate (sum ≤ 1) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 127415 | UP sweep | 13.0 | 0.253333 | 0.844443 | 2.893 | 3.593 | 0.805177 | 0.077778 | 0.097412 | **1.649620** | 0.17519 | **FAIL** |
| 2 | 127421 | UP sweep | 10.0 | 0.253333 | 0.844443 | 2.893 | 3.593 | 0.805177 | 0.077778 | 0.097412 | **1.649620** | 0.17519 | **FAIL** |
| 3 | 165488 | UP sweep | 15.0 | 0.171429 | 0.571430 | 4.511 | 5.985 | 0.753718 | 0.214285 | 0.123141 | **1.325148** | 0.33743 | **FAIL** |
| 4 | 165496 | UP sweep | 15.0 | 0.171429 | 0.571430 | 4.511 | 5.985 | 0.753718 | 0.214285 | 0.123141 | **1.325148** | 0.33743 | **FAIL** |
| 5 | 778042 | DN sweep | 12.0 | 0.292308 | 0.974360 | 4.105 | 4.943 | 0.830467 | 0.012820 | 0.084766 | **1.804827** | 0.09759 | **FAIL** |

Reading case 3 line by line:

```
eff/0.30        = 0.171429 / 0.30 = 0.571430
rate/rate_ref   = 4.511 / 5.985   = 0.753718
sum             = 1.325148  >  1.0            -> score < 0.5
t1              = 0.5 * (1 - 0.571430) = 0.214285
t2              = 0.5 * (1 - 0.753718) = 0.123141
score           = 0.214285 + 0.123141 = 0.337426  <  0.50  -> SCORE_REJECT
```

Storage note: `rate_stall_s` and `rate_ref_s` are written with 3 decimals, so a
score recomputed from the CSV can differ from the stored score by ~1e-4 (e.g.
0.17519 vs 0.17513). The verdict is unaffected — every case is far below 0.50.

Note also that rows 1-2 are two evaluations of the **same** sweep 1.1 s apart,
and rows 3-4 the same sweep 0.9 s apart. There are **three distinct sweep
events**, not five.

---

## 4. Consistency of the audit with the Signal Diagnostics

| Diagnostics row | Evaluated | Passed | Audit cross-check |
|---|---|---|---|
| `H3_04_reclaim` | 1,052 | **858** | audit has exactly **858** rows (written after the reclaim gate) |
| `H3_05_stall_efficiency` | 858 | **5** | rows with `eff_stall < 0.30` = **5** |
| `H3_06_quote_activity_decay` | 5 | **5** | of those, `rate_stall < rate_ref` = **5** |
| `H3_07_stall_score` | 5 | **0** | of those, `score >= 0.50` = **0** |
| `H3_08_micro_bos` | 0 | 0 | never reached |
| `H3_09_emitted` | 0 | 0 | never reached |

The executed code and the diagnostics report are the same object: both are
produced by the same binary in the same run, and the counts reconcile exactly.

---

## 5. Independent replication from the raw ticks

`H3` was re-implemented from scratch in Python over
`XTRD_XAUUSD.m_Market_Ticks.csv` (1,349,273 ticks), using the same windows,
the same 1 s evaluation cadence, the same 60 s reference cache and the same
arithmetic. It does not read any EA output.

| Comparison on the 858 reclaim-stage cases | Result |
|---|---|
| Row count | 858 vs 858 |
| Joined on `tick_seq` | 858 / 858 |
| `verdict` identical | **True** |
| `eff_stall` max abs difference | **0.000000** |
| `rate_stall_s` max abs difference | **0.000000** |
| `rate_ref_s` max abs difference | **0.000000** |
| `stall_score` max abs difference | **0.000000** |
| `penetration_pts` max abs difference | **0.000000** |
| `sigma60_pts` max abs difference | 0.0019 (4-decimal display only) |

Direction sign convention: an **up** sweep produces a **short** signal
(`direction = -1`); the EA is correct, the replica's own report column used the
opposite label for the same event.

---

## 6. Compiled file = tested file

| Evidence | Value |
|---|---|
| Run `headSha` | `dbf423169e5f31f2ef91a21c19e0a88693728f87` |
| `git rev-parse HEAD:XTRD_OMIGA_EDGE_LAB_v2_0_2.mq5` | `9367dc25b475fbfff72594920ffb374d42edfef1` |
| SHA-256 of that blob | `b2bde2a1184a7501baba2347376c271a714a2818856b9ac00a3e06440bc0fd7e` |
| SHA-256 of the delivered working file | `b2bde2a1184a7501baba2347376c271a714a2818856b9ac00a3e06440bc0fd7e` |
| Compile log path | `C:\mt5\MQL5\Experts\XTRD_OMIGA_EDGE_LAB_v2_0_2.mq5` |
| Compile result | `0 errors, 0 warnings, 1116 ms elapsed, cpu='X64 Regular'` |

The compile and the strategy test happen in the **same** CI job: the job
checks out `headSha`, copies that file to `MQL5\Experts`, compiles it, and then
runs `terminal64.exe` with `Expert=XTRD_OMIGA_EDGE_LAB_v2_0_2.ex5`. There is no
step in which a different source or a stale `.ex5` could be substituted
(the workflow aborts if the `.mq5` is missing and never reuses a pre-built
`.ex5` when the source exists).

---

## 7. Final root cause statement

1. **No defect was found in the StallScore accounting.** The five cases were
   correctly rejected: the normalised sum `eff/0.30 + rate/rate_ref` is
   1.33-1.80 in every case, i.e. well above the 1.0 required for `score >= 0.5`.
2. **The documentation was ambiguous.** `V2_0_2_FEATURE_DEFINITIONS.md` listed
   the score formula and the 0.50 threshold but did not state the equivalent
   condition `eff/0.30 + rate/rate_ref <= 1`. That omission is what made
   "both gates passed" look sufficient. The document has been corrected; the
   code was not.
3. **No threshold was modified** in H1, H2 or H3. The only code change in this
   round is instrumentation: an `H3_Stall_Audit.csv` file and the effective
   inputs in `Run_Summary.csv`.

## 8. What would have to change for H3 to emit signals

Not applied, and deliberately so — this is a research decision, not a bug fix:

- With `InpH3StallEffWeight = 1.0` the score becomes `1 - eff/0.30`, and the
  0.50 gate then requires `eff <= 0.15`. The observed minimum among the three
  distinct events is 0.171429, so even that variant would still reject them.
- Relaxing `InpH3MaxStallEfficiency` or `InpH3MinStallScore` would change the
  definition and is therefore out of scope for this task.
