"""Pod 2 - liquidity sweeps / stop hunts (6 strategies)."""


def m15_swing_liquidity_sweep(c):
    if c.m15_sw_lo is not None and c.low < c.m15_sw_lo and c.close > c.m15_sw_lo \
            and c.wick_low >= 0.45 * c.range:
        return c.cand("M15_SwingLiquiditySweep", "BUY", 0.70)
    if c.m15_sw_hi is not None and c.high > c.m15_sw_hi and c.close < c.m15_sw_hi \
            and c.wick_high >= 0.45 * c.range:
        return c.cand("M15_SwingLiquiditySweep", "SELL", 0.70)
    return None


def m5_swing_liquidity_sweep(c):
    if c.m5_sw_lo is not None and c.low < c.m5_sw_lo and c.close > c.m5_sw_lo \
            and c.wick_low >= 0.45 * c.range:
        return c.cand("M5_SwingLiquiditySweep", "BUY", 0.69)
    if c.m5_sw_hi is not None and c.high > c.m5_sw_hi and c.close < c.m5_sw_hi \
            and c.wick_high >= 0.45 * c.range:
        return c.cand("M5_SwingLiquiditySweep", "SELL", 0.69)
    return None


def m1_micro_stop_hunt(c):
    if c.rsi is None:
        return None
    if c.swing_lo is not None and c.low < c.swing_lo and c.close > c.swing_lo \
            and c.wick_low >= 0.5 * c.range and c.rsi < 35:
        return c.cand("M1_MicroStopHunt", "BUY", 0.67)
    if c.swing_hi is not None and c.high > c.swing_hi and c.close < c.swing_hi \
            and c.wick_high >= 0.5 * c.range and c.rsi > 65:
        return c.cand("M1_MicroStopHunt", "SELL", 0.67)
    return None


def equal_highs_lows_raid(c):
    if None in (c.swing_hi, c.swing_hi20, c.swing_lo, c.swing_lo20) or c.atr <= 0:
        return None
    if abs(c.swing_hi - c.swing_hi20) <= 0.15 * c.atr \
            and c.high > max(c.swing_hi, c.swing_hi20) and c.close < c.swing_hi:
        return c.cand("EqualHighsLows_Raid", "SELL", 0.66)
    if abs(c.swing_lo - c.swing_lo20) <= 0.15 * c.atr \
            and c.low < min(c.swing_lo, c.swing_lo20) and c.close > c.swing_lo:
        return c.cand("EqualHighsLows_Raid", "BUY", 0.66)
    return None


def asian_range_sweep_reverse(c):
    if c.hf is None or not (8.0 <= c.hf < 12.0):
        return None
    if c.asian_lo is not None and c.low < c.asian_lo and c.close > c.asian_lo:
        return c.cand("AsianRange_SweepReverse", "BUY", 0.68)
    if c.asian_hi is not None and c.high > c.asian_hi and c.close < c.asian_hi:
        return c.cand("AsianRange_SweepReverse", "SELL", 0.68)
    return None


def dual_wick_rejection_trap(c):
    if c.m15_sw_lo is not None and c.low <= c.m15_sw_lo \
            and c.wick_low >= 0.5 * c.range and c.close > c.open_:
        return c.cand("DualWick_RejectionTrap", "BUY", 0.66)
    if c.m15_sw_hi is not None and c.high >= c.m15_sw_hi \
            and c.wick_high >= 0.5 * c.range and c.close < c.open_:
        return c.cand("DualWick_RejectionTrap", "SELL", 0.66)
    return None


STRATEGIES = [
    ("M15_SwingLiquiditySweep", m15_swing_liquidity_sweep),
    ("M5_SwingLiquiditySweep", m5_swing_liquidity_sweep),
    ("M1_MicroStopHunt", m1_micro_stop_hunt),
    ("EqualHighsLows_Raid", equal_highs_lows_raid),
    ("AsianRange_SweepReverse", asian_range_sweep_reverse),
    ("DualWick_RejectionTrap", dual_wick_rejection_trap),
]
