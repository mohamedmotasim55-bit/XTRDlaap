"""
indicators.py
=============
Pure pandas / numpy technical indicators — no TA-Lib dependency.

``add_indicators(df, point=0.01)`` appends these columns (and returns a copy):

    ema_9, ema_21, ema_50      exponential moving averages
    rsi_7                      fast RSI (Wilder smoothing)
    bb_mid, bb_upper,
    bb_lower, bb_width         Bollinger Bands (20, 2.0)
    atr_14                     ATR in price units (Wilder smoothing)
    atr_points                 ATR expressed in *points* (atr_14 / point)
    vol_ma_10                  10-period mean of tick_volume
    swing_high_15              highest high of the previous 15 closed candles
    swing_low_15               lowest low  of the previous 15 closed candles

All indicators are causal (they never look ahead). The swing levels are
shifted by one bar so the current (still-forming) candle is excluded.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

import config

REQUIRED_COLUMNS = ("open", "high", "low", "close")


def _ema(series: pd.Series, span: int) -> pd.Series:
    return series.ewm(span=span, adjust=False).mean()


def _rsi(close: pd.Series, period: int) -> pd.Series:
    """Wilder's RSI. Returns values in [0, 100]."""
    delta = close.diff()
    gain = delta.clip(lower=0.0)
    loss = -delta.clip(upper=0.0)

    avg_gain = gain.ewm(alpha=1.0 / period, adjust=False, min_periods=period).mean()
    avg_loss = loss.ewm(alpha=1.0 / period, adjust=False, min_periods=period).mean()

    rs = avg_gain / avg_loss.replace(0.0, np.nan)
    rsi = 100.0 - (100.0 / (1.0 + rs))

    # Edge cases: no losses -> 100 ; no gains & no losses -> 50.
    rsi = rsi.where(avg_loss != 0.0, 100.0)
    rsi = rsi.where(~((avg_gain == 0.0) & (avg_loss == 0.0)), 50.0)
    return rsi


def _atr(df: pd.DataFrame, period: int) -> pd.Series:
    high, low, close = df["high"], df["low"], df["close"]
    prev_close = close.shift(1)
    tr = pd.concat(
        [
            (high - low).abs(),
            (high - prev_close).abs(),
            (low - prev_close).abs(),
        ],
        axis=1,
    ).max(axis=1)
    return tr.ewm(alpha=1.0 / period, adjust=False, min_periods=period).mean()


def _adx(df: pd.DataFrame, period: int) -> pd.Series:
    """Wilder's Average Directional Index."""
    high, low, close = df["high"], df["low"], df["close"]
    up = high.diff()
    down = -low.diff()
    plus_dm = pd.Series(
        np.where((up > down) & (up > 0), up, 0.0), index=df.index
    )
    minus_dm = pd.Series(
        np.where((down > up) & (down > 0), down, 0.0), index=df.index
    )
    prev_close = close.shift(1)
    tr = pd.concat(
        [(high - low).abs(), (high - prev_close).abs(), (low - prev_close).abs()],
        axis=1,
    ).max(axis=1)
    atr = tr.ewm(alpha=1.0 / period, adjust=False, min_periods=period).mean()
    plus_di = 100.0 * plus_dm.ewm(alpha=1.0 / period, adjust=False, min_periods=period).mean() / atr
    minus_di = 100.0 * minus_dm.ewm(alpha=1.0 / period, adjust=False, min_periods=period).mean() / atr
    dx = 100.0 * (plus_di - minus_di).abs() / (plus_di + minus_di).replace(0.0, np.nan)
    return dx.ewm(alpha=1.0 / period, adjust=False, min_periods=period).mean()


def add_indicators(df: pd.DataFrame, point: float = 0.01) -> pd.DataFrame:
    """Return a copy of ``df`` with all indicator columns appended.

    Parameters
    ----------
    df : DataFrame
        Must contain ``open, high, low, close`` (and ideally ``tick_volume``).
    point : float
        Symbol point size used to convert ATR to points (XAUUSD -> 0.01).
    """
    for col in REQUIRED_COLUMNS:
        if col not in df.columns:
            raise ValueError(f"add_indicators: missing required column '{col}'")
    if point is None or point <= 0:
        raise ValueError("add_indicators: 'point' must be > 0")

    out = df.copy()
    close = out["close"]

    # Moving averages
    out["ema_9"] = _ema(close, config.EMA_FAST)
    out["ema_21"] = _ema(close, config.EMA_MID)
    out["ema_50"] = _ema(close, config.EMA_SLOW)

    # RSI
    out["rsi_7"] = _rsi(close, config.RSI_PERIOD)

    # Bollinger Bands (population std, ddof=0)
    mid = close.rolling(config.BB_PERIOD).mean()
    std = close.rolling(config.BB_PERIOD).std(ddof=0)
    out["bb_mid"] = mid
    out["bb_upper"] = mid + config.BB_STD * std
    out["bb_lower"] = mid - config.BB_STD * std
    out["bb_width"] = (out["bb_upper"] - out["bb_lower"]) / mid.replace(0.0, np.nan)

    # ATR (price + points)
    out["atr_14"] = _atr(out, config.ATR_PERIOD)
    out["atr_points"] = out["atr_14"] / point

    # Volume moving average
    if "tick_volume" in out.columns:
        out["vol_ma_10"] = out["tick_volume"].rolling(config.VOL_MA_PERIOD).mean()
    else:
        out["vol_ma_10"] = np.nan

    # Swing levels of the previous SWING_LOOKBACK closed candles (exclude current)
    out["swing_high_15"] = out["high"].rolling(config.SWING_LOOKBACK).max().shift(1)
    out["swing_low_15"] = out["low"].rolling(config.SWING_LOOKBACK).min().shift(1)

    # Ultra-fast scalping ribbon
    out["ema_5"] = _ema(close, 5)
    out["ema_13"] = _ema(close, 13)

    # Fast Scalping MACD (5, 13, 4)
    macd_line = out["ema_5"] - out["ema_13"]
    macd_signal = macd_line.ewm(span=4, adjust=False).mean()
    out["macd_line"] = macd_line
    out["macd_signal"] = macd_signal
    out["macd_hist"] = macd_line - macd_signal

    # Fast Stochastic (5, 3, 3)
    low5 = out["low"].rolling(5).min()
    high5 = out["high"].rolling(5).max()
    raw_k = 100.0 * (close - low5) / (high5 - low5).replace(0.0, np.nan)
    stoch_k = raw_k.rolling(3).mean()
    out["stoch_k"] = stoch_k
    out["stoch_d"] = stoch_k.rolling(3).mean()

    # ADX(14) — trend strength
    out["adx_14"] = _adx(out, 14)

    # Fair Value Gap (3-candle imbalance) on M1 candles
    out["fvg_bull"] = (out["low"] > out["high"].shift(2)).astype(int)
    out["fvg_bear"] = (out["high"] < out["low"].shift(2)).astype(int)

    return out
