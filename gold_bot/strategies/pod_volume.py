"""Pod 4 - volume / order-flow anomalies (5 strategies)."""


def tick_volume_climax_absorption(c):
    if c.rsi is None or c.range <= 0 or not c.vol_ok(2.2):
        return None
    if c.body < 0.35 * c.range and c.wick_low >= 0.4 * c.range and c.rsi < 40:
        return c.cand("TickVolume_ClimaxAbsorption", "BUY", 0.67)
    if c.body < 0.35 * c.range and c.wick_high >= 0.4 * c.range and c.rsi > 60:
        return c.cand("TickVolume_ClimaxAbsorption", "SELL", 0.67)
    return None


def volume_weighted_impulse_limit(c):
    if c.body <= 1.3 * c.atr or not c.vol_ok(1.5):
        return None
    if c.close > c.open_ and c.m5_up:
        return c.cand("VolumeWeighted_ImpulseLimit", "BUY", 0.69, "LIMIT")
    if c.close < c.open_ and c.m5_dn:
        return c.cand("VolumeWeighted_ImpulseLimit", "SELL", 0.69, "LIMIT")
    return None


def obv_divergence_snap(c):
    if None in (c.obv, c.obv_prev, c.prev_close, c.rsi):
        return None
    if c.close < c.prev_close and c.obv > c.obv_prev and c.close > c.open_ and c.rsi < 40:
        return c.cand("OBV_DivergenceSnap", "BUY", 0.65)
    if c.close > c.prev_close and c.obv < c.obv_prev and c.close < c.open_ and c.rsi > 60:
        return c.cand("OBV_DivergenceSnap", "SELL", 0.65)
    return None


def effort_vs_result_anomaly(c):
    if c.range <= 0 or not c.vol_ok(2.0):
        return None
    if c.body < 0.25 * c.range and c.wick_low >= 0.4 * c.range:
        return c.cand("EffortVsResult_Anomaly", "BUY", 0.64)
    if c.body < 0.25 * c.range and c.wick_high >= 0.4 * c.range:
        return c.cand("EffortVsResult_Anomaly", "SELL", 0.64)
    return None


def tick_velocity_breakout(c):
    if c.range <= 0 or not c.vol_ok(1.8):
        return None
    if c.close >= c.low + 0.8 * c.range and c.m5_up and (c.m5_slope or 0) > 0:
        return c.cand("TickVelocity_Breakout", "BUY", 0.68, "LIMIT")
    if c.close <= c.low + 0.2 * c.range and c.m5_dn and (c.m5_slope or 0) < 0:
        return c.cand("TickVelocity_Breakout", "SELL", 0.68, "LIMIT")
    return None


STRATEGIES = [
    ("TickVolume_ClimaxAbsorption", tick_volume_climax_absorption),
    ("VolumeWeighted_ImpulseLimit", volume_weighted_impulse_limit),
    ("OBV_DivergenceSnap", obv_divergence_snap),
    ("EffortVsResult_Anomaly", effort_vs_result_anomaly),
    ("TickVelocity_Breakout", tick_velocity_breakout),
]
