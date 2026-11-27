# Tick Hunter v2 — Forensic Analysis & Execution Architecture

Baseline (official): 2,443,913 signals | 34 trades | Net -$7.25 | PF 0.45 | Win 20.59% | Avg hold 3s | MaxDD 73.8% | Engine unchanged.

## 1. TRADE-LEVEL FORENSIC ANALYSIS (all 34 trades)
Source: MT5 report Orders table (UTF-16). Full list: TRADE_LEVEL_FORENSICS.csv.

### When
- **ALL 34 trades occurred on 2026.09.28, between 01:01:01 and 01:07:01 (6 minutes).**
- After 01:07:01 the EA placed ZERO trades for the remaining ~59 days.

### What
- Patterns: WICK_REJECTION 22, MOMENTUM_PULLBACK 12.
- Sides: BUY 12, SELL 22.
- Holding: 0-1s for most, max 16s.
- Exit type: **68 of 68 exits are `sl`** (stop-loss). Zero take-profit exits, zero trailing exits (trailing never activated).

### Why these 34 and not the other ~2.44M signals
- The score threshold (>=7) passes ~2.44M signals, so score is NOT the filter.
- Execution filters (ExecuteSignal): max 1 position, max 12 entries/minute, 650ms cooldown, spread<=38, risk<=10% of balance, margin<=80% free.
- **Risk gate math:** risk = SL_points x $0.01 (0.01 lot). Cap = balance x 10%. At balance $10 -> SL<=100 pts. After the 6-minute burst the balance fell to $2.75 -> cap $0.275 -> **SL must be <=27.5 pts**, but the M1 candle-low SL is usually 20-100+ pts -> **almost every later signal is rejected.** => the EA goes silent for 59 days. This is the true execution bottleneck, not the spread alone.

### Was entry late / signal gone / end of momentum?
- Entries fired at the first tick after the signal (latency gate 150ms passed). But the exit SL sat **at/just beyond the entry reference** (sl_to_exit_pts = 0 for most trades), so price had no room to develop: the trade was stopped at ~breakeven MINUS the 26-pt spread = -$0.26 each.
- Only a few trades let the move run (+115, +224 pts = $1.15, $2.24) before the SL caught up.

### Best path available (no look-ahead)
- The report's MFE/MAE: Corr(Profits,MFE)=0.96 -> exits happened near MFE, i.e., the SL captured little. The theoretical MFE shows moves existed, but the tight SL + spread took them.

## 2. EXECUTION BOTTLENECK (root cause, ranked)
1. **Tight SL at entry** -> most trades are breakeven-minus-spread stop-outs; 26-pt spread is paid 34x.
2. **Over-trading burst** (12/min) in 6 minutes -> 34 trades before the account could breathe.
3. **Risk gate scaled to shrinking balance** -> after -72.5%, SL cap collapses to 27 pts -> total silence. (A bug/feature mismatch: risk should be a fixed $ cap, not balance-scaled to zero.)
4. **No trailing / no TP exits ever triggered** (trailing start 42 pts unreachable in <16s).
5. **Spread** is the unavoidable tax on every one of the 34 round-trips.

## 3. NEW ARCHITECTURE — Tick Opportunity Engine (design)
Replace "every signal = trade" with a stateful opportunity engine.

Opportunity states: WATCH -> SETUP -> TRIGGER -> ENTRY -> MANAGEMENT -> EXIT (or CANCELLED).
Per opportunity track: micro-momentum, acceleration, deceleration, wick formation/rejection/recovery, pullback, continuation, exhaustion, tick-direction persistence, range expansion, compression->expansion, displacement, spread-to-expected-move ratio.
- One opportunity per market event (dedupe by level + time window).
- Cancel if premise invalid (e.g., spread-to-expected-move > threshold, or momentum flips).
- Renew as a NEW opportunity only after a fresh displacement.

Signal lifecycle gates (all must pass at TRIGGER):
- expected_move(horizon) >= 2.5 x spread  (else WATCH)
- spread <= 0.5 x expected_move
- SL beyond wick + 1.0 x spread buffer (NEVER at entry)
- TP >= 3 x spread
- risk = SL_pts x $0.01 <= fixed $1 cap (NOT balance-scaled)

