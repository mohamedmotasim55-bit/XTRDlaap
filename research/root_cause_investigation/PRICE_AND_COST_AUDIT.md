# Price and Cost Audit

## Confirmed XAUUSD.m spec (from MT5, PHASE0)
- point=0.01 | contract=100.0 oz | tick_value=$1.0/pt/lot | lot=0.01 => **$0.01/pt**
- spread median=26.0 pts = $0.26 = 2.6% of $10.0
- 1 pt = 0.01 USD (0.01 lot). 26 pts = $0.26.

## Spread verification (entry_ask - entry_bid vs logged spread_pts)
- rows checked: 257722 | mismatches >0.6pt: 0 | max diff: 0.00 pt

## Double-charge check
- Net computed as (exit_bid - entry_ask) for BUY and (entry_bid - exit_ask) for SELL.
- This already contains the spread exactly once. No extra spread subtracted.

## Verdict
- Point/dollar conversion: **Correct** (no x10/x100/x1000 error).
- Spread counted once: **Correct**.
