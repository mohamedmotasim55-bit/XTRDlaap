"""
strategy_engine.py
==================
7-Strategy High-Frequency Matrix with confidence scoring.

Strategies (all evaluated every tick):
    1. MomentumBreakout     - trend + BB break + RSI + volume (+ M5 filter)
    2. LiquiditySweep       - wick sweep beyond 15-candle swing + reversal
    3. BollingerBounce      - mean reversion from outer BB + extreme RSI(7)
    4. EMARibbonPullback    - trend pullback to ema_13 in trending regimes
    5. FastMACDCross        - MACD(5,13,4) histogram flip + Stoch cross
    6. FairValueGapScalp    - retrace into FVG + rejection candle
    7. MicroEngulfingReversal - engulfing candle > 1.3x ATR + volume

If several fire, the highest-confidence one wins; same-direction agreement
boosts the winner's confidence (capped at 1.0).
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import List, Optional

import pandas as pd

import config
import regime_detector


@dataclass
class Signal:
    signal: str = "NONE"          # "BUY" | "SELL" | "NONE"
    strategy: str = ""
    entry: float = 0.0
    sl: float = 0.0
    tp: float = 0.0
    atr_points: float = 0.0
    confidence_score: float = 0.0
    regime: str = ""
    reason: str = ""

    def __bool__(self) -> bool:
        return self.signal in ("BUY", "SELL")


def _num(value) -> Optional[float]:
    try:
        f = float(value)
        return f if math.isfinite(f) else None
    except (TypeError, ValueError):
        return None


def _last(df: pd.DataFrame, col: str, offset: int = -1) -> Optional[float]:
    if col not in df.columns or len(df) < abs(offset):
        return None
    return _num(df[col].iloc[offset])


def _clamp_sl_tp(direction, entry, atr, atr_points):
    """Unified SL/TP calculator: ATR-based, hard-clamped in POINTS.

    Guarantees no strategy can ever emit a 5-point (or 290-point) stop.
    """
    point = (atr / atr_points) if atr_points and atr_points > 0 else 0.01
    sl_points = max(config.MIN_SL_POINTS,
                    min(config.MAX_SL_POINTS, atr_points * config.SL_ATR_MULT))
    tp_points = max(config.MIN_TP_POINTS,
                    min(config.MAX_TP_POINTS, atr_points * config.TP_ATR_MULT))
    sl_dist = sl_points * point
    tp_dist = tp_points * point
    if direction == "BUY":
        return entry - sl_dist, entry + tp_dist
    return entry + sl_dist, entry - tp_dist


def _build(direction, strategy, entry, atr, atr_points, sl_mult, tp_mult, confidence):
    sl, tp = _clamp_sl_tp(direction, entry, atr, atr_points)
    return dict(direction=direction, strategy=strategy, entry=round(entry, 5),
                sl=round(sl, 5), tp=round(tp, 5), atr_points=round(atr_points, 1),
                confidence=round(confidence, 3))


def generate_signal(df: pd.DataFrame, mode: str, df_m5: Optional[pd.DataFrame] = None,
                    regime=None) -> Signal:
    sig = Signal()
    min_rows = max(config.EMA_SLOW, config.BB_PERIOD, config.ATR_PERIOD,
                   config.SWING_LOOKBACK) + 2
    if df is None or len(df) < min_rows:
        sig.reason = f"insufficient data (need >= {min_rows})"
        return sig

    # Non-tradeable modes (dead zone / weekend) never produce a signal.
    if mode in (
        config.SESSION_MODE_STOP,
        getattr(config, "SESSION_MODE_WEEKEND_SLEEP", "WEEKEND_SLEEP"),
        getattr(config, "SESSION_MODE_WEEKEND_CLOSE", "WEEKEND_CLOSE"),
    ):
        sig.reason = f"mode '{mode}' not tradeable"
        return sig

    atr = _last(df, "atr_14")
    atr_points = _last(df, "atr_points")
    if atr is None or atr_points is None or atr <= 0:
        sig.reason = "ATR unavailable"
        return sig
    sig.atr_points = round(atr_points, 1)

    # Rule 0: volatility gate
    if atr_points < config.MIN_ATR_POINTS:
        sig.reason = f"ATR {atr_points:.1f} pts < min {config.MIN_ATR_POINTS:.0f}"
        return sig

    close = _last(df, "close"); open_ = _last(df, "open")
    high = _last(df, "high"); low = _last(df, "low")
    ema5 = _last(df, "ema_5"); ema13 = _last(df, "ema_13")
    ema9 = _last(df, "ema_9"); ema21 = _last(df, "ema_21"); ema50 = _last(df, "ema_50")
    rsi = _last(df, "rsi_7")
    bb_up = _last(df, "bb_upper"); bb_lo = _last(df, "bb_lower")
    vol = _last(df, "tick_volume"); vol_ma = _last(df, "vol_ma_10")
    sw_hi = _last(df, "swing_high_15"); sw_lo = _last(df, "swing_low_15")
    sw_hi8 = _last(df, "swing_high_8"); sw_lo8 = _last(df, "swing_low_8")
    macd_hist = _last(df, "macd_hist"); macd_prev = _last(df, "macd_hist", -2)
    stoch_k = _last(df, "stoch_k"); stoch_d = _last(df, "stoch_d")
    stoch_k_p = _last(df, "stoch_k", -2); stoch_d_p = _last(df, "stoch_d", -2)
    fvg_bull = _last(df, "fvg_bull"); fvg_bear = _last(df, "fvg_bear")
    fvg_bull_1 = _last(df, "fvg_bull", -2); fvg_bull_2 = _last(df, "fvg_bull", -3)
    fvg_bear_1 = _last(df, "fvg_bear", -2); fvg_bear_2 = _last(df, "fvg_bear", -3)
    prev_open = _last(df, "open", -2); prev_close = _last(df, "close", -2)

    core = (close, open_, high, low, ema9, ema21, ema50, rsi, bb_up, bb_lo)
    if any(v is None for v in core):
        sig.reason = "indicator values contain NaN"
        return sig

    if regime is None:
        regime = regime_detector.RegimeDetector.classify(df, df_m5)
    sig.regime = regime.regime

    candle_range = high - low
    body = abs(close - open_)
    volume_ok = vol is not None and vol_ma is not None and vol > vol_ma
    cands: List[dict] = []
    enabled = set(config.ENABLED_STRATEGIES)

    # ---- 1. MomentumBreakout --------------------------------------------
    m5_ok_buy = m5_ok_sell = True
    if df_m5 is not None and len(df_m5) >= config.EMA_SLOW:
        try:
            mc = float(df_m5["close"].iloc[-1])
            me = float(df_m5["close"].ewm(span=config.EMA_SLOW, adjust=False).mean().iloc[-1])
            m5_ok_buy = mc > me
            m5_ok_sell = mc < me
        except (KeyError, IndexError, TypeError, ValueError):
            pass
    bull_break = (close > bb_up) or (body > 1.2 * atr and close > open_)
    bear_break = (close < bb_lo) or (body > 1.2 * atr and close < open_)
    if ("MomentumBreakout" in enabled and close > ema50 and ema9 > ema21
            and bull_break and 60 <= rsi <= 82 and volume_ok and m5_ok_buy):
        cands.append(_build("BUY", "MomentumBreakout", close, atr, atr_points,
                            config.SL_ATR_MULT, config.TP_ATR_MULT, 0.72))
    if ("MomentumBreakout" in enabled and close < ema50 and ema9 < ema21
            and bear_break and 18 <= rsi <= 40 and volume_ok and m5_ok_sell):
        cands.append(_build("SELL", "MomentumBreakout", close, atr, atr_points,
                            config.SL_ATR_MULT, config.TP_ATR_MULT, 0.72))

    # ---- 2. LiquiditySweep (24/5 micro-swing sweeps) ---------------------
    if "LiquiditySweep" in enabled and candle_range > 0:
        lower_wick = min(open_, close) - low
        upper_wick = high - max(open_, close)
        broke_lo = ((sw_lo is not None and low < sw_lo)
                    or (sw_lo8 is not None and low < sw_lo8))
        broke_hi = ((sw_hi is not None and high > sw_hi)
                    or (sw_hi8 is not None and high > sw_hi8))
        if broke_lo and lower_wick >= 0.38 * candle_range and rsi < 40:
            cands.append(_build("BUY", "LiquiditySweep", close, atr, atr_points,
                                config.SL_ATR_MULT, config.TP_ATR_MULT, 0.68))
        if broke_hi and upper_wick >= 0.38 * candle_range and rsi > 60:
            cands.append(_build("SELL", "LiquiditySweep", close, atr, atr_points,
                                config.SL_ATR_MULT, config.TP_ATR_MULT, 0.68))

    # ---- 3. BollingerBounce (24/5 mean reversion) -----------------------
    if "BollingerBounce" in enabled:
        if low <= bb_lo and rsi < 32 and close > open_:
            cands.append(_build("BUY", "BollingerBounce", close, atr, atr_points,
                                config.RANGE_SL_ATR_MULT, config.RANGE_TP_ATR_MULT, 0.65))
        if high >= bb_up and rsi > 68 and close < open_:
            cands.append(_build("SELL", "BollingerBounce", close, atr, atr_points,
                                config.RANGE_SL_ATR_MULT, config.RANGE_TP_ATR_MULT, 0.65))

    # ---- 4. EMARibbonPullback (trending regimes only) -------------------
    if "EMARibbonPullback" in enabled and regime.is_trending and ema5 is not None and ema13 is not None:
        if ema5 > ema13 > ema21 and low <= ema13 and close > open_ and close > ema13:
            cands.append(_build("BUY", "EMARibbonPullback", close, atr, atr_points,
                                1.5, 2.2, 0.70))
        if ema5 < ema13 < ema21 and high >= ema13 and close < open_ and close < ema13:
            cands.append(_build("SELL", "EMARibbonPullback", close, atr, atr_points,
                                1.5, 2.2, 0.70))

    # ---- 5. FastMACDCross -----------------------------------------------
    if "FastMACDCross" in enabled and None not in (macd_hist, macd_prev, stoch_k, stoch_d, stoch_k_p, stoch_d_p):
        if (macd_prev <= 0 < macd_hist and close > ema50
                and stoch_k_p < stoch_d_p and stoch_k > stoch_d and stoch_k_p < 25):
            cands.append(_build("BUY", "FastMACDCross", close, atr, atr_points,
                                1.5, 2.2, 0.65))
        if (macd_prev >= 0 > macd_hist and close < ema50
                and stoch_k_p > stoch_d_p and stoch_k < stoch_d and stoch_k_p > 75):
            cands.append(_build("SELL", "FastMACDCross", close, atr, atr_points,
                                1.5, 2.2, 0.65))

    # ---- 6. FairValueGapScalp -------------------------------------------
    recent_bull_fvg = bool(fvg_bull) or bool(fvg_bull_1) or bool(fvg_bull_2)
    recent_bear_fvg = bool(fvg_bear) or bool(fvg_bear_1) or bool(fvg_bear_2)
    if "FairValueGapScalp" in enabled and recent_bull_fvg and close > open_:
        cands.append(_build("BUY", "FairValueGapScalp", close, atr, atr_points,
                            1.4, 2.0, 0.60))
    if "FairValueGapScalp" in enabled and recent_bear_fvg and close < open_:
        cands.append(_build("SELL", "FairValueGapScalp", close, atr, atr_points,
                            1.4, 2.0, 0.60))

    # ---- 7. MicroEngulfingReversal --------------------------------------
    if ("MicroEngulfingReversal" in enabled and prev_open is not None
            and prev_close is not None and body > 1.3 * atr and volume_ok):
        if prev_close < prev_open and close > open_ and close >= prev_open and open_ <= prev_close:
            cands.append(_build("BUY", "MicroEngulfingReversal", close, atr, atr_points,
                                1.5, 2.2, 0.70))
        if prev_close > prev_open and close < open_ and close <= prev_open and open_ >= prev_close:
            cands.append(_build("SELL", "MicroEngulfingReversal", close, atr, atr_points,
                                1.5, 2.2, 0.70))

    # ---- 8. RSISnapback (high-frequency exhaustion reversal) ------------
    if "RSISnapback" in enabled:
        c2 = _last(df, "close", -3)
        two_candle_move = abs(close - c2) if c2 is not None else 0.0
        if two_candle_move > 1.6 * atr:
            if rsi < 22 and close > open_:
                cands.append(_build("BUY", "RSISnapback", close, atr, atr_points,
                                    config.SL_ATR_MULT, config.TP_ATR_MULT, 0.64))
            if rsi > 78 and close < open_:
                cands.append(_build("SELL", "RSISnapback", close, atr, atr_points,
                                    config.SL_ATR_MULT, config.TP_ATR_MULT, 0.64))

    if not cands:
        sig.reason = "no strategy matched"
        return sig

    winner = max(cands, key=lambda c: c["confidence"])
    agree = [c for c in cands if c["direction"] == winner["direction"]]
    conf = winner["confidence"]
    if len(agree) >= 2:
        conf = min(1.0, conf + 0.1 * (len(agree) - 1))

    return Signal(
        signal=winner["direction"], strategy=winner["strategy"],
        entry=winner["entry"], sl=winner["sl"], tp=winner["tp"],
        atr_points=winner["atr_points"], confidence_score=round(conf, 3),
        regime=regime.regime,
        reason=f"{winner['strategy']} ({len(agree)} agree)",
    )
