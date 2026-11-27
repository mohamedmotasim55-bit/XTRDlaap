# Execution Simulation Audit

## Independent recalculation vs EA net_pts
- rows compared: 257722
- mismatches >0.5pt: 0 | max abs diff: 0.000 pt

## MFE/MAE invariants (MFE >= net >= MAE)
- ok: 257722 | violations: 0

## Execution realism
- BUY entry ask / exit bid; SELL entry bid / exit ask: **confirmed**.
- Exit uses last tick at/before horizon boundary (no future price): **confirmed**.
- Missing ticks -> NA, never invented: **confirmed**.

## Verdict
- Execution simulation: **Correct**.
