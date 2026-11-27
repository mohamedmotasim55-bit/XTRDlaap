# PHASE 0 — FEASIBILITY GATE

## Account
- Broker: JustMarkets, account type Standard, leverage 1:3000
- Trade mode: DEMO (verified — all workflow runs use demo credentials; no live creds exist)
- Target equity for all sizing math: $10.00
- No leverage/deposit/withdraw changes made or proposed.

## Symbol (verified from MT5 symbol scan, symbols.csv)
- Name: XAUUSD.m (GOLD vs USD, path "Metals M\XAUUSD.m")
- point = 0.01 | contract = 100 oz | tick value = $1.00 per 1.00 pt per 1.00 lot
- volume_min = 0.01 | volume_step = 0.01
- trade_stops_level = 0 (to re-verify live)
- spread: median 26 pts, p95 60 pts (from 1-month tick profile)

## Sizing math at $10 (min lot 0.01 => 1 pt = $0.01)
| stop | points | risk $ | % equity |
|---:|---:|---:|---:|
| 0.30 | 30 | 0.30 | 3.0% |
| 0.50 | 50 | 0.50 | 5.0% |
| 1.00 | 100 | 1.00 | 10.0% |
| 2.00 | 200 | 2.00 | 20.0% |
| 3.00 | 300 | 3.00 | 30.0% |

Spread cost per trade: median $0.26 (2.6%), p95 $0.60 (6.0%).

## Gate result
- 1% risk budget = $0.10 = **10 points**.
- Spread alone = **26 points = 2.6% of equity**.
- The spread is **2.6x larger than the entire 1% risk budget**.
- Therefore NO stop (even 0 points) can keep risk <= 1%. The minimum possible
  risk per trade is the spread itself: **2.6%**.

## Verdict: NOT VIABLE (for live trading)
Position sizing is not feasible on a $10 account at 1:3000 with XAUUSD.m.
Live trading stays BLOCKED. Research continues on DEMO only.

## Implication for strategy research
Any strategy must overcome a fixed 2.6%-of-equity cost per trade. A 50% WR,
1:1 strategy loses ~2.6% per trade. To break even a strategy needs
(avg_win - avg_loss)/2 > 2.6% of equity, i.e. avg_win - avg_loss > $0.52,
or with symmetric R:R, win rate > 50% + 26/(2*stop_pts).

## Open risks
- trade_stops_level and tick_value must be read live (not assumed) before any demo order.
- p95 spread 60 pts is from a 1-month sample; a news-heavy month may be worse.
- Sandbox is Linux: no local MT5; all MT5 work runs on the GitHub Actions Windows runner (demo).
