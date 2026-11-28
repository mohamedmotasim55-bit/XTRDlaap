"""Institutional tick-pulse / order-flow metrics (strictly causal)."""
from __future__ import annotations

import math
from typing import Optional

import pandas as pd

PULSE_MIN_ATR_POINTS = 95.0
SESSION_START = 8.0
SESSION_END = 18.5


def _num(value) -> Optional[float]:
    try:
        f = float(value)
        return f if math.isfinite(f) else None
    except (TypeError, ValueError):
        return None


def add_pulse(df: pd.DataFrame) -> pd.DataFrame:
    """Append pulse columns to an M1/M5 frame (vectorised, no lookahead)."""
    vol = df["tick_volume"] if "tick_volume" in df.columns else pd.Series(1.0, index=df.index)
    vol_ma20 = vol.rolling(20).mean()
    df["pulse_intensity"] = (vol / vol_ma20).fillna(1.0).clip(upper=10.0)

    body = (df["close"] - df["open"]).abs()
    atr = df["atr_14"] if "atr_14" in df.columns else (df["high"] - df["low"])
    expansion = (body / atr.replace(0.0, pd.NA)).fillna(0.15).clip(lower=0.15)
    df["effort_vs_result"] = (df["pulse_intensity"] / expansion).clip(upper=40.0)

    rising = (vol > vol.shift(1)) & (vol.shift(1) > vol.shift(2))
    df["tick_accel_buy"] = (rising & (df["close"] > df["open"])).astype(int)
    df["tick_accel_sell"] = (rising & (df["close"] < df["open"])).astype(int)

    active = pd.Series(0, index=df.index)
    if "time" in df.columns:
        ts = pd.to_datetime(df["time"])
        hf = ts.dt.hour + ts.dt.minute / 60.0
        atr_ok = (df["atr_points"] >= PULSE_MIN_ATR_POINTS) if "atr_points" in df.columns else True
        active = ((hf >= SESSION_START) & (hf < SESSION_END) & atr_ok).astype(int)
    df["session_pulse_active"] = active
    return df


_ROW_CACHE = {}


def _row(frame):
    if frame is None or not len(frame):
        return None
    key = (id(frame), len(frame))
    hit = _ROW_CACHE.get(key)
    if hit is not None:
        return hit
    if len(_ROW_CACHE) > 6:
        _ROW_CACHE.clear()
    d = frame.iloc[-1].to_dict()
    _ROW_CACHE[key] = d
    return d


class PulseContext:
    """Snapshot of the last closed bar across M1/M5/M15."""

    def __init__(self, df, m5=None, m15=None):
        lr, m5r, m15r = _row(df), _row(m5), _row(m15)

        def g(col):
            return _num(lr.get(col)) if lr is not None else None

        def g5(col):
            return _num(m5r.get(col)) if m5r is not None else None

        def g15(col):
            return _num(m15r.get(col)) if m15r is not None else None

        self.close, self.open_, self.high, self.low = g("close"), g("open"), g("high"), g("low")
        self.atr, self.atr_points = g("atr_14"), g("atr_points")
        self.rsi, self.adx = g("rsi_7"), g("adx_14")
        self.vol, self.vol_ma = g("tick_volume"), g("vol_ma_10")
        self.pulse = g("pulse_intensity") or 0.0
        self.evr = g("effort_vs_result") or 0.0
        self.accel_buy, self.accel_sell = g("tick_accel_buy"), g("tick_accel_sell")
        self.session_active = bool(g("session_pulse_active"))

        self.ema9, self.ema13, self.ema21, self.ema50 = (
            g("ema_9"), g("ema_13"), g("ema_21"), g("ema_50"))
        self.bb_width_rank = g("bb_width_rank_prev")
        self.bb_up, self.bb_lo = g("bb_upper"), g("bb_lower")
        self.kelt_up, self.kelt_lo = g("keltner_upper"), g("keltner_lower")
        self.vwap_up, self.vwap_lo = g("vwap_upper"), g("vwap_lower")
        self.pivot_r1, self.pivot_s1 = g("pivot_r1"), g("pivot_s1")
        self.swing_hi, self.swing_lo = g("swing_high_15"), g("swing_low_15")

        self.m5_close, self.m5_ema21, self.m5_ema50 = g5("close"), g5("m5_ema_21"), g5("m5_ema_50")
        self.m5_adx, self.m5_slope = g5("m5_adx_14"), g5("m5_ema21_slope")
        self.m5_vwap_up, self.m5_vwap_lo = g5("m5_vwap_upper"), g5("m5_vwap_lower")
        self.m5_sw_hi, self.m5_sw_lo = g5("swing_high_20"), g5("swing_low_20")
        self.m15_close = g15("close")
        self.m15_ema21, self.m15_ema50 = g15("ema_21"), g15("ema_50")
        self.m15_adx = g15("adx_14")
        self.m15_sw_hi, self.m15_sw_lo = g15("swing_high_12"), g15("swing_low_12")
        self.h1_close, self.h1_ema50 = g15("h1_close"), g15("h1_ema_50")
        self.atr_ma_20 = g("atr_ma_20")
        self.atr_ratio = ((self.atr / self.atr_ma_20)
                          if (self.atr and self.atr_ma_20) else 1.0)

        self.range = (self.high - self.low) if None not in (self.high, self.low) else 0.0
        self.body = abs(self.close - self.open_) if None not in (self.close, self.open_) else 0.0
        self.wick_low = ((min(self.open_, self.close) - self.low)
                         if None not in (self.open_, self.close, self.low) else 0.0)
        self.wick_high = ((self.high - max(self.open_, self.close))
                          if None not in (self.open_, self.close, self.high) else 0.0)
        self.point = (self.atr / self.atr_points) if (self.atr and self.atr_points) else 0.01

        self.m5_up = None not in (self.m5_close, self.m5_ema21) and self.m5_close > self.m5_ema21
        self.m5_dn = None not in (self.m5_close, self.m5_ema21) and self.m5_close < self.m5_ema21
        self.m15_up = None not in (self.m15_ema21, self.m15_ema50) and self.m15_ema21 > self.m15_ema50
        self.m15_dn = None not in (self.m15_ema21, self.m15_ema50) and self.m15_ema21 < self.m15_ema50
        self.m5_trend_up = None not in (self.m5_ema21, self.m5_ema50) and self.m5_ema21 > self.m5_ema50
        self.m5_trend_dn = None not in (self.m5_ema21, self.m5_ema50) and self.m5_ema21 < self.m5_ema50
        self.aligned_buy = self.m5_trend_up and self.m15_up
        self.aligned_sell = self.m5_trend_dn and self.m15_dn

    def near_level(self):
        if not self.atr:
            return False
        tol = 0.6 * self.atr
        levels = [v for v in (self.swing_hi, self.swing_lo, self.m5_sw_hi, self.m5_sw_lo,
                              self.vwap_up, self.vwap_lo, self.m5_vwap_up, self.m5_vwap_lo,
                              self.pivot_r1, self.pivot_s1) if v is not None]
        return any(abs(self.close - lv) <= tol for lv in levels)

    def h1_up(self):
        if self.h1_close is not None and self.h1_ema50 is not None:
            return self.h1_close > self.h1_ema50
        return self.m15_up

    def h1_dn(self):
        if self.h1_close is not None and self.h1_ema50 is not None:
            return self.h1_close < self.h1_ema50
        return self.m15_dn

    def limit_price(self, direction, offset_points=15.0):
        if direction == "BUY":
            return round(self.close - offset_points * self.point, 5)
        return round(self.close + offset_points * self.point, 5)
