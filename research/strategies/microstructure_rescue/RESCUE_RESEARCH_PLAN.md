# Rescue Research Plan
Capital fixed 10 USD. XAUUSD.m JustMarkets Standard. No trading.

## Problem
Phase-1/2 showed sub-second imbalance has real directional info but predictable move (~2-25 pts) < spread (~26 pts). Mean-based tests all negative.

## New angles tested here
A. Longer horizons (30/60/120/300s) - does drift accumulate above cost?
B. Delayed entry (+1s/+5s) - does waiting improve executable price?
C. First-passage T/S (2:1, 3:1, 3:2) - does a skewed payoff capture fat tails profitably even if mean is small?
D. Regime interaction (vol x rate) x strong imbalance.
E. Cost/latency stress.

## Method
Discovery/Validation/OOS 60/20/20, 300s embargo, block bootstrap, per-cell n and CI. No OOS tuning.
