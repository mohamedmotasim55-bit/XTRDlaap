# Conditional Market Predictability Discovery

Capital fixed **10 USD**. Decisions: 29592 (120s sampling, 59 days). Split disc/val/oos = 17446/6606/5510 (embargo 1800s).

## Top features by information gain (60s, discovery set)

| feature | IG |
|---|---|
| dist_low | 0.00090 |
| dist_high | 0.00063 |
| z | 0.00051 |
| v5s | 0.00035 |
| v500ms | 0.00032 |
| accel | 0.00032 |
| atr60_pts | 0.00030 |
| v10s | 0.00029 |

## First passage (discovery)

level,n,p_up_first,p_down_first,p_none,mean_up_time_s,mean_down_time_s
1.0x,17446,0.4940,0.5059,0.0001,35.00,34.57
1.5x,17446,0.4940,0.5052,0.0008,46.11,46.53
2.0x,17446,0.4914,0.5050,0.0036,56.11,57.39
3.0x,17446,0.4815,0.4970,0.0215,74.76,75.64

## Classification rules
- IG ~ 0 => No Predictive Information. Any lift must survive OOS to be Confirmed.
- Confirmed Predictive Information / Statistical Association Only / No Predictive Information / Inconclusive.

## Data
- 29,594 decisions (120s sampling, 59 real-tick days). Split: discovery 17,446 / validation 6,606 / OOS 5,510 (1800s embargo).
- 473,420 outcome rows (NET_SHORT 8 horizons, NET_LONG 4 horizons, FIRST 4 levels).

## Key results
### Information gain (60s, discovery)
All 22 features: IG < 0.001 bits (max dist_low = 0.00090). Essentially zero predictive information.

### Directional predictability
Per-bin P(up) ranges 0.46-0.52 with lifts of ±2-3 percentage points. These do NOT survive OOS — signs flip (e.g., dist_low: discovery -3.2% -> OOS +2.1%; z: +2.2% -> -1.0%; v5s: -2.1% -> +2.4%).

### First passage (discovery, ±k x spread)
| level | p_up_first | p_down_first | p_none | mean time |
|---|---:|---:|---:|---:|
| 1.0x | 0.4940 | 0.5059 | 0.0001 | ~35s |
| 1.5x | 0.4940 | 0.5052 | 0.0008 | ~46s |
| 2.0x | 0.4914 | 0.5050 | 0.0036 | ~56s |
| 3.0x | 0.4815 | 0.4970 | 0.0215 | ~75s |
Symmetric ~50/50 at every level. No directional advantage in first-passage either.

### Feature interactions
Largest |lift| = 2.7% (v3s x atr60), all within noise; signs unstable across segments.

### Economic value (OOS)
Every conditional cell: p_up 0.46-0.51, mean net buy and sell both negative after 26-pt spread. No "buy candidate" or "sell candidate" survived OOS.

## Classification
| Discovery | Classification |
|---|---|
| All 22 single features vs direction | **No Predictive Information** |
| All tested 2-way interactions | **Statistical Association Only** (unstable, sign-flips OOS) |
| First-passage direction (1/1.5/2/3x) | **No Predictive Information** (50/50) |
| Any conditional edge after cost | **No Predictive Information** |

## Verdict
At 120s decision points on XAUUSD.m, **no market-state feature or interaction predicts the direction of the next 1s-30m move better than chance**. The market moves enough (MFE grows with horizon) but direction is symmetric and unpredictable from these features. This confirms the root-cause audit: the missing ingredient is genuine directional predictability, which these features do not provide.

## Suggested next directions (data-driven, not tested here)
- Features not in this set: order-book depth (unavailable in MT5 retail), cross-asset (DXY, yields, VIX) lead-lag, news-calendar conditioning.
- Higher-frequency (sub-second) microstructure with tick-rule signed volume.
- Regime-switching models conditioned on realised-volatility state (tested here only as a single feature; full HMM not tested).
