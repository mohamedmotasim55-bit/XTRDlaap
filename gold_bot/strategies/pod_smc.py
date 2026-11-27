"""Pod 3 - Smart Money Concepts / order blocks / FVG (5 strategies)."""


def m5_order_block_retest(c):
    if c.m5_ob_bull and c.low <= c.m5_ob_bull[0] and c.close > c.m5_ob_bull[0] \
            and c.close > c.open_:
        return c.cand("M5_OrderBlock_Retest", "BUY", 0.68, "LIMIT")
    if c.m5_ob_bear and c.high >= c.m5_ob_bear[1] and c.close < c.m5_ob_bear[1] \
            and c.close < c.open_:
        return c.cand("M5_OrderBlock_Retest", "SELL", 0.68, "LIMIT")
    return None


def m15_order_block_mitigation(c):
    if c.m15_ob_bull and c.low <= c.m15_ob_bull[0] and c.close > c.m15_ob_bull[0] \
            and c.close > c.open_:
        return c.cand("M15_OrderBlock_Mitigation", "BUY", 0.68, "LIMIT")
    if c.m15_ob_bear and c.high >= c.m15_ob_bear[1] and c.close < c.m15_ob_bear[1] \
            and c.close < c.open_:
        return c.cand("M15_OrderBlock_Mitigation", "SELL", 0.68, "LIMIT")
    return None


def m5_fvg_sniper_fill(c):
    if c.m15_up and c.m5_fvg_bull and c.low <= c.m5_fvg_bull[0] \
            and c.close > c.m5_fvg_bull[0] and c.close > c.open_:
        return c.cand("M5_FVG_SniperFill", "BUY", 0.67, "LIMIT")
    if c.m15_dn and c.m5_fvg_bear and c.high >= c.m5_fvg_bear[1] \
            and c.close < c.m5_fvg_bear[1] and c.close < c.open_:
        return c.cand("M5_FVG_SniperFill", "SELL", 0.67, "LIMIT")
    return None


def nested_m1_m5_fvg(c):
    if c.fvg_bull and c.m5_fvg_bull and c.close > c.open_:
        return c.cand("Nested_M1_M5_FVG", "BUY", 0.66, "LIMIT")
    if c.fvg_bear and c.m5_fvg_bear and c.close < c.open_:
        return c.cand("Nested_M1_M5_FVG", "SELL", 0.66, "LIMIT")
    return None


def breaker_block_flip(c):
    if c.swing_hi is not None and c.prev_close is not None \
            and c.prev_close < c.swing_hi <= c.close \
            and c.low <= c.swing_hi and c.close > c.swing_hi:
        return c.cand("BreakerBlock_Flip", "BUY", 0.66, "LIMIT")
    if c.swing_lo is not None and c.prev_close is not None \
            and c.prev_close > c.swing_lo >= c.close \
            and c.high >= c.swing_lo and c.close < c.swing_lo:
        return c.cand("BreakerBlock_Flip", "SELL", 0.66, "LIMIT")
    return None


STRATEGIES = [
    ("M5_OrderBlock_Retest", m5_order_block_retest),
    ("M15_OrderBlock_Mitigation", m15_order_block_mitigation),
    ("M5_FVG_SniperFill", m5_fvg_sniper_fill),
    ("Nested_M1_M5_FVG", nested_m1_m5_fvg),
    ("BreakerBlock_Flip", breaker_block_flip),
]
