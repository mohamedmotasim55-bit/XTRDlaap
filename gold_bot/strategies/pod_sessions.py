"""Pod 6 - session timing / compression breakouts (5 strategies)."""


def london_open_liquidity_burst(c):
    if c.hf is None or not (8.0 <= c.hf < 10.5) or c.range <= 1.5 * c.atr:
        return None
    if c.m5_up and c.close > c.open_:
        return c.cand("LondonOpen_LiquidityBurst", "BUY", 0.69, "LIMIT")
    if c.m5_dn and c.close < c.open_:
        return c.cand("LondonOpen_LiquidityBurst", "SELL", 0.69, "LIMIT")
    return None


def ny_open_comex_surge(c):
    if c.hf is None or not (13.5 <= c.hf < 16.5) or c.range <= 1.5 * c.atr:
        return None
    if c.m5_up and c.close > c.open_:
        return c.cand("NYOpen_COMEX_Surge", "BUY", 0.70, "LIMIT")
    if c.m5_dn and c.close < c.open_:
        return c.cand("NYOpen_COMEX_Surge", "SELL", 0.70, "LIMIT")
    return None


def london_fix_mean_reversion(c):
    if c.hf is None or not (15.75 <= c.hf < 17.5) or c.m15_rsi is None:
        return None
    if c.m15_rsi > 78 and c.close < c.open_:
        return c.cand("LondonFix_MeanReversion", "SELL", 0.66)
    if c.m15_rsi < 22 and c.close > c.open_:
        return c.cand("LondonFix_MeanReversion", "BUY", 0.66)
    return None


def inside_bar_compression_break(c):
    if not c.inside_bar or c.prev_high is None or c.prev_low is None:
        return None
    if c.m15_up and c.close > c.prev_high:
        return c.cand("InsideBar_CompressionBreak", "BUY", 0.67, "LIMIT")
    if c.m15_dn and c.close < c.prev_low:
        return c.cand("InsideBar_CompressionBreak", "SELL", 0.67, "LIMIT")
    return None


def m15_key_level_pin_bar(c):
    if c.range <= 0:
        return None
    if c.m15_sw_lo is not None and c.low <= c.m15_sw_lo \
            and c.wick_low >= 0.6 * c.range and c.close > c.open_:
        return c.cand("M15_KeyLevel_PinBar", "BUY", 0.68)
    if c.m15_sw_hi is not None and c.high >= c.m15_sw_hi \
            and c.wick_high >= 0.6 * c.range and c.close < c.open_:
        return c.cand("M15_KeyLevel_PinBar", "SELL", 0.68)
    return None


STRATEGIES = [
    ("LondonOpen_LiquidityBurst", london_open_liquidity_burst),
    ("NYOpen_COMEX_Surge", ny_open_comex_surge),
    ("LondonFix_MeanReversion", london_fix_mean_reversion),
    ("InsideBar_CompressionBreak", inside_bar_compression_break),
    ("M15_KeyLevel_PinBar", m15_key_level_pin_bar),
]
