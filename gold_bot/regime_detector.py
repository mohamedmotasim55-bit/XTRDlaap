"""
regime_detector.py
==================
Market Regime Classifier.

Analyses M1 + optional M5 indicators and classifies the live market into one
of four regimes:

    STRONG_TREND_UP    ADX > 25, EMA21 > EMA50, M5 trend up
    STRONG_TREND_DOWN  ADX > 25, EMA21 < EMA50, M5 trend down
    VOLATILE_BREAKOUT  ATR spike (> ATR_SPIKE_FACTOR * recent average)
    RANGING_CHOP       ADX <= 25 and/or no trend alignment
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

import pandas as pd

import config

REGIME_TREND_UP = "STRONG_TREND_UP"
REGIME_TREND_DOWN = "STRONG_TREND_DOWN"
REGIME_VOLATILE = "VOLATILE_BREAKOUT"
REGIME_RANGING = "RANGING_CHOP"


@dataclass
class Regime:
    regime: str = REGIME_RANGING
    adx: float = 0.0
    bb_width: float = 0.0
    atr_points: float = 0.0
    atr_avg_points: float = 0.0
    m5_trend_up: bool = True
    reason: str = ""

    @property
    def is_trending(self) -> bool:
        return self.regime in (REGIME_TREND_UP, REGIME_TREND_DOWN)


class RegimeDetector:
    @staticmethod
    def _last(df: pd.DataFrame, col: str) -> Optional[float]:
        try:
            v = float(df[col].iloc[-1])
            return v if v == v else None  # NaN check
        except (KeyError, IndexError, TypeError, ValueError):
            return None

    @classmethod
    def classify(cls, df: pd.DataFrame, df_m5: Optional[pd.DataFrame] = None) -> Regime:
        r = Regime()
        if df is None or len(df) < 20:
            r.reason = "insufficient data"
            return r

        adx = cls._last(df, "adx_14")
        bb_width = cls._last(df, "bb_width")
        atr_points = cls._last(df, "atr_points")
        ema21 = cls._last(df, "ema_21")
        ema50 = cls._last(df, "ema_50")

        r.adx = adx or 0.0
        r.bb_width = bb_width or 0.0
        r.atr_points = atr_points or 0.0
        try:
            r.atr_avg_points = float(df["atr_points"].tail(20).mean())
        except (KeyError, TypeError, ValueError):
            r.atr_avg_points = 0.0

        m5_up = True
        if df_m5 is not None and len(df_m5) >= config.EMA_SLOW:
            try:
                mc = float(df_m5["close"].iloc[-1])
                if "m5_ema_50" in df_m5.columns:
                    me = float(df_m5["m5_ema_50"].iloc[-1])
                else:
                    me = float(df_m5["close"].ewm(span=config.EMA_SLOW, adjust=False).mean().iloc[-1])
                m5_up = mc > me
            except (KeyError, IndexError, TypeError, ValueError):
                m5_up = True
        r.m5_trend_up = m5_up

        if adx is None or atr_points is None or ema21 is None or ema50 is None:
            r.reason = "missing indicators"
            return r

        # Volatility spike takes precedence.
        if r.atr_avg_points > 0 and atr_points > config.ATR_SPIKE_FACTOR * r.atr_avg_points:
            r.regime = REGIME_VOLATILE
            r.reason = "ATR spike"
            return r

        if adx > config.ADX_TREND_THRESHOLD:
            if ema21 > ema50 and m5_up:
                r.regime = REGIME_TREND_UP
                r.reason = "ADX>25 + EMA21>EMA50 + M5 up"
                return r
            if ema21 < ema50 and not m5_up:
                r.regime = REGIME_TREND_DOWN
                r.reason = "ADX>25 + EMA21<EMA50 + M5 down"
                return r

        r.regime = REGIME_RANGING
        r.reason = "ADX<=25 or no trend alignment"
        return r
