# Foundation Specification

Fixed capital: **10.0 USD**. Point=0.01, contract=100.0oz, $/pt=0.01 (0.01 lot).

## Mandatory measurement rules (verified)
1. BUY: entry ask, exit bid. SELL: entry bid, exit ask. Spread counted ONCE.
2. Points = (price diff)/0.01. USD = points * 0.01 (0.01 lot).
3. MFE (BUY)=max(bid)-entry_ask; MAE (BUY)=min(bid)-entry_ask; mirrored for SELL.
4. Exit = last tick at/before horizon; never a future price; NA if no tick.
5. Cluster temporally-close same-type events; never count overlapping signals as independent.
6. Block-bootstrap CIs; multiple-testing correction; discovery/validation/OOS split.

## Acceptance gate for any future strategy
- mean NET > 0 with CI lower bound > 0 after realistic cost.
- beats fair random baseline by a statistically significant margin.
- holds out-of-sample and across sessions/regimes (n>=200 per cell).
- expected move > cost with a safety margin (e.g. MFE > 3x spread).

## Hard constraint discovered
- Spread = 26 pts = 2.6% of $10.0 per trade.
- Any strategy must target moves >> 26 pts, or costs dominate.
