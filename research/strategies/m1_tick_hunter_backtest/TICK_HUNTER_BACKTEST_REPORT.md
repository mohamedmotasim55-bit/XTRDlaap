# XTRD_M1_TICK_HUNTER — Backtest Report (59 days, $10, 1:3000)

## Environment (verified from report)
- Broker: JustMarkets-Demo (Build 6328) | Symbol: XAUUSD.m | Period: M1
- Range: 2026.09.28 – 2026.11.26 (59 days) | Model: real ticks (100% quality)
- Ticks: 22,162,626 | Bars: 59,183 | Currency: USD
- Initial Deposit: **10.00** | Leverage: **1:3000** | Commission: 0
- Inputs: InpEnableLiveTrading=true, InpEntryMode=1 (market), InpFixedVolume=0.01, InpMaxRiskPercent=10, InpSignalScoreThreshold=7
- Compile: 0 errors, 1 warning

## RESULTS (all metrics)
| Metric | Value |
|---|---|
| Total Net Profit | **-7.25 USD (-72.50%)** |
| Gross Profit | 6.01 |
| Gross Loss | -13.26 |
| Profit Factor | **0.45** |
| Expected Payoff / trade | **-0.21** |
| Recovery Factor | -0.98 |
| Sharpe Ratio | -5.00 |
| Z-Score | 1.83 (93.28%) |
| AHPR | 0.9682 (-3.18%) |
| GHPR | 0.9627 (-3.73%) |
| Balance Drawdown Maximal | 7.25 (72.50%) |
| Equity Drawdown Maximal | 7.38 (73.80%) |
| Margin Level | 184.51% |
| Total Trades | 34 |
| Long Trades | 12 (won 25.00%) |
| Short Trades | 22 (won 18.18%) |
| Profit Trades | 7 (20.59%) |
| Loss Trades | 27 (79.41%) |
| Largest profit trade | 2.26 |
| Largest loss trade | -0.91 |
| Average profit trade | 0.86 |
| Average loss trade | -0.49 |
| Max consecutive losses | 10 (-3.59) |
| Avg consecutive losses | 3 |
| Min / Avg / Max holding | 0s / 3s / 16s |
| Corr(Profits,MFE) | 0.96 |
| Corr(Profits,MAE) | 0.58 |
| Corr(MFE,MAE) | 0.34 |

## SIGNAL FUNNEL
- Signals logged (score>=7): **2,443,913** over 59 days (~41,400/day, ~28.7/min)
  - WICK_REJECTION: 1,848,420 (75.7%)
  - MOMENTUM_PULLBACK: 595,493 (24.3%)
- Trades executed: **34** (0.58/day)
- Signal-to-trade ratio: **~71,880 : 1** -> the risk/spread/margin gates reject ~99.999% of signals.

## WHY IT LOSES (root-cause analysis)
1. **3-second average holding vs 26-pt spread.** A round trip costs ~26 pts = $0.26 = **2.6% of the $10 account**. A 3-second move rarely exceeds this; the EA exits on a tight SL/trail before any edge materialises. Max holding was only 16s.
2. **Win rate far below breakeven.** Avg win $0.86 / avg loss $0.49 -> R:R 1.75 -> breakeven win rate = 0.49/(0.86+0.49) = **36.3%**. Actual = **20.6%**. Expectancy = 0.206*0.86 - 0.794*0.49 = **-0.21/trade** (matches report).
3. **Spread drag is the dominant cost.** 34 round-trips x ~$0.26 = ~$8.8 of spread; the realised loss (-7.25) plus a small gross edge (6.01) is almost entirely spread. The gross (pre-spread) edge is negative.
4. **Risk gate starves the strategy.** With $10 / 0.01 lot, 1 pt = $0.01. InpMaxRiskPercent=10 -> max $1 risk -> max SL = 100 pts. Any signal needing SL > 100 pts is rejected. This is why 2.44M signals -> 34 trades. The EA cannot express its own signal density on this account size.
5. **Exit logic never engages.** InpExitOnMomentumFlip=false; trailing starts at 42 pts (rarely reached in 3s). So exits are almost always immediate stop-outs.
6. **DOM absent in tester** (dom_valid=0) removes one scoring component; minor vs the structural issues.

## THE QUALITATIVE-LEAP MATH (why $10 + 0.01 lot + 26-pt spread is the binding constraint)
- 1 round-trip spread = $0.26 = **2.6% of equity**.
- To break even you need a **>2.6% edge per trade**; at 34 trades the expected spread drag is ~88% of equity. Observed -72.5% is consistent.
- Minimum viable: a strategy that (a) holds minutes not seconds, (b) targets >= 3x spread (>=78 pts = $0.78), (c) stops <= 1.5x spread (<=39 pts = $0.39), (d) requires expected move >= 2.5x spread before entry.
- On $10/0.01 lot the risk per trade cannot be < $0.01/pt, so SL must stay <= ~100 pts to respect 10% risk. This caps the strategy to tight-stop, medium-horizon setups only.

## ACTIONABLE FIXES (ranked)
1. **Kill the 3s scalp.** Enforce min holding (e.g., 60s) or target >= 3x spread. The current micro-hold cannot pay the spread.
2. **Raise InpMinExpectedMoveSpreadFactor** from 0.45 to >= 2.5 (expected 3s move must exceed 2.5x spread = 65 pts before entry).
3. **Raise InpSignalScoreThreshold** and require MOMENTUM_PULLBACK only (WICK_REJECTION is 75.7% of signals but mean-reverting into the spread).
4. **Cap SL at 100 pts** explicitly and reject anything wider (already implicit via risk gate) - but then require the target to still be >= 3x spread.
5. **Test at longer horizons** (5-30 min) with first-passage 2R/1R - the only regime where a >26-pt move is plausible (see prior rescue/next-gen research: still < spread on this broker).
6. **Honest verdict:** on JustMarkets Standard XAUUSD.m (26-pt spread) with a $10 account, tick scalping is mathematically unviable. The same conclusion held across 6 prior research missions. A real leap requires either a **lower-spread account (<=8-10 pts)** or **external data (DXY/silver/news)** to raise the conditional move above 26 pts.

## Reproduce
- EA: XTRD_M1_TICK_HUNTER.mq5 (commit 4e9ce42)
- Run: backtest.yml, days=59, model=4, execution_mode=15, deposit=10, extra_inputs="InpEnableLiveTrading=true,InpEntryMode=1", tag=tick59
- Artifacts: backtest_report.htm, metrics.json, compile.log (this folder); signals CSV (425MB, not committed)
