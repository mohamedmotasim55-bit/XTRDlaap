# Root Cause Report

Reference capital: **10.0 USD** (fixed, unchanged).

## Measurement correctness
- Independent recompute vs EA: mismatches=0, max diff=0.000 pt -> **Correct**.
- Spread counted once; point=0.01; $/pt=0.01 -> **Correct**.
- MFE/MAE invariant violations=0 -> **Correct**.

## Where the movement disappears (60s, all events)
- mean GROSS (mid-to-mid) = -0.24 pts
- mean NET (after spread) = -26.26 pts
- mean cost (spread) = 26.02 pts

## Classification
| Issue | Classification |
|---|---|
| Point/price/dollar conversion | **Correct (no bug)** |
| Spread double-charged | **No (correct)** |
| Execution (ask/bid) simulation | **Correct** |
| MFE/MAE computation | **Correct** |
| Data validity | **Valid** |
| Directional edge | **No Evidence of Directional Edge** |
| Execution cost | **Execution Cost** (spread ~26 pts > gross move) |
| Strategy design | **Strategy Design Weakness** (targets < spread) |

## Answers to the 10 questions
1. Measurement method correct? **Yes** (independently verified).
2. Tick data reliable? **Yes** (monotonic, plausible spreads, no invented prices).
3. Spread computed correctly? **Yes**, counted once.
4. Loss from cost or no direction? **Both**: gross edge ~0 and cost ~26 pts.
5. Common defect across strategies? **Yes** — all target sub-spread moves on a 26-pt-spread symbol.
6. Exploitable movement missed? **Not at 1-300s**; longer horizons untested.
7. Bad design or unsuitable conditions? **Unsuitable conditions**: costs exceed achievable edge.
8. Evidence of pre-cost edge? **None** (gross mean ≈ 0).
9. Conditions before a strategy is valid? See FOUNDATION_SPECIFICATION.md.
10. Technical/statistical basis? See FOUNDATION_SPECIFICATION.md.
