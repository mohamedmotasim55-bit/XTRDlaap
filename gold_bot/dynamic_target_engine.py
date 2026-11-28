"""Dynamic SL/TP calibrated for medium and explosive Gold waves.

SL: clamp(0.58 * ATR, 55, 74) pts -> max $0.74 risk per 0.01 lot.
TP: 145-420 pts, scaled by pulse intensity, M5 ADX and ATR expansion,
    while keeping Reward/Risk inside 2.4x-5.5x.
"""
from __future__ import annotations

import config


def _clamp(x, lo, hi):
    return max(lo, min(hi, x))


def select_targets(pulse_intensity, atr_points, m5_adx=0.0, atr_ratio=1.0,
                   m5_aligned=False, consensus=0, momentum=False) -> dict:
    pulse = _clamp(float(pulse_intensity or 0.0), 1.0, 4.0)
    atr_points = float(atr_points or 0.0)
    sl = _clamp(0.58 * atr_points, 55.0, 74.0)

    pulse_s = _clamp((pulse - 1.45) / 1.55, 0.0, 1.0)
    adx_s = _clamp((float(m5_adx or 0.0) - 21.0) / 20.0, 0.0, 1.0)
    atr_s = _clamp((float(atr_ratio or 1.0) - 0.9) / 0.6, 0.0, 1.0)
    mix = 0.5 * pulse_s + 0.3 * adx_s + 0.2 * atr_s

    tp = 145.0 + 275.0 * mix
    if m5_aligned:
        tp += 15.0
    if consensus >= 3:
        tp += 15.0

    tp = _clamp(tp, 145.0, 420.0)
    tp = max(tp, 2.4 * sl)
    tp = min(tp, 5.5 * sl, 420.0)

    tier = "T1" if tp < 220.0 else ("T2" if tp < 320.0 else "T3")
    return dict(tier=tier, score=round(_clamp(mix, 0.0, 1.0), 4),
                consensus=int(consensus), tp_points=round(tp, 1),
                sl_points=round(sl, 1), be_trigger=38.0, be_lock=12.0,
                trail_start=65.0, max_hold_minutes=config.MAX_SCALP_HOLD_MINUTES)
