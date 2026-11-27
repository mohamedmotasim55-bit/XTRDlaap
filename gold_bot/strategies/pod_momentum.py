"""Pod 1 - momentum / continuation (6 strategies)."""


def m1_m5_momentum_limit(c):
    if c.m5_adx is None or c.m5_adx <= 22 or c.body <= 1.2 * c.atr:
        return None
    if not c.vol_ok(1.3):
        return None
    if c.m15_up and c.m5_up and c.close > c.open_:
        return c.cand("M1_M5_MomentumLimit", "BUY", 0.72, "LIMIT")
    if c.m15_dn and c.m5_dn and c.close < c.open_:
        return c.cand("M1_M5_MomentumLimit", "SELL", 0.72, "LIMIT")
    return None


def m15_trend_pullback_limit(c):
    if c.ema21 is None or c.atr is None:
        return None
    if c.m15_up and c.low <= c.ema21 and c.close > c.ema21 and c.close > c.open_:
        return c.cand("M15_TrendPullbackLimit", "BUY", 0.68, "LIMIT")
    if c.m15_dn and c.high >= c.ema21 and c.close < c.ema21 and c.close < c.open_:
        return c.cand("M15_TrendPullbackLimit", "SELL", 0.68, "LIMIT")
    return None


def macd_zero_line_burst(c):
    if c.macd_hist is None or c.macd_hist_prev is None:
        return None
    if c.m5_adx is None or c.m5_adx <= 22:
        return None
    if c.macd_hist > 0 >= c.macd_hist_prev and c.close > c.open_:
        return c.cand("MACD_ZeroLineBurst", "BUY", 0.66, "LIMIT")
    if c.macd_hist < 0 <= c.macd_hist_prev and c.close < c.open_:
        return c.cand("MACD_ZeroLineBurst", "SELL", 0.66, "LIMIT")
    return None


def adx_volatility_breakout(c):
    if c.adx is None or c.adx <= 28 or c.range <= 1.4 * c.atr:
        return None
    if c.close > c.open_ and c.m5_up:
        return c.cand("ADX_VolatilityBreakout", "BUY", 0.69, "LIMIT")
    if c.close < c.open_ and c.m5_dn:
        return c.cand("ADX_VolatilityBreakout", "SELL", 0.69, "LIMIT")
    return None


def dual_supertrend_flip(c):
    if None in (c.st_dir, c.st_dir_prev, c.m5_st_dir):
        return None
    if c.m5_st_dir > 0 and c.st_dir > 0 >= c.st_dir_prev:
        return c.cand("DualSuperTrendFlip", "BUY", 0.70, "LIMIT")
    if c.m5_st_dir < 0 and c.st_dir < 0 <= c.st_dir_prev:
        return c.cand("DualSuperTrendFlip", "SELL", 0.70, "LIMIT")
    return None


def triple_ema_ribbon_surge(c):
    if None in (c.ema5, c.ema13, c.ema21) or not c.vol_ok(1.3):
        return None
    if c.ema5 > c.ema13 > c.ema21 and c.close > c.open_:
        return c.cand("TripleEMARibbonSurge", "BUY", 0.67, "LIMIT")
    if c.ema5 < c.ema13 < c.ema21 and c.close < c.open_:
        return c.cand("TripleEMARibbonSurge", "SELL", 0.67, "LIMIT")
    return None


STRATEGIES = [
    ("M1_M5_MomentumLimit", m1_m5_momentum_limit),
    ("M15_TrendPullbackLimit", m15_trend_pullback_limit),
    ("MACD_ZeroLineBurst", macd_zero_line_burst),
    ("ADX_VolatilityBreakout", adx_volatility_breakout),
    ("DualSuperTrendFlip", dual_supertrend_flip),
    ("TripleEMARibbonSurge", triple_ema_ribbon_surge),
]
