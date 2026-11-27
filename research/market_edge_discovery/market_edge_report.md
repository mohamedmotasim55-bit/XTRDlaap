# XTRD OMIGA — Market Edge Discovery Report

## 1. Integrity (SHA256 in SHA256SUMS.txt)
- Old signal engine: `XTRD_OMIGA_SIGNAL_ENGINE.mq5` — unchanged (logic not touched).
- Discovery EA: `XTRD_EDGE_DISCOVERY.mq5` — measurement only, NO trading (no OrderSend/CTrade).
- Data: `edge_events.csv`, `edge_outcomes.csv` — 59 real-tick days (2026-09-28 → 2026-11-25).

## 2. Data quality
- 32,216 events; 257,728 outcome rows; 6 NA (end-of-test, never invented).
- Real ticks, model 4, bid/ask per tick. Spread median ~26 pts.
- Point=0.01; net computed BUY ask→bid, SELL bid→ask (spread included).
- Tick volume/imbalance used as activity only, NOT real order flow.

## 3. Hypotheses tested (no look-ahead; features from data available at event time only)
| Code | Hypothesis | Detector |
|---|---|---|
| A | Volatility expansion out of compression | range > 1.5×avg60 while avg60 < 0.7×avg300; follow bar direction |
| B | Momentum persistence | |3s mid move| > 3×spread; follow |
| C | Breakout of 60s range | bid breaks hi/lo by ≥1×spread; follow |
| D | Short-term mean reversion | |z| > 2.5 vs 60s mean; fade |
| E | Session/regime structure | hour/weekday + volatility bucket on all events |

## 4. Results — classification (raw, all directions)
| Hypothesis | 10s mean | 60s mean | 300s mean | Classification |
|---|---:|---:|---:|---|
| A_EXPANSION | −25.8 | −26.3 | −26.3 | **Negative Evidence** |
| B_MOMENTUM | −27.3 | −25.4 | −28.7 | **Negative Evidence** |
| C_BREAKOUT | −25.4 | −25.7 | −28.3 | **Negative Evidence** |
| D_REVERSION | −28.4 | −27.3 | −23.6 | **Negative Evidence** |

All 95% block-bootstrap CIs lie entirely below zero. No horizon, direction, or session shows Positive Evidence.

## 5. Random baseline (60s)
| Hypothesis | engine | random | opposite | delta |
|---|---:|---:|---:|---:|
| A_EXPANSION | −26.28 | −26.01 | −25.74 | −0.27 |
| B_MOMENTUM | −25.43 | −26.02 | −26.61 | +0.59 |
| C_BREAKOUT | −25.72 | −26.03 | −26.33 | +0.30 |
| D_REVERSION | −27.34 | −26.02 | −24.71 | −1.31 |

The engine is statistically indistinguishable from a coin flip; deltas are within noise. The ~26-pt spread is not recovered.

## 6. Out-of-sample (time split 60/20/20)
Every hypothesis is negative in the OOS segment (A −32.2, B −39.5, C −35.1, D −29.7). Validation "inconclusive" cells are only due to wider CIs; none is positive.

## 7. Multiple testing
4 hypotheses × 8 horizons × 3 direction groupings = 96 core tests; plus 4×24 hour cells. With ~5% false positives expected, any isolated positive cell must be treated as noise unless it survives OOS and dedup — none did.

## 8. Verdict
**No exploitable market edge found.** All four microstructure hypotheses (expansion, momentum, breakout, reversion) lose roughly the full spread per event at 1–300s. The random baseline confirms no directional information beyond chance.

## 9. Why (mechanism)
- XAUUSD.m spread ≈ 26 pts ≈ 2.6% of a $10-equity 0.01-lot trade. Any sub-300s signal must move > 26 pts net just to break even; observed mean net moves are ~0 to −3 pts gross before spread.
- The four hypotheses capture direction only weakly; the edge (if any) is smaller than transaction cost.

## 10. Suggested next hypotheses (data-driven)
1. **Cost-aware horizon**: require expected MFE > 3× spread before entry; measure hit-rate of such filters (from feature_discovery.csv).
2. **Session × volatility interaction**: the discovery file shows regime-dependent variance; test whether a specific hour×regime has MFE/MAE ratio > cost with n≥200 in OOS.
3. **Spread regime**: test only when spread < 20 pts (lower cost environment).
4. **Longer horizons (5–30 min)** where cost/edge ratio is more favourable — not tested here.

## 11. Reproducibility
`python3 research/market_edge_discovery/analyze_market_edge.py edge_events.csv edge_outcomes.csv .` regenerates every CSV/MD. No tuning, no cherry-picking, all negative results kept.
