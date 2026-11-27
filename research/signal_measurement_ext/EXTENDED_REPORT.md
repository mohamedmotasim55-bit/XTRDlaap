# XTRD OMIGA — Extended Horizon Validation Report

## Integrity
- Engine (unchanged): `XTRD_OMIGA_SIGNAL_ENGINE.mq5` SHA256 = `f12858e41263ae6513d1a843328749df6a3d0cb451d04ed6c49debe1525fa30e`
- Measurement EA: `XTRD_OMIGA_SIGNAL_ENGINE_MEASURE_EXT.mq5` (logging only; signal-scoring & indicator blocks byte-identical to engine)
- Data: real ticks, 7 days, model 4; 6,757 signals; 33,785 follow-up rows; 17 NA (end-of-test, not invented).
- Execution: BUY ask-in/bid-out, SELL bid-in/ask-out. Net already includes spread.

## Overall: engine vs fair random baseline (block bootstrap 95% CI)

| horizon | n | engine mean | 95% CI (block) | random mean | opposite mean | delta vs random | verdict |
|---|---|---|---|---|---|---|---|
| 10s | 6756 | -23.97 | [-26.23, -21.69] | -26.02 | -28.08 | 2.06 | Negative evidence |
| 30s | 6756 | -24.45 | [-28.38, -20.59] | -26.02 | -27.58 | 1.56 | Negative evidence |
| 60s | 6755 | -24.24 | [-30.78, -17.97] | -26.02 | -27.79 | 1.78 | Negative evidence |
| 120s | 6753 | -24.61 | [-36.06, -13.14] | -26.01 | -27.41 | 1.40 | Negative evidence |
| 300s | 6748 | -19.48 | [-45.13, 5.46] | -26.01 | -32.54 | 6.53 | Inconclusive |

## Clustered (temporally close same-direction signals merged; raw preserved)

| horizon | n | engine mean | 95% CI (block) | random mean | delta vs random | verdict |
|---|---|---|---|---|---|---|
| 10s | 3911 | -23.50 | [-26.67, -20.31] | -26.02 | 2.52 | Negative evidence |
| 30s | 3911 | -24.85 | [-30.11, -19.88] | -26.01 | 1.16 | Negative evidence |
| 60s | 3910 | -24.00 | [-30.75, -18.01] | -26.01 | 2.01 | Negative evidence |
| 120s | 3909 | -26.63 | [-38.08, -16.37] | -26.01 | -0.63 | Negative evidence |
| 300s | 3907 | -19.48 | [-44.18, 3.93] | -26.01 | 6.53 | Inconclusive |

## Strategy classification (raw, 60s)

| strategy | n | mean | 95% CI | classification |
|---|---|---|---|---|
| Breakout | 923 | -27.21 | [-46.72, -6.21] | Negative evidence |
| Exhaustion | 3 | -194.67 | [NA, NA] | small sample — no verdict |
| MeanReversion | 1 | -3.00 | [NA, NA] | small sample — no verdict |
| Momentum | 5926 | -23.33 | [-30.46, -16.68] | Negative evidence |
| TickFlow | 2761 | -27.31 | [-35.88, -19.44] | Negative evidence |
| TrendPullback | 4398 | -21.93 | [-29.93, -14.73] | Negative evidence |

## Strategy classification (raw, 300s)

| strategy | n | mean | 95% CI | classification |
|---|---|---|---|---|
| Breakout | 920 | -34.63 | [-83.94, 23.77] | Inconclusive |
| Exhaustion | 3 | 6.00 | [NA, NA] | small sample — no verdict |
| MeanReversion | 1 | 692.00 | [NA, NA] | small sample — no verdict |
| Momentum | 5919 | -15.91 | [-43.63, 10.99] | Inconclusive |
| TickFlow | 2759 | -27.96 | [-58.08, 0.88] | Inconclusive |
| TrendPullback | 4393 | -12.75 | [-43.63, 17.15] | Inconclusive |

## Session analysis & multiple-testing caveat
115 hour×horizon tests (raw). Only 2 showed "Positive evidence" (hour 4 @300s: +117.2 CI[15.4,236.7]; hour 17 @300s: +198.7 CI[15.1,416.1]). At a 5% level over 115 tests, **~5.8 false positives are expected** — 2 is *below* chance. After clustering (dedup), both fall to n=164 and n=142 (< 200 threshold) → "small sample — no verdict". 59 cells are Negative evidence.

## Verdict
**No Positive evidence at any horizon, strategy, or session.**
- Every horizon has a negative mean; 10s–120s are statistically negative (CI entirely < 0).
- 300s is "Inconclusive" only because variance explodes (CI crosses 0); mean still negative (−19.5).
- The engine beats the coin-flip baseline by +1.4 to +6.5 pts, but this is far below the ~26-pt spread.
- The 2 hour-level positives are consistent with multiple-comparison noise and do not survive dedup.

## Limitations
- 7 days, one instrument, one broker (JustMarkets demo, real ticks). No out-of-sample period available here; any hour-level signal would require fresh OOS data before consideration.
- 300s horizons have very high variance; larger samples needed.
- No live spread/latency comparison (sandbox has no persistent MT5).

## Conclusion
The current BUY/SELL signal engine does not possess a measurable, statistically stable edge after costs at 10s–300s. No execution layer should be built. Next evidence-gathering step: re-measure on a longer, separate out-of-sample period, focusing on the London/NY overlap (hours 15–17) where session structure — not indicators — is the plausible source of edge.
