"""
strategy_engine.py
==================
Turns the latest indicator row + session mode into a scalping signal.

Public API
----------
``generate_signal(df, mode) -> Signal``

``df`` must already contain the columns produced by ``indicators.add_indicators``.
``mode`` is one of ``config.SESSION_MODE_MOMENTUM`` / ``SESSION_MODE_ASIAN`` /
``SESSION_MODE_STOP``.

Sub-strategies
--------------
MOMENTUM session:
    * MomentumBreakout   (trend + band break / strong candle + volume)
    * LiquiditySweep     (wick sweep of swing level + close back inside)
ASIAN_RANGE session:
    * BollingerBounce    (band pierce + RSI extreme + reversal candle)

A global volatility gate (Rule 0) rejects everything when ATR is too small to
cover the spread.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Optional

import pandas as pd

import config


@dataclass
class Signal:
    """Result of one strategy evaluation."""

    signal: str = "NONE"          # "BUY" | "SELL" | "NONE"
    strategy: str = ""            # sub-strategy name
    entry: float = 0.0            # reference entry (last close)
    sl: float = 0.0               # stop-loss price
    tp: float = 0.0               # take-profit price
    atr_points: float = 0.0
    reason: str = ""              # explanation (esp. when NONE)

    def __bool__(self) -> bool:
        return self.signal in ("BUY", "SELL")


def _num(value) -> Optional[float]:
    try:
        f = float(value)
        return f if math.isfinite(f) else None
    except (TypeError, ValueError):
        return None


def _last(df: pd.DataFrame, col: str) -> Optional[float]:
    if col not in df.columns or len(df) == 0:
        return None
    return _num(df[col].iloc[-1])


def _make_signal(
    direction: str,
    strategy: str,
    entry: float,
    atr: float,
    sl_mult: float,
    tp_mult: float,
    atr_points: float,
) -> Signal:
    if direction == "BUY":
        sl = entry - sl_mult * atr
        tp = entry + tp_mult * atr
    else:  # SELL
        sl = entry + sl_mult * atr
        tp = entry - tp_mult * atr
    return Signal(
        signal=direction,
        strategy=strategy,
        entry=round(entry, 5),
        sl=round(sl, 5),
        tp=round(tp, 5),
        atr_points=round(atr_points, 1),
        reason=f"{strategy} triggered",
    )


def generate_signal(df: pd.DataFrame, mode: str, df_m5: Optional[pd.DataFrame] = None) -> Signal:
    """Evaluate the appropriate sub-strategies and return a :class:`Signal`.

    ``df_m5`` (optional) is used only to align MomentumBreakout with the
    higher-timeframe trend (M5 close vs M5 EMA50). LiquiditySweep and
    BollingerBounce remain independent reversal strategies.
    """
    sig = Signal()

    min_rows = max(
        config.EMA_SLOW, config.BB_PERIOD, config.ATR_PERIOD, config.SWING_LOOKBACK
    ) + 2
    if df is None or len(df) < min_rows:
        sig.reason = f"insufficient data (need >= {min_rows} rows)"
        return sig

    atr = _last(df, "atr_14")
    atr_points = _last(df, "atr_points")
    if atr is None or atr_points is None or atr <= 0:
        sig.reason = "ATR unavailable"
        return sig
    sig.atr_points = round(atr_points, 1)

    # --- Rule 0: volatility gate -------------------------------------------------
    if atr_points < config.MIN_ATR_POINTS:
        sig.reason = f"ATR {atr_points:.1f} pts < min {config.MIN_ATR_POINTS:.0f}"
        return sig

    # --- Pull the latest values --------------------------------------------------
    close = _last(df, "close")
    open_ = _last(df, "open")
    high = _last(df, "high")
    low = _last(df, "low")
    ema9 = _last(df, "ema_9")
    ema21 = _last(df, "ema_21")
    ema50 = _last(df, "ema_50")
    rsi = _last(df, "rsi_7")
    bb_up = _last(df, "bb_upper")
    bb_lo = _last(df, "bb_lower")
    vol = _last(df, "tick_volume")
    vol_ma = _last(df, "vol_ma_10")
    sw_hi = _last(df, "swing_high_15")
    sw_lo = _last(df, "swing_low_15")

    core = (close, open_, high, low, ema9, ema21, ema50, rsi, bb_up, bb_lo)
    if any(v is None for v in core):
        sig.reason = "indicator values contain NaN"
        return sig

    candle_range = high - low
    body = abs(close - open_)

    # -------------------------------------------------------------------------
    # MOMENTUM session
    # -------------------------------------------------------------------------
    if mode == config.SESSION_MODE_MOMENTUM:
        volume_ok = vol is not None and vol_ma is not None and vol > vol_ma

        # M5 higher-timeframe trend alignment (only filters MomentumBreakout).
        m5_ok_buy = True
        m5_ok_sell = True
        if df_m5 is not None and len(df_m5) >= config.EMA_SLOW:
            try:
                m5_close = float(df_m5["close"].iloc[-1])
                m5_ema50 = float(df_m5["close"].ewm(span=config.EMA_SLOW, adjust=False).mean().iloc[-1])
                m5_ok_buy = m5_close > m5_ema50
                m5_ok_sell = m5_close < m5_ema50
            except (KeyError, IndexError, TypeError, ValueError):
                pass

        # Sub-strategy 1: Momentum Breakout
        bullish_break = (close > bb_up) or (body > 1.2 * atr and close > open_)
        bearish_break = (close < bb_lo) or (body > 1.2 * atr and close < open_)

        if (
            close > ema50
            and ema9 > ema21
            and bullish_break
            and 60.0 <= rsi <= 82.0
            and volume_ok
            and m5_ok_buy
        ):
            return _make_signal(
                "BUY", "MomentumBreakout", close, atr,
                config.SL_ATR_MULT, config.TP_ATR_MULT, atr_points,
            )
        if (
            close < ema50
            and ema9 < ema21
            and bearish_break
            and 18.0 <= rsi <= 40.0
            and volume_ok
            and m5_ok_sell
        ):
            return _make_signal(
                "SELL", "MomentumBreakout", close, atr,
                config.SL_ATR_MULT, config.TP_ATR_MULT, atr_points,
            )

        # Sub-strategy 2: Liquidity Sweep (fakeout reversal)
        if candle_range > 0 and sw_lo is not None and sw_hi is not None:
            lower_wick = min(open_, close) - low
            upper_wick = high - max(open_, close)

            sweep_buy = (
                low < sw_lo
                and lower_wick > 0.45 * candle_range
                and close > sw_lo
                and rsi < 35.0
            )
            if sweep_buy:
                return _make_signal(
                    "BUY", "LiquiditySweep", close, atr,
                    config.SL_ATR_MULT, config.TP_ATR_MULT, atr_points,
                )

            sweep_sell = (
                high > sw_hi
                and upper_wick > 0.45 * candle_range
                and close < sw_hi
                and rsi > 65.0
            )
            if sweep_sell:
                return _make_signal(
                    "SELL", "LiquiditySweep", close, atr,
                    config.SL_ATR_MULT, config.TP_ATR_MULT, atr_points,
                )

        sig.reason = "momentum: no sub-strategy matched"
        return sig

    # -------------------------------------------------------------------------
    # ASIAN_RANGE session — Bollinger Bounce (mean reversion, tighter targets)
    # -------------------------------------------------------------------------
    if mode == config.SESSION_MODE_ASIAN:
        if low <= bb_lo and rsi < 28.0 and close > open_:
            return _make_signal(
                "BUY", "BollingerBounce", close, atr,
                config.RANGE_SL_ATR_MULT, config.RANGE_TP_ATR_MULT, atr_points,
            )
        if high >= bb_up and rsi > 72.0 and close < open_:
            return _make_signal(
                "SELL", "BollingerBounce", close, atr,
                config.RANGE_SL_ATR_MULT, config.RANGE_TP_ATR_MULT, atr_points,
            )
        sig.reason = "asian: no sub-strategy matched"
        return sig

    # STOP / unknown mode
    sig.reason = f"mode '{mode}' not tradeable"
    return sig
