"""
dynamic_target_engine.py
========================
Indicator-driven TP/SL selector for pure M1/M5 scalping.

A 0-1 momentum score (ADX strength, ATR expansion, volume surge, triple-TF
EMA alignment) picks one of three exit tiers.  Every scalp is force-closed
after MAX_SCALP_HOLD_MINUTES so capital never sits in a stalled trade.
"""
from __future__ import annotations

import config


def _clamp01(x: float) -> float:
    return max(0.0, min(1.0, x))


def momentum_score(direction, m1_adx, m5_adx, atr_ratio, vol_ratio,
                   m1_up, m5_up, m15_up) -> float:
    adx = [v for v in (m1_adx, m5_adx) if v is not None]
    adx_avg = sum(adx) / len(adx) if adx else 0.0
    adx_s = _clamp01((adx_avg - 20.0) / 25.0)
    atr_s = _clamp01((float(atr_ratio or 0.0) - 0.8) / 0.8)
    vol_s = _clamp01((float(vol_ratio or 0.0) - 1.0) / 1.5)

    bullish = direction == "BUY"
    flags = [bool(v) == bullish for v in (m1_up, m5_up, m15_up)]
    align = sum(flags) / 3.0

    return round(_clamp01(0.30 * adx_s + 0.25 * atr_s + 0.20 * vol_s + 0.25 * align), 4)


def select_targets(score: float) -> dict:
    score = _clamp01(float(score))
    if score < 0.45:
        f = score / 0.45
        tier, tp, sl = "T1", 85.0 + f * 45.0, 55.0 + f * 15.0
        be, lock, trail = 38.0, 10.0, 65.0
    elif score <= 0.75:
        f = (score - 0.45) / 0.30
        tier, tp, sl = "T2", 150.0 + f * 100.0, 65.0 + f * 20.0
        be, lock, trail = 45.0, 12.0, 110.0
    else:
        f = (score - 0.75) / 0.25
        tier, tp, sl = "T3", 280.0 + f * 120.0, 75.0 + f * 20.0
        be, lock, trail = 55.0, 15.0, 180.0
    return dict(tier=tier, score=round(score, 4), tp_points=round(tp, 1),
                sl_points=round(sl, 1), be_trigger=be, be_lock=lock,
                trail_start=trail, max_hold_minutes=config.MAX_SCALP_HOLD_MINUTES)


def build(direction, m1_adx, m5_adx, atr_ratio, vol_ratio, m1_up, m5_up, m15_up) -> dict:
    return select_targets(momentum_score(direction, m1_adx, m5_adx, atr_ratio,
                                         vol_ratio, m1_up, m5_up, m15_up))
