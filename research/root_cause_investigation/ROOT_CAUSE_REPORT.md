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

## Long-horizon evidence (5/10/15/30 min, 59 real-tick days)
| horizon | n | mean GROSS pts | mean NET pts | MFE mean | MAE mean | %pos |
|---|---:|---:|---:|---:|---:|---:|
| 5m | 32142 | +0.09 | −25.93 | 208.6 | −259.6 | 45.8 |
| 10m | 32139 | −2.00 | −28.02 | 308.5 | −359.8 | 46.7 |
| 15m | 32136 | −0.00 | −26.02 | 384.3 | −436.3 | 47.5 |
| 30m | 32126 | −1.08 | −27.10 | 557.1 | −610.1 | 48.2 |

**Interpretation:** at 30 minutes the market offers a mean favourable excursion of 557 points, but an equal adverse excursion of 610 points, with only 48.2% of events positive. The movement is huge; the direction is 50/50. Net is negative at every horizon.

## Definitive root cause
The loss is **not** a measurement bug (recompute diff = 0.000, MFE/MAE invariants = 0 violations, spread counted once, point/$ correct), and **not** a data problem (valid real ticks). It is a **combination**:
1. **No Evidence of Directional Edge** — gross mean ≈ 0 at every horizon (1s–30m), hit rate ≈ 48–49%. The signals cannot predict direction.
2. **Execution Cost** — spread ≈ 26 pts (2.6% of $10) turns a zero-edge system into a guaranteed loser.
3. **Strategy Design Weakness** — all strategies target sub-cost moves; none requires expected MFE > cost.

**Cost sensitivity proof:** even with a hypothetical 10-pt spread and 0 slippage, mean net stays ≈ −10 pts (because gross ≈ 0). Lowering the spread alone cannot make these strategies profitable.

## The four separate questions
- Large movement exists? **YES** (p90 = 169 pts at 60s; 557 pts MFE at 30m).
- Direction predictable? **NO** (48–49% hit rate).
- Can capture part? **Only if direction known** — it is not.
- Net profit after cost? **NO** at any horizon.
