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

import market_pulse

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
    # Micro-swing (8-bar) for high-frequency liquidity sweeps.
    out["swing_high_8"] = out["high"].rolling(8).max().shift(1)
    out["swing_low_8"] = out["low"].rolling(8).min().shift(1)

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

    # Intraday VWAP (resets at 00:00 server time) + 20-bar sigma bands
    out["vwap"], out["vwap_upper"], out["vwap_lower"] = vwap_bands(out, 1.35)
    out["vwap_sd"] = (out["vwap_upper"] - out["vwap"]) / 1.35

    # 12-bar swing levels (M15 institutional sweep reference)
    out["swing_high_12"] = out["high"].rolling(12).max().shift(1)
    out["swing_low_12"] = out["low"].rolling(12).min().shift(1)
    out["swing_high_20"] = out["high"].rolling(20).max().shift(1)
    out["swing_low_20"] = out["low"].rolling(20).min().shift(1)

    out["atr_ma_20"] = out["atr_14"].rolling(20).mean()
    out["bb_width"] = (out["bb_upper"] - out["bb_lower"]).abs()
    out["bb_width_rank"] = out["bb_width"].rolling(20).rank(pct=True)
    out["bb_width_rank_prev"] = out["bb_width_rank"].shift(1)
    out["keltner_mid"] = out["ema_21"]
    out["keltner_upper"] = out["keltner_mid"] + 1.8 * out["atr_14"]
    out["keltner_lower"] = out["keltner_mid"] - 1.8 * out["atr_14"]

    st, st_dir = _supertrend(out, 10, 2.5)
    out["supertrend"] = st
    out["supertrend_dir"] = st_dir

    _vol = (out["tick_volume"] if "tick_volume" in out.columns
            else pd.Series(1.0, index=out.index))
    out["obv"] = (np.sign(out["close"].diff().fillna(0.0)) * _vol).cumsum()
    out["obv_ema_10"] = out["obv"].ewm(span=10, adjust=False).mean()

    out["inside_bar"] = ((out["high"] < out["high"].shift(1))
                         & (out["low"] > out["low"].shift(1))).astype(int)

    body = (out["close"] - out["open"]).abs()
    out["order_block_bull"] = ((out["close"] > out["open"])
                               & (body > 1.2 * out["atr_14"])).astype(int)
    out["order_block_bear"] = ((out["close"] < out["open"])
                               & (body > 1.2 * out["atr_14"])).astype(int)

    add_zone_levels(out, ("fvg_bull", "fvg_bear",
                          "order_block_bull", "order_block_bear"), 10)

    for col, ser in _pivots(out).items():
        out[col] = ser

    if "time" in out.columns:
        try:
            ts = pd.to_datetime(out["time"])
            day = ts.dt.date
            asian = ts.dt.hour < 7
            hi = out["high"].where(asian).groupby(day).cummax()
            lo = out["low"].where(asian).groupby(day).cummin()
            out["asian_high"] = hi.groupby(day).ffill()
            out["asian_low"] = lo.groupby(day).ffill()
        except (TypeError, ValueError):
            out["asian_high"] = np.nan
            out["asian_low"] = np.nan
    else:
        out["asian_high"] = np.nan
        out["asian_low"] = np.nan

    return market_pulse.add_pulse(out)


def add_zone_levels(df, flags, n: int = 10):
    """Vectorised "last active zone" high/low so strategies avoid per-bar scans."""
    idx = np.arange(len(df))
    hi = df["high"].to_numpy()
    lo = df["low"].to_numpy()
    for flag in flags:
        if flag not in df.columns:
            continue
        pos = np.maximum.accumulate(np.where(df[flag].to_numpy() == 1, idx, -1))
        valid = (pos >= 0) & ((idx - pos) <= n)
        safe = np.clip(pos, 0, None)
        df[flag + "_hi"] = np.where(valid, hi[safe], np.nan)
        df[flag + "_lo"] = np.where(valid, lo[safe], np.nan)
    return df


def _supertrend(df, period: int = 10, mult: float = 2.5):
    prev_close = df["close"].shift(1)
    tr = pd.concat([df["high"] - df["low"],
                    (df["high"] - prev_close).abs(),
                    (df["low"] - prev_close).abs()], axis=1).max(axis=1)
    atr = tr.rolling(period).mean().bfill().fillna(0.0)
    hl2 = (df["high"] + df["low"]) / 2.0
    upper = (hl2 + mult * atr).to_numpy()
    lower = (hl2 - mult * atr).to_numpy()
    close = df["close"].to_numpy()
    n = len(df)
    st = np.zeros(n)
    direction = np.ones(n)
    for i in range(1, n):
        if close[i] > upper[i - 1]:
            direction[i] = 1
        elif close[i] < lower[i - 1]:
            direction[i] = -1
        else:
            direction[i] = direction[i - 1]
        st[i] = lower[i] if direction[i] == 1 else upper[i]
    return pd.Series(st, index=df.index), pd.Series(direction, index=df.index)


def _pivots(df):
    empty = {k: pd.Series(np.nan, index=df.index)
             for k in ("pivot_p", "pivot_r1", "pivot_s1")}
    if "time" not in df.columns or len(df) < 2:
        return empty
    try:
        day = pd.to_datetime(df["time"]).dt.date
    except (TypeError, ValueError):
        return empty
    g = df.groupby(day).agg(h=("high", "max"), l=("low", "min"), c=("close", "last"))
    p = (g["h"] + g["l"] + g["c"]) / 3.0
    g["p"] = p
    g["r1"] = 2 * p - g["l"]
    g["s1"] = 2 * p - g["h"]
    g = g.shift(1)
    return {"pivot_p": day.map(g["p"]), "pivot_r1": day.map(g["r1"]),
            "pivot_s1": day.map(g["s1"])}


def vwap_bands(df, sigma: float = 1.35):
    """Return (vwap, upper, lower) with a daily reset at 00:00 server time."""
    typical = (df["high"] + df["low"] + df["close"]) / 3.0
    vol = (df["tick_volume"] if "tick_volume" in df.columns
           else pd.Series(1.0, index=df.index))
    if "time" in df.columns:
        try:
            day_key = pd.to_datetime(df["time"]).dt.date
        except (TypeError, ValueError):
            day_key = pd.Series(0, index=df.index)
    else:
        day_key = pd.Series(0, index=df.index)
    cum_pv = (typical * vol).groupby(day_key).cumsum()
    cum_v = vol.groupby(day_key).cumsum().replace(0.0, np.nan)
    vwap = cum_pv / cum_v
    sd = (typical - vwap).rolling(20).std()
    return vwap, vwap + sigma * sd, vwap - sigma * sd
