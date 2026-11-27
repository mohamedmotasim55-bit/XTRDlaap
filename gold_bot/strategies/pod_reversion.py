"""Pod 5 - mean reversion / exhaustion (5 strategies)."""


def m5_vwap_elastic_snap(c):
    if c.rsi is None or c.m15_adx is None or c.m15_adx >= 22 or c.m5_vwap_lo is None:
        return None
    if c.low <= c.m5_vwap_lo and c.rsi < 35 and c.close > c.open_:
        return c.cand("M5_VWAP_ElasticSnap", "BUY", 0.67)
    if c.m5_vwap_up is not None and c.high >= c.m5_vwap_up and c.rsi > 65 and c.close < c.open_:
        return c.cand("M5_VWAP_ElasticSnap", "SELL", 0.67)
    return None


def daily_pivot_s1r1_bounce(c):
    if c.rsi is None:
        return None
    if c.pivot_s1 is not None and c.low <= c.pivot_s1 and c.close > c.pivot_s1 and c.rsi < 30:
        return c.cand("DailyPivot_S1R1_Bounce", "BUY", 0.66)
    if c.pivot_r1 is not None and c.high >= c.pivot_r1 and c.close < c.pivot_r1 and c.rsi > 70:
        return c.cand("DailyPivot_S1R1_Bounce", "SELL", 0.66)
    return None


def keltner_channel_exhaustion(c):
    if c.rsi is None or c.kelt_lo is None:
        return None
    if c.low <= c.kelt_lo and c.rsi < 25 and c.close > c.open_:
        return c.cand("KeltnerChannel_Exhaustion", "BUY", 0.66)
    if c.kelt_up is not None and c.high >= c.kelt_up and c.rsi > 75 and c.close < c.open_:
        return c.cand("KeltnerChannel_Exhaustion", "SELL", 0.66)
    return None


def double_oscillator_snapback(c):
    if None in (c.rsi, c.stoch_k, c.stoch_d):
        return None
    if c.rsi < 25 and c.stoch_k < 20 and c.stoch_k > c.stoch_d:
        return c.cand("DoubleOscillator_Snapback", "BUY", 0.68)
    if c.rsi > 75 and c.stoch_k > 80 and c.stoch_k < c.stoch_d:
        return c.cand("DoubleOscillator_Snapback", "SELL", 0.68)
    return None


def flat_range_bollinger_sniper(c):
    if c.rsi is None or c.adx is None or c.m5_adx is None:
        return None
    if not (c.m5_adx < 19 and c.adx < 21) or c.range <= 0:
        return None
    if c.low <= c.bb_lo and c.rsi < 24 and c.close > c.open_ \
            and c.wick_low >= 0.42 * c.range:
        return c.cand("FlatRange_BollingerSniper", "BUY", 0.66)
    if c.high >= c.bb_up and c.rsi > 76 and c.close < c.open_ \
            and c.wick_high >= 0.42 * c.range:
        return c.cand("FlatRange_BollingerSniper", "SELL", 0.66)
    return None


STRATEGIES = [
    ("M5_VWAP_ElasticSnap", m5_vwap_elastic_snap),
    ("DailyPivot_S1R1_Bounce", daily_pivot_s1r1_bounce),
    ("KeltnerChannel_Exhaustion", keltner_channel_exhaustion),
    ("DoubleOscillator_Snapback", double_oscillator_snapback),
    ("FlatRange_BollingerSniper", flat_range_bollinger_sniper),
]
