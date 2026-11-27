"""Spread-proof dynamic SL/TP for the 4 Market-Pulse engines.

SL is volatility-scaled and hard-capped at 78 pts ($0.78 on 0.01 lot) so a
$10 account never risks more than ~8%.  TP is pulse-scaled and clamped to
165-380 pts while keeping Reward/Risk inside 2.5x-4.2x.
"""
from __future__ import annotations

import config


def _clamp(x, lo, hi):
    return max(lo, min(hi, x))


def select_targets(pulse_intensity, atr_points, m5_aligned=False, consensus=0) -> dict:
    pulse = _clamp(float(pulse_intensity or 0.0), 1.0, 4.0)
    atr_points = float(atr_points or 0.0)

    sl = _clamp(0.62 * atr_points, 58.0, 78.0)

    strength = _clamp((pulse - 1.45) / 1.35, 0.0, 1.0)
    tp = 165.0 + 215.0 * strength
    if m5_aligned:
        tp += 25.0
    if consensus >= 3:
        tp += 20.0

    tp = min(tp, 380.0)
    tp = max(tp, 165.0, 2.5 * sl)
    tp = min(tp, 4.2 * sl)

    tier = "T1" if tp < 220.0 else ("T2" if tp < 300.0 else "T3")
    return dict(tier=tier, score=round(_clamp((pulse - 1.0) / 2.0, 0.0, 1.0), 4),
                consensus=int(consensus), tp_points=round(tp, 1),
                sl_points=round(sl, 1), be_trigger=42.0, be_lock=12.0,
                trail_start=75.0, max_hold_minutes=config.MAX_SCALP_HOLD_MINUTES)
