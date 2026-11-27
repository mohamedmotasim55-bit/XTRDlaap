# Data Quality Forensic Audit

- events: 32216 | outcome rows: 257728 | usable: 257722 | NA: 6
- time order monotonic: True
- spread pts: median=26.0 p05=26.0 p95=26.0 min=26.0 max=60.0
- ticks/outcome: median=105 min=1 max=4057
- event gaps(s): median=93.0 p95=291.0 max=180377.0
- Tick volume/imbalance treated as activity proxy only, NOT real order flow.

## Verdicts
1. Data validity: **Valid** (monotonic time, plausible spreads, no invented prices; NA on missing).
2. Suitability for directional testing: **Valid** (real bid/ask, 59 days, 32k events).
3. Suitability for short-term execution testing: **Valid** (per-tick bid/ask, spread present).
