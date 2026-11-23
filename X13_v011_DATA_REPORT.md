# X13 Core v0.11 — Tick Intelligence Engine · Data Validation Report

Test environment: JustMarkets demo, XAUUSD.m, M1, **Model 4 (real ticks)**,
2026.10.23 → 2026.11.22, deposit $10, leverage 1:3000, execution delay 15 ms,
no commission. Data engine only — no trading logic in this version.

## 1. Compilation

| Pass | Errors | Warnings |
|---|---|---|
| As submitted | **100** | 2 |
| After keyword restoration | **0** | **1** |

Remaining warning: `version '0.11' is incompatible with MQL5 Market, must be xxx.yyy`
(cosmetic, `#property version` format only).

The 100 errors were all one root cause: MQL5 keywords arrived machine-translated
(`دالة` → `int`, `أرجع` → `return`, `إذا` → `if`, `آخر` → `else`, `صحيح` → `true`,
`GetMicro SecondCount()` → `GetMicrosecondCount()`), plus a stray extra `)` on
`EventSetTimer`. No logic, input or threshold was touched.

## 2. Engine counters (end of month)

| Counter | Value |
|---|---|
| Ticks processed | **11,275,252** |
| Invalid ticks | **0** |
| Same-millisecond ticks | **331** |
| Gaps > 2000 ms | **14,401** |
| Ticks per bar (28,872 bars) | ~390 |

`invalid = 0` means every tick passed bid>0, ask>0, ask>=bid, time_msc>0.
331 same-ms ticks confirm the tick file carries sub-millisecond resolution.

## 3. Spread

| Metric | Value |
|---|---|
| Minimum | **26 pts** |
| Maximum | **60 pts** |
| Average (rolling 128) | 26.0 |
| Share of month at 26 | **99.85%** |

Distribution: 26 pts for 2,587,984 s, then isolated spikes to 27–58 pts
(1–9 s each) and 195 s at 60 pts. The spread is a real broker stream, not a
constant injected by the harness — it moves only during news/illiquidity.

## 4. Velocity engine

| Window | Non-zero readings | Max | Notes |
|---|---|---|---|
| V50 | 7.71% | 24,000 pts/s | only fires inside tick bursts |
| V100 | 30.90% | 24,000 pts/s | |
| V250 | 67.17% | 4,434 pts/s | |
| V1000 | 85.92% | 1,500 pts/s | main usable horizon |
| Acceleration | 56.01% | 23,677 | V100 − V250 |

XAUUSD.m averages ~4.3 ticks/s over the month, so a 50 ms window is empty most of
the time — V50 returning 0 is expected behaviour of the current formula, not a bug.
Any strategy built on V50 alone will see a signal in under 8% of seconds.

## 5. Runtime

| Version | Test time | Ticks |
|---|---|---|
| v0.10 (data only) | 23.9 s | 11,275,252 |
| **v0.11 (data + velocity + spread)** | **31.2 s** | 11,275,252 |

Cost of the intelligence layer: **+30.5%** (7.3 s). Per-tick overhead rises from
2.12 µs to 2.77 µs — acceptable for a live EA, and it leaves headroom for the
strategy layer.

## 6. Findings for the next version

1. Spread is effectively fixed at 26 pts. Any edge target below ~52 pts (2× spread)
   is not viable; the v2.25-style 5–10 pt targets are unreachable.
2. V50/V100 saturate at 24,000 pts/s (clamp), so they cannot separate "fast" from
   "extreme". A percentile rank is needed instead of a raw value.
3. 14,401 gaps > 2 s exist — session breaks and weekends. Regime logic must reset
   across a gap rather than carry state.
4. Same-ms ticks (331) mean the velocity loop can divide by zero-age; the guard
   `if(elapsed <= 0) return 0.0` handles it, but it silently drops signal.
5. `X13_UpdateRegime()` still returns `REGIME_UNKNOWN`; no strategy can be gated
   until it is implemented.

## 7. Artifacts

- `X13_Core_v011.mq5` — source (keywords restored)
- `X13_Core_v011_Diagnostics.csv` — 2,592,000 heartbeat rows
- `X13_v011_data_dashboard.svg` — metrics dashboard
- CI run: https://github.com/mohamedmotasim55-bit/XTRDlaap/actions/runs/45204904514