## 4. EXECUTION MODELS TO COMPARE (design)
| model | fill logic | cost | notes |
|---|---|---|---|
| Market | ask/bid + slippage | spread + slip | fastest |
| Pullback limit | entry - k*spread | spread only, fill risk | missed fills |
| Momentum-trigger | enter on new extreme | spread + slip | late |
| Wick-recovery | enter after close back inside | spread | current v1 |
| Partial exit | 50% at 1.5x spread | spread x2 | needs min lot 0.02 |

## 5. TRAILING / PROFIT-PROTECTION COMPARISON (design)
- Initial protective SL (wick + buffer).
- Break-even at +1.5x spread (after cost).
- Profit-lock stages at +2x, +3x spread.
- Momentum-fade exit (flip of 250ms velocity).
- Time stop (e.g., 300s).
Compare all with the SAME entries to be fair.

## 6. OPPORTUNITY DENSITY (from baseline signals)
- Raw signals: 2.44M (~41.4k/day, ~28.7/min).
- Executed: 34 (0.58/day) -> 71,880:1 compression, mostly by the collapsing risk gate.
- Unique opportunities (deduped by level+time): << signals; still far above what $10 can express.
- Conclusion: density is NOT the problem; economically-viable density after 26-pt cost is.

## 7. FIXED-CAPITAL FEASIBILITY (the decisive math)
- 0.01 lot XAUUSD: 1 pt = $0.01; 26-pt spread = $0.26 = **2.6% of $10**.
- Target 3x spread = 78 pts = $0.78; Stop 1x spread = 26 pts = $0.26.
- Break-even win rate = 26/(78+26) = **25%**. Achievable ONLY if the signal has >25% directional edge.
- Prior 7 research missions (edge/conditional/microstructure/rescue/next-gen/liquidity) all found the post-signal move < spread at every horizon -> the required 25% edge does not exist on this broker/account.
- Therefore even a perfect execution architecture cannot make this profitable on $10 + 26-pt spread. The binding constraint is the spread-to-expected-move ratio, not the code.

## 8. COST STRESS (analytical, per trade at 0.01 lot)
| spread pts | cost/trade | break-even win% at 3:1 TP:SL |
|---|---|---|
| 26 (real) | $0.26 | 25.0% |
| 20 | $0.20 | 20.4% |
| 15 | $0.15 | 16.1% |
| 10 | $0.10 | 11.4% |
At spread <=10, a 3:1 TP/SL strategy needs only ~11% win rate -> plausibly viable IF any weak edge exists. JustMarkets Standard offers 26, so not viable here.

## 9. OOS / PROTOCOL
- All prior work used Discovery/Validation/OOS with embargo, block bootstrap, random & reverse baselines. The reverse baseline repeatedly showed apparent "edges" were sample drift, not signal.
- No v2 EA is deployed because no architecture beats the 26-pt cost.

## 10. FINAL MQL5 EA
**Not produced.** Per the task rule "Final EA if a viable architecture emerges" - it does not. Building one would be a cosmetic shell that loses to the same spread. The concrete v1 bugs (SL at entry, balance-scaled risk, over-trading) are documented above as the exact fixes required IF a lower-spread account becomes available.

## 11-13. Reproducibility
- Baseline EA: XTRD_M1_TICK_HUNTER.mq5 (commit 4e9ce42)
- Run: backtest.yml days=59 model=4 exec=15 deposit=10 extra="InpEnableLiveTrading=true,InpEntryMode=1"
- Artifacts: /research/strategies/m1_tick_hunter_backtest/ (report, metrics, compile log)
- Trade list: TRADE_LEVEL_FORENSICS.csv (this folder)
- Engine untouched: f12858e4...

## VERDICT
The failure is structural: (a) SL at entry pays the spread 34x, (b) over-trading burst, (c) balance-scaled risk gate chokes the EA to silence after -72.5%. Even fixing all three, the 26-pt spread vs sub-26-pt predictable moves makes a positive expectancy impossible on $10/0.01 lot. The qualitative leap requires a **<=10-pt spread account** or **external data (DXY/silver/news)** - not more code on the same feed.
