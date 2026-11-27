"""Shared context for the 32-strategy engine (all values strictly causal)."""
from __future__ import annotations

import math
from typing import Optional

import numpy as np


def _num(value) -> Optional[float]:
    try:
        f = float(value)
        return f if math.isfinite(f) else None
    except (TypeError, ValueError):
        return None


_ROW_CACHE = {}


def _row_dict(frame):
    if frame is None or not len(frame):
        return None
    key = (id(frame), len(frame))
    cached = _ROW_CACHE.get(key)
    if cached is not None:
        return cached
    if len(_ROW_CACHE) > 6:
        _ROW_CACHE.clear()
    d = frame.iloc[-1].to_dict()
    _ROW_CACHE[key] = d
    return d


def _zone(frame, flag, n=10):
    if frame is None or flag not in getattr(frame, "columns", []) or "high" not in frame.columns:
        return None
    tail = frame[flag].tail(n).to_numpy()
    hits = np.nonzero(tail == 1)[0]
    if not len(hits):
        return None
    pos = len(frame) - 1 - (len(tail) - 1 - int(hits[-1]))
    return float(frame["high"].iloc[pos]), float(frame["low"].iloc[pos])


class Ctx:
    def __init__(self, df, m5=None, m15=None):
        self.df, self.m5, self.m15 = df, m5, m15
        lr = _row_dict(df)
        pr = df.iloc[-2].to_dict() if df is not None and len(df) > 1 else None

        def g(col):
            return _num(lr.get(col)) if lr is not None else None

        def gp(col):
            return _num(pr.get(col)) if pr is not None else None

        self.close = g("close")
        self.open_ = g("open")
        self.high = g("high")
        self.low = g("low")
        self.atr = g("atr_14")
        self.atr_points = g("atr_points")
        self.atr_ma_20 = g("atr_ma_20")
        self.rsi = g("rsi_7")
        self.adx = g("adx_14")
        self.vol = g("tick_volume")
        self.vol_ma = g("vol_ma_10")
        self.ema5 = g("ema_5")
        self.ema9 = g("ema_9")
        self.ema13 = g("ema_13")
        self.ema21 = g("ema_21")
        self.ema50 = g("ema_50")
        self.macd_hist = g("macd_hist")
        self.macd_hist_prev = gp("macd_hist")
        self.stoch_k = g("stoch_k")
        self.stoch_d = g("stoch_d")
        self.st_dir = g("supertrend_dir")
        self.st_dir_prev = gp("supertrend_dir")
        self.bb_up = g("bb_upper")
        self.bb_lo = g("bb_lower")
        self.kelt_up = g("keltner_upper")
        self.kelt_lo = g("keltner_lower")
        self.vwap_up = g("vwap_upper")
        self.vwap_lo = g("vwap_lower")
        self.pivot_p = g("pivot_p")
        self.pivot_r1 = g("pivot_r1")
        self.pivot_s1 = g("pivot_s1")
        self.obv = g("obv")
        self.obv_prev = gp("obv")
        self.swing_hi = g("swing_high_15")
        self.swing_lo = g("swing_low_15")
        self.swing_hi20 = g("swing_high_20")
        self.swing_lo20 = g("swing_low_20")
        self.inside_bar = g("inside_bar")
        self.asian_hi = g("asian_high")
        self.asian_lo = g("asian_low")
        self.prev_high = gp("high")
        self.prev_low = gp("low")
        self.prev_close = gp("close")
        self.fvg_bull = self._lvl(g, "fvg_bull") or _zone(df, "fvg_bull")
        self.fvg_bear = self._lvl(g, "fvg_bear") or _zone(df, "fvg_bear")
        self.ob_bull = self._lvl(g, "order_block_bull") or _zone(df, "order_block_bull")
        self.ob_bear = self._lvl(g, "order_block_bear") or _zone(df, "order_block_bear")

        m5r = _row_dict(m5)
        m15r = _row_dict(m15)

        def g5(col):
            return _num(m5r.get(col)) if m5r is not None else None

        def g15(col):
            return _num(m15r.get(col)) if m15r is not None else None

        self.m5_close = g5("close")
        self.m5_ema21 = g5("m5_ema_21")
        self.m5_ema50 = g5("m5_ema_50")
        self.m5_adx = g5("m5_adx_14")
        self.m5_slope = g5("m5_ema21_slope")
        self.m5_vwap_up = g5("m5_vwap_upper")
        self.m5_vwap_lo = g5("m5_vwap_lower")
        self.m5_sw_hi = g5("swing_high_20")
        self.m5_sw_lo = g5("swing_low_20")
        self.m5_st_dir = g5("supertrend_dir")
        self.m5_inside = g5("inside_bar")
        self.m5_ob_bull = self._lvl(g5, "order_block_bull") or _zone(m5, "order_block_bull") or _zone(m5, "m5_ob_bull")
        self.m5_ob_bear = self._lvl(g5, "order_block_bear") or _zone(m5, "order_block_bear") or _zone(m5, "m5_ob_bear")
        self.m5_fvg_bull = self._lvl(g5, "fvg_bull") or _zone(m5, "fvg_bull")
        self.m5_fvg_bear = self._lvl(g5, "fvg_bear") or _zone(m5, "fvg_bear")

        self.m15_ema21 = g15("ema_21")
        self.m15_ema50 = g15("ema_50")
        self.m15_adx = g15("adx_14")
        self.m15_rsi = g15("rsi_7")
        self.m15_sw_hi = g15("swing_high_12")
        self.m15_sw_lo = g15("swing_low_12")
        self.m15_st_dir = g15("supertrend_dir")
        self.m15_ob_bull = self._lvl(g15, "order_block_bull") or _zone(m15, "order_block_bull", 6)
        self.m15_ob_bear = self._lvl(g15, "order_block_bear") or _zone(m15, "order_block_bear", 6)
        self.m15_fvg_bull = self._lvl(g15, "fvg_bull") or _zone(m15, "fvg_bull", 6)
        self.m15_fvg_bear = self._lvl(g15, "fvg_bear") or _zone(m15, "fvg_bear", 6)

        self.range = (self.high - self.low) if None not in (self.high, self.low) else 0.0
        self.body = abs(self.close - self.open_) if None not in (self.close, self.open_) else 0.0
        self.wick_low = ((min(self.open_, self.close) - self.low)
                         if None not in (self.open_, self.close, self.low) else 0.0)
        self.wick_high = ((self.high - max(self.open_, self.close))
                          if None not in (self.open_, self.close, self.high) else 0.0)
        self.point = (self.atr / self.atr_points) if (self.atr and self.atr_points) else 0.01

        self.m1_up = None not in (self.ema9, self.ema21) and self.ema9 > self.ema21
        self.m1_dn = None not in (self.ema9, self.ema21) and self.ema9 < self.ema21
        self.m5_up = None not in (self.m5_close, self.m5_ema21) and self.m5_close > self.m5_ema21
        self.m5_dn = None not in (self.m5_close, self.m5_ema21) and self.m5_close < self.m5_ema21
        self.m15_up = None not in (self.m15_ema21, self.m15_ema50) and self.m15_ema21 > self.m15_ema50
        self.m15_dn = None not in (self.m15_ema21, self.m15_ema50) and self.m15_ema21 < self.m15_ema50

        self.hf = None
        if df is not None and "time" in df.columns and len(df):
            try:
                ts = df["time"].iloc[-1]
                self.hf = ts.hour + ts.minute / 60.0
            except (AttributeError, TypeError, ValueError):
                self.hf = None

        self.atr_ratio = ((self.atr / self.atr_ma_20)
                          if (self.atr and self.atr_ma_20) else 0.0)
        self.vol_ratio = ((self.vol / self.vol_ma)
                          if (self.vol and self.vol_ma) else 0.0)

    @staticmethod
    def _lvl(getter, flag):
        hi = getter(flag + "_hi")
        lo = getter(flag + "_lo")
        return (hi, lo) if hi is not None and lo is not None else None

    def micro_limit(self, direction):
        if not self.point:
            return 0.0
        off = min(16.0, max(12.0, 0.35 * self.range / self.point))
        return (self.close - off * self.point if direction == "BUY"
                else self.close + off * self.point)

    def cand(self, name, direction, confidence, entry_type="MARKET"):
        return dict(direction=direction, strategy=name, entry=round(self.close, 5),
                    confidence=round(confidence, 3), entry_type=entry_type,
                    limit_price=round(self.micro_limit(direction), 5)
                    if entry_type == "LIMIT" else 0.0)

    def vol_ok(self, mult=1.0):
        return self.vol is not None and self.vol_ma is not None and self.vol > mult * self.vol_ma
