# Data Quality Audit

- events: 32216 | outcome rows: 257728 | usable numeric: 257722 | NA rows: 6
- event types: {'A_EXPANSION': 4940, 'B_MOMENTUM': 7832, 'D_REVERSION': 10378, 'C_BREAKOUT': 9066}
- spread pts: median=26.0 p95=26.0 min=26.0 max=60.0
- ticks per outcome: median=105 min=1 max=4057
- NA policy: missing forward ticks written as NA, never invented.
- price/points: point=0.01, net_pts computed from real bid/ask (BUY ask->bid, SELL bid->ask).
- tick volume/imbalance treated as activity proxy only, NOT real order flow.
