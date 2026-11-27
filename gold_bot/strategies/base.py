"""Shared context for the 32-strategy engine (all values strictly causal)."""
from __future__ import annotations

import math
from typing import Optional

import config


def _num(value) -> Optional[float]:
    try:
        f = float(value)
        return f if math.isfinite(f) else None
    except (TypeError, ValueError):
        return None


def _last(frame, col, off=-1):
    if frame is None or col not in getattr(frame, "columns", []) or len(frame) < abs(off):
        return None
    return _num(frame[col].iloc[off])


def _zone(frame, flag, n=10):
    if frame is None or flag not in getattr(frame, "columns", []) or "high" not in frame.columns:
        return None
    for _, row in frame.tail(n).iloc[::-1].iterrows():
        try:
            if int(row[flag]) == 1:
                return float(row["high"]), float(row["low"])
        except (TypeError, ValueError):
            continue
    return None


class Ctx:
    def __init__(self, df, m5=None, m15=None):
        self.df, self.m5, self.m15 = df, m5, m15
        self.close = _last(df, "close")
        self.open_ = _last(df, "open")
        self.high = _last(df, "high")
        self.low = _last(df, "low")
        self.atr = _last(df, "atr_14")
        self.atr_points = _last(df, "atr_points")
        self.atr_ma_20 = _last(df, "atr_ma_20")
        self.rsi = _last(df, "rsi_7")
        self.adx = _last(df, "adx_14")
        self.vol = _last(df, "tick_volume")
        self.vol_ma = _last(df, "vol_ma_10")
        self.ema5 = _last(df, "ema_5")
        self.ema9 = _last(df, "ema_9")
        self.ema13 = _last(df, "ema_13")
        self.ema21 = _last(df, "ema_21")
        self.ema50 = _last(df, "ema_50")
        self.macd_hist = _last(df, "macd_hist")
        self.macd_hist_prev = _last(df, "macd_hist", -2)
        self.stoch_k = _last(df, "stoch_k")
        self.stoch_d = _last(df, "stoch_d")
        self.st_dir = _last(df, "supertrend_dir")
        self.st_dir_prev = _last(df, "supertrend_dir", -2)
        self.bb_up = _last(df, "bb_upper")
        self.bb_lo = _last(df, "bb_lower")
        self.kelt_up = _last(df, "keltner_upper")
        self.kelt_lo = _last(df, "keltner_lower")
        self.vwap_up = _last(df, "vwap_upper")
        self.vwap_lo = _last(df, "vwap_lower")
        self.pivot_p = _last(df, "pivot_p")
        self.pivot_r1 = _last(df, "pivot_r1")
        self.pivot_s1 = _last(df, "pivot_s1")
        self.obv = _last(df, "obv")
        self.obv_prev = _last(df, "obv", -2)
        self.swing_hi = _last(df, "swing_high_15")
        self.swing_lo = _last(df, "swing_low_15")
        self.swing_hi20 = _last(df, "swing_high_20")
        self.swing_lo20 = _last(df, "swing_low_20")
        self.inside_bar = _last(df, "inside_bar")
        self.asian_hi = _last(df, "asian_high")
        self.asian_lo = _last(df, "asian_low")
        self.prev_high = _last(df, "high", -2)
        self.prev_low = _last(df, "low", -2)
        self.prev_close = _last(df, "close", -2)
        self.fvg_bull = _zone(df, "fvg_bull")
        self.fvg_bear = _zone(df, "fvg_bear")
        self.ob_bull = _zone(df, "order_block_bull")
        self.ob_bear = _zone(df, "order_block_bear")

        self.m5_close = _last(m5, "close")
        self.m5_ema21 = _last(m5, "m5_ema_21")
        self.m5_ema50 = _last(m5, "m5_ema_50")
        self.m5_adx = _last(m5, "m5_adx_14")
        self.m5_slope = _last(m5, "m5_ema21_slope")
        self.m5_vwap_up = _last(m5, "m5_vwap_upper")
        self.m5_vwap_lo = _last(m5, "m5_vwap_lower")
        self.m5_sw_hi = _last(m5, "swing_high_20")
        self.m5_sw_lo = _last(m5, "swing_low_20")
        self.m5_st_dir = _last(m5, "supertrend_dir")
        self.m5_inside = _last(m5, "inside_bar")
        self.m5_ob_bull = _zone(m5, "order_block_bull") or _zone(m5, "m5_ob_bull")
        self.m5_ob_bear = _zone(m5, "order_block_bear") or _zone(m5, "m5_ob_bear")
        self.m5_fvg_bull = _zone(m5, "fvg_bull")
        self.m5_fvg_bear = _zone(m5, "fvg_bear")

        self.m15_ema21 = _last(m15, "ema_21")
        self.m15_ema50 = _last(m15, "ema_50")
        self.m15_adx = _last(m15, "adx_14")
        self.m15_rsi = _last(m15, "rsi_7")
        self.m15_sw_hi = _last(m15, "swing_high_12")
        self.m15_sw_lo = _last(m15, "swing_low_12")
        self.m15_st_dir = _last(m15, "supertrend_dir")
        self.m15_ob_bull = _zone(m15, "order_block_bull", 6)
        self.m15_ob_bear = _zone(m15, "order_block_bear", 6)
        self.m15_fvg_bull = _zone(m15, "fvg_bull", 6)
        self.m15_fvg_bear = _zone(m15, "fvg_bear", 6)

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
