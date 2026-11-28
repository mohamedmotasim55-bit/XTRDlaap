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

import indicators
import dynamic_target_engine
import market_pulse
from market_pulse import PulseContext

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
    entry_type: str = "MARKET"    # "MARKET" | "LIMIT"
    limit_price: float = 0.0
    tp_points: float = 0.0
    sl_points: float = 0.0
    be_trigger: float = 0.0
    be_lock: float = 0.0
    trail_start: float = 0.0
    max_hold_minutes: int = 0
    tier: str = ""
    score: float = 0.0

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


def _build(direction, strategy, entry, atr, atr_points, sl_mult, tp_mult, confidence,
           entry_type="MARKET", limit_price=0.0, targets=None):
    out = dict(direction=direction, strategy=strategy, entry=round(entry, 5),
               atr_points=round(atr_points, 1), confidence=round(confidence, 3),
               entry_type=entry_type, limit_price=round(limit_price, 5))
    if targets:
        point = (atr / atr_points) if atr_points else 0.01
        sl_pts, tp_pts = targets["sl_points"], targets["tp_points"]
        if direction == "BUY":
            sl, tp = entry - sl_pts * point, entry + tp_pts * point
        else:
            sl, tp = entry + sl_pts * point, entry - tp_pts * point
        out.update(sl_points=sl_pts, tp_points=tp_pts,
                   be_trigger=targets["be_trigger"], be_lock=targets["be_lock"],
                   trail_start=targets["trail_start"],
                   max_hold_minutes=targets["max_hold_minutes"],
                   tier=targets["tier"], score=targets["score"])
    else:
        sl, tp = _clamp_sl_tp(direction, entry, atr, atr_points)
    out.update(sl=round(sl, 5), tp=round(tp, 5))
    return out


def _limit_entry(direction, close, high, low, atr, atr_points):
    """35% retracement of the trigger candle, clamped to 12-16 points."""
    if not atr or not atr_points:
        return 0.0
    point = atr / atr_points
    if point <= 0:
        return 0.0
    off_pts = min(16.0, max(12.0, 0.35 * (high - low) / point))
    return close - off_pts * point if direction == "BUY" else close + off_pts * point


def generate_signal(df: pd.DataFrame, mode: str, df_m5: Optional[pd.DataFrame] = None,
                    regime=None, df_m15: Optional[pd.DataFrame] = None) -> Signal:
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

    if set(config.ENABLED_STRATEGIES) & set(config.PULSE_MODELS):
        return _build_pulse_signal(df, df_m5, df_m15, regime,
                                   set(config.ENABLED_STRATEGIES), sig)

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
    adx = _last(df, "adx_14")
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
            if "m5_ema_50" in df_m5.columns:
                me = float(df_m5["m5_ema_50"].iloc[-1])
            else:
                me = float(df_m5["close"].ewm(span=config.EMA_SLOW, adjust=False).mean().iloc[-1])
            m5_ok_buy = mc > me
            m5_ok_sell = mc < me
        except (KeyError, IndexError, TypeError, ValueError):
            pass
    m5_close = m5_ema21 = m5_adx = None
    if df_m5 is not None and len(df_m5) >= 30:
        try:
            m5_close = float(df_m5["close"].iloc[-1])
            if "m5_ema_21" in df_m5.columns:
                m5_ema21 = float(df_m5["m5_ema_21"].iloc[-1])
            else:
                m5_ema21 = float(df_m5["close"].ewm(span=21, adjust=False).mean().iloc[-1])
            if "m5_adx_14" in df_m5.columns:
                m5_adx = float(df_m5["m5_adx_14"].iloc[-1])
            elif {"high", "low", "close"}.issubset(df_m5.columns):
                m5_adx = float(indicators._adx(df_m5, 14).iloc[-1])
        except (KeyError, IndexError, TypeError, ValueError):
            m5_close = m5_ema21 = m5_adx = None
    shield_buy = not (m5_adx is not None and m5_close is not None
                      and m5_ema21 is not None and m5_adx > 30 and m5_close < m5_ema21)
    shield_sell = not (m5_adx is not None and m5_close is not None
                       and m5_ema21 is not None and m5_adx > 30 and m5_close > m5_ema21)
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

    # ---- 2. LiquiditySweep (15-bar institutional sweep) ------------------
    if "LiquiditySweep" in enabled and candle_range > 0:
        lower_wick = min(open_, close) - low
        upper_wick = high - max(open_, close)
        vol_ok_strict = (vol is not None and vol_ma is not None
                         and vol > 1.1 * vol_ma)
        if (sw_lo is not None and low < sw_lo and close > sw_lo
                and lower_wick >= 0.48 * candle_range and rsi < 34
                and vol_ok_strict and shield_buy):
            cands.append(_build("BUY", "LiquiditySweep", close, atr, atr_points,
                                config.SL_ATR_MULT, config.TP_ATR_MULT, 0.70))
        if (sw_hi is not None and high > sw_hi and close < sw_hi
                and upper_wick >= 0.48 * candle_range and rsi > 66
                and vol_ok_strict and shield_sell):
            cands.append(_build("SELL", "LiquiditySweep", close, atr, atr_points,
                                config.SL_ATR_MULT, config.TP_ATR_MULT, 0.70))

    # ---- 3. BollingerBounce (flat-range sniper, M5+M1 ADX gated) --------
    if "BollingerBounce" in enabled and candle_range > 0:
        lower_wick_ratio = (min(open_, close) - low) / candle_range
        upper_wick_ratio = (high - max(open_, close)) / candle_range
        flat_range = (m5_adx is not None and m5_adx < 20
                      and adx is not None and adx < 22)
        if (flat_range and low <= bb_lo and rsi < 24 and close > open_
                and lower_wick_ratio >= 0.42 and volume_ok and shield_buy):
            cands.append(_build("BUY", "BollingerBounce", close, atr, atr_points,
                                config.RANGE_SL_ATR_MULT, config.RANGE_TP_ATR_MULT, 0.66))
        if (flat_range and high >= bb_up and rsi > 76 and close < open_
                and upper_wick_ratio >= 0.42 and volume_ok and shield_sell):
            cands.append(_build("SELL", "BollingerBounce", close, atr, atr_points,
                                config.RANGE_SL_ATR_MULT, config.RANGE_TP_ATR_MULT, 0.66))

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

    # ---- 8. RSISnapback (calibrated exhaustion reversal) ----------------
    if "RSISnapback" in enabled:
        c2 = _last(df, "close", -3)
        two_candle_move = abs(close - c2) if c2 is not None else 0.0
        if two_candle_move > 1.05 * atr:
            if rsi < 27 and close > open_ and shield_buy:
                cands.append(_build("BUY", "RSISnapback", close, atr, atr_points,
                                    config.SL_ATR_MULT, config.TP_ATR_MULT, 0.65))
            if rsi > 73 and close < open_ and shield_sell:
                cands.append(_build("SELL", "RSISnapback", close, atr, atr_points,
                                    config.SL_ATR_MULT, config.TP_ATR_MULT, 0.65))

    # ---- 9. VWAPReversion (intraday magnet, with M5 shield) -------------
    if "VWAPReversion" in enabled:
        vwap = _last(df, "vwap")
        vw_up = _last(df, "vwap_upper")
        vw_lo = _last(df, "vwap_lower")
        if None not in (vwap, vw_up, vw_lo):
            if low <= vw_lo and rsi < 38 and close > open_ and close > vw_lo and shield_buy:
                cands.append(_build("BUY", "VWAPReversion", close, atr, atr_points,
                                    config.SL_ATR_MULT, config.TP_ATR_MULT, 0.67))
            if high >= vw_up and rsi > 62 and close < open_ and close < vw_up and shield_sell:
                cands.append(_build("SELL", "VWAPReversion", close, atr, atr_points,
                                    config.SL_ATR_MULT, config.TP_ATR_MULT, 0.67))

    _institutional_models(cands, enabled, df, df_m5, df_m15, close, open_, high, low,
                          atr, atr_points, rsi, vol, vol_ma, candle_range, body, adx, m5_adx)

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
        entry_type=winner.get("entry_type", "MARKET"),
        limit_price=winner.get("limit_price", 0.0),
        tp_points=winner.get("tp_points", 0.0),
        sl_points=winner.get("sl_points", 0.0),
        be_trigger=winner.get("be_trigger", 0.0),
        be_lock=winner.get("be_lock", 0.0),
        trail_start=winner.get("trail_start", 0.0),
        max_hold_minutes=winner.get("max_hold_minutes", 0),
        tier=winner.get("tier", ""),
        score=winner.get("score", 0.0),
    )


# ---------------------------------------------------------------------------
# Institutional multi-timeframe models (Step 13)
# ---------------------------------------------------------------------------
def _institutional_models(cands, enabled, df, df_m5, df_m15, close, open_, high, low,
                          atr, atr_points, rsi, vol, vol_ma, candle_range, body,
                          adx, m5_adx):
    models = set(config.NEW_MODELS) & set(enabled)
    if not models:
        return

    def val(frame, col, default=None):
        if frame is None or col not in frame.columns or len(frame) == 0:
            return default
        return _num(frame[col].iloc[-1])

    def last_zone(frame, flag):
        if frame is None or flag not in frame.columns or "high" not in frame.columns:
            return None
        for _, r in frame.tail(10).iloc[::-1].iterrows():
            try:
                if int(r[flag]) == 1:
                    return float(r["high"]), float(r["low"])
            except (TypeError, ValueError):
                continue
        return None

    m5_close = val(df_m5, "close")
    m5_ema21 = val(df_m5, "m5_ema_21")
    m5_adx_v = val(df_m5, "m5_adx_14", m5_adx)
    m5_slope = val(df_m5, "m5_ema21_slope", 0.0)
    m5_vup = val(df_m5, "m5_vwap_upper")
    m5_vlo = val(df_m5, "m5_vwap_lower")

    m15_ema21 = val(df_m15, "ema_21")
    m15_ema50 = val(df_m15, "ema_50")
    m15_adx = val(df_m15, "adx_14")
    m15_rsi = val(df_m15, "rsi_7")
    m15_sw_hi = val(df_m15, "swing_high_12")
    m15_sw_lo = val(df_m15, "swing_low_12")

    ts = None
    if df is not None and "time" in df.columns and len(df):
        ts = df["time"].iloc[-1]
    hour = minute = None
    if ts is not None:
        try:
            hour, minute = int(ts.hour), int(ts.minute)
        except (AttributeError, TypeError, ValueError):
            hour = None
    hf = (hour + minute / 60.0) if hour is not None else None

    m1_up = (lambda a, b: a is not None and b is not None and a > b)(
        val(df, "ema_9"), val(df, "ema_21"))
    atr_avg20 = 0.0
    if df is not None and "atr_points" in df.columns and len(df):
        atr_avg20 = float(df["atr_points"].tail(20).mean())
    atr_ratio = (atr_points / atr_avg20) if atr_avg20 > 0 else 0.0
    vol_ratio = (vol / vol_ma) if vol_ma else 0.0
    scalp_ok = atr_points >= config.SCALP_MIN_ATR_POINTS

    def targets_for(direction):  # legacy models keep the static ATR clamp
        return None

    m15_up = m15_ema21 is not None and m15_ema50 is not None and m15_ema21 > m15_ema50
    m15_dn = m15_ema21 is not None and m15_ema50 is not None and m15_ema21 < m15_ema50
    m5_up = m5_close is not None and m5_ema21 is not None and m5_close > m5_ema21
    m5_dn = m5_close is not None and m5_ema21 is not None and m5_close < m5_ema21
    vol_13 = vol is not None and vol_ma is not None and vol > 1.3 * vol_ma
    vol_12 = vol is not None and vol_ma is not None and vol > 1.2 * vol_ma
    vol_20 = vol is not None and vol_ma is not None and vol > 2.0 * vol_ma

    def limit_price(direction):
        return _limit_entry(direction, close, high, low, atr, atr_points)

    # 1. M1_M5_MomentumLimit
    if ("M1_M5_MomentumLimit" in models and scalp_ok
            and m5_adx_v is not None and m5_adx_v > 22
            and body > 1.2 * atr and vol_13):
        if m15_up and m5_up and close > open_:
            cands.append(_build("BUY", "M1_M5_MomentumLimit", close, atr, atr_points,
                                config.SL_ATR_MULT, config.TP_ATR_MULT, 0.72,
                                "LIMIT", limit_price("BUY"), targets_for("BUY")))
        if m15_dn and m5_dn and close < open_:
            cands.append(_build("SELL", "M1_M5_MomentumLimit", close, atr, atr_points,
                                config.SL_ATR_MULT, config.TP_ATR_MULT, 0.72,
                                "LIMIT", limit_price("SELL"), targets_for("SELL")))

    # 2. SessionOpenExpansion
    if ("SessionOpenExpansion" in models and scalp_ok and hf is not None
            and (8.0 <= hf < 11.0 or 13.5 <= hf < 17.0) and candle_range > 1.5 * atr):
        if m5_up and close > open_ and (m15_up or m15_ema21 is None):
            cands.append(_build("BUY", "SessionOpenExpansion", close, atr, atr_points,
                                config.SL_ATR_MULT, config.TP_ATR_MULT, 0.70,
                                "LIMIT", limit_price("BUY"), targets_for("BUY")))
        if m5_dn and close < open_ and (m15_dn or m15_ema21 is None):
            cands.append(_build("SELL", "SessionOpenExpansion", close, atr, atr_points,
                                config.SL_ATR_MULT, config.TP_ATR_MULT, 0.70,
                                "LIMIT", limit_price("SELL"), targets_for("SELL")))

    # 3. M15_LiquiditySweep_M1Trigger
    if "M15_LiquiditySweep_M1Trigger" in models and scalp_ok and candle_range > 0:
        lower_wick = min(open_, close) - low
        upper_wick = high - max(open_, close)
        if (m15_sw_lo is not None and low < m15_sw_lo and close > m15_sw_lo
                and lower_wick >= 0.45 * candle_range and vol_12):
            cands.append(_build("BUY", "M15_LiquiditySweep_M1Trigger", close, atr,
                                atr_points, config.SL_ATR_MULT, config.TP_ATR_MULT, 0.70,
                                targets=targets_for("BUY")))
        if (m15_sw_hi is not None and high > m15_sw_hi and close < m15_sw_hi
                and upper_wick >= 0.45 * candle_range and vol_12):
            cands.append(_build("SELL", "M15_LiquiditySweep_M1Trigger", close, atr,
                                atr_points, config.SL_ATR_MULT, config.TP_ATR_MULT, 0.70,
                                targets=targets_for("SELL")))

    # 4. M5_OrderBlock_Retest
    if "M5_OrderBlock_Retest" in models and scalp_ok:
        bull_zone = last_zone(df_m5, "m5_ob_bull")
        bear_zone = last_zone(df_m5, "m5_ob_bear")
        if bull_zone and low <= bull_zone[0] and close > bull_zone[0] and close > open_:
            cands.append(_build("BUY", "M5_OrderBlock_Retest", close, atr, atr_points,
                                config.SL_ATR_MULT, config.TP_ATR_MULT, 0.68,
                                targets=targets_for("BUY")))
        if bear_zone and high >= bear_zone[1] and close < bear_zone[1] and close < open_:
            cands.append(_build("SELL", "M5_OrderBlock_Retest", close, atr, atr_points,
                                config.SL_ATR_MULT, config.TP_ATR_MULT, 0.68,
                                targets=targets_for("SELL")))

    # 5. VWAP_SessionMagnet
    if ("VWAP_SessionMagnet" in models and m15_adx is not None and m15_adx < 22
            and m5_vlo is not None):
        if low <= m5_vlo and rsi < 35 and close > open_:
            cands.append(_build("BUY", "VWAP_SessionMagnet", close, atr, atr_points,
                                config.RANGE_SL_ATR_MULT, config.RANGE_TP_ATR_MULT, 0.67))
        if m5_vup is not None and high >= m5_vup and rsi > 65 and close < open_:
            cands.append(_build("SELL", "VWAP_SessionMagnet", close, atr, atr_points,
                                config.RANGE_SL_ATR_MULT, config.RANGE_TP_ATR_MULT, 0.67))

    # 6. TickVelocitySurge
    if ("TickVelocitySurge" in models and scalp_ok
            and vol is not None and vol_ma is not None and vol > 1.8 * vol_ma
            and candle_range > 0 and m5_slope is not None and m5_slope > 0):
        if close >= low + 0.8 * candle_range and m5_up:
            cands.append(_build("BUY", "TickVelocitySurge", close, atr, atr_points,
                                config.SL_ATR_MULT, config.TP_ATR_MULT, 0.68,
                                "LIMIT", limit_price("BUY"), targets_for("BUY")))
        if close <= low + 0.2 * candle_range and m5_dn:
            cands.append(_build("SELL", "TickVelocitySurge", close, atr, atr_points,
                                config.SL_ATR_MULT, config.TP_ATR_MULT, 0.68,
                                "LIMIT", limit_price("SELL"), targets_for("SELL")))

    # 7. FVG_InstitutionalFill
    if "FVG_InstitutionalFill" in models:
        fvg_bull = last_zone(df_m5, "fvg_bull")
        fvg_bear = last_zone(df_m5, "fvg_bear")
        if (m15_up and fvg_bull and low <= fvg_bull[0] and close > fvg_bull[0]
                and close > open_):
            cands.append(_build("BUY", "FVG_InstitutionalFill", close, atr, atr_points,
                                config.SL_ATR_MULT, config.TP_ATR_MULT, 0.67))
        if (m15_dn and fvg_bear and high >= fvg_bear[1] and close < fvg_bear[1]
                and close < open_):
            cands.append(_build("SELL", "FVG_InstitutionalFill", close, atr, atr_points,
                                config.SL_ATR_MULT, config.TP_ATR_MULT, 0.67))

    # 8. LondonFixReversal
    if "LondonFixReversal" in models and hf is not None and 15.75 <= hf < 18.0:
        if m15_rsi is not None and m15_rsi > 78 and close < open_:
            cands.append(_build("SELL", "LondonFixReversal", close, atr, atr_points,
                                config.SL_ATR_MULT, config.TP_ATR_MULT, 0.66))
        if m15_rsi is not None and m15_rsi < 22 and close > open_:
            cands.append(_build("BUY", "LondonFixReversal", close, atr, atr_points,
                                config.SL_ATR_MULT, config.TP_ATR_MULT, 0.66))


ENGINE_HITS = {}


def _cand(c, name, direction, confidence, entry_type="MARKET", offset=15.0):
    ENGINE_HITS[name] = ENGINE_HITS.get(name, 0) + 1
    return dict(direction=direction, strategy=name, entry=round(c.close, 5),
                confidence=confidence, entry_type=entry_type,
                limit_price=c.limit_price(direction, offset) if entry_type == "LIMIT" else 0.0)


def _build_pulse_signal(df, df_m5, df_m15, regime, enabled, base_sig):
    c = PulseContext(df, df_m5, df_m15)
    if c.close is None or c.atr is None or c.atr_points is None:
        base_sig.reason = "pulse indicators unavailable"
        return base_sig
    if c.atr_points < config.PULSE_MIN_ATR_POINTS:
        base_sig.reason = f"ATR {c.atr_points:.1f} < pulse min {config.PULSE_MIN_ATR_POINTS:.0f}"
        return base_sig
    if not c.session_active:
        base_sig.reason = "outside institutional pulse session"
        return base_sig
    base_sig.atr_points = round(c.atr_points, 1)
    if regime is None:
        regime = regime_detector.RegimeDetector.classify(df, df_m5)

    rng = c.range or 1e-9
    cands = []

    if "Pulse_ClimaxAbsorption" in enabled and c.pulse >= 1.55 and c.evr >= 2.2 \
            and c.body <= 0.48 * rng:
        if c.wick_low >= 0.45 * rng and c.rsi is not None and c.rsi < 35 and c.close > c.open_:
            cands.append(_cand(c, "Pulse_ClimaxAbsorption", "BUY", 0.75))
        if c.wick_high >= 0.45 * rng and c.rsi is not None and c.rsi > 65 and c.close < c.open_:
            cands.append(_cand(c, "Pulse_ClimaxAbsorption", "SELL", 0.75))

    if "Exhaustion_FOMOFade" in enabled and c.pulse >= 1.45 and c.rsi is not None:
        if (c.rsi > 75 and (c.rsi_prev or 0) > 70 and c.wick_high >= 0.42 * rng
                and c.close < c.open_):
            cands.append(_cand(c, "Exhaustion_FOMOFade", "SELL", 0.74))
        if (c.rsi < 25 and (c.rsi_prev or 100) < 30 and c.wick_low >= 0.42 * rng
                and c.close > c.open_):
            cands.append(_cand(c, "Exhaustion_FOMOFade", "BUY", 0.74))

    if "Pulse_ExhaustionDivergence" in enabled and c.pulse >= 1.55 and c.rsi is not None:
        stretched_lo = ((c.m5_vwap_lo is not None and c.low <= c.m5_vwap_lo)
                        or (c.kelt_lo is not None and c.low <= c.kelt_lo))
        stretched_hi = ((c.m5_vwap_up is not None and c.high >= c.m5_vwap_up)
                        or (c.kelt_up is not None and c.high >= c.kelt_up))
        if stretched_lo and c.rsi < 26 and c.close > c.open_:
            cands.append(_cand(c, "Pulse_ExhaustionDivergence", "BUY", 0.73))
        if stretched_hi and c.rsi > 74 and c.close < c.open_:
            cands.append(_cand(c, "Pulse_ExhaustionDivergence", "SELL", 0.73))

    buy_ok = c.h1_up() and (c.m5_adx is None or c.m5_adx > 25)
    if not buy_ok:
        cands = [x for x in cands if x["direction"] != "BUY"]

    if "H1_Trend_Pullback_Limit" in enabled and c.m5_adx is not None and c.ema21:
        if (c.h1_up() and c.m15_up and c.m5_adx >= 23 and c.rsi is not None
                and 38 <= c.rsi <= 48 and c.close <= c.ema21 + 0.25 * (c.atr or 0)):
            cands.append(_cand(c, "H1_Trend_Pullback_Limit", "BUY", 0.72, "LIMIT", 14.0))
        if (c.h1_dn() and c.m15_dn and c.m5_adx >= 23 and c.rsi is not None
                and 52 <= c.rsi <= 62 and c.close >= c.ema21 - 0.25 * (c.atr or 0)):
            cands.append(_cand(c, "H1_Trend_Pullback_Limit", "SELL", 0.72, "LIMIT", 14.0))

    if ("Session_SwingSweep_Limit" in enabled and c.pulse >= 1.45
            and c.swing_hi is not None and c.swing_lo is not None):
        if (c.wick_low >= 0.45 * rng and c.low < c.swing_lo and c.close > c.open_):
            cands.append(_cand(c, "Session_SwingSweep_Limit", "BUY", 0.72, "LIMIT", 10.0))
        if (c.wick_high >= 0.45 * rng and c.high > c.swing_hi and c.close < c.open_):
            cands.append(_cand(c, "Session_SwingSweep_Limit", "SELL", 0.72, "LIMIT", 10.0))

    if ("M5_OrderBlock_Rebound" in enabled and c.m5_pulse is not None
            and c.m5_body is not None and c.m5_atr and c.m5_atr > 0):
        displacement = c.m5_pulse >= 1.60 and c.m5_body > 1.3 * c.m5_atr
        if (displacement and c.h1_up() and c.m5_ob_bull_top is not None
                and c.m5_ob_bull_bot is not None
                and c.close <= c.m5_ob_bull_top + 0.5 * (c.atr or 0)):
            cands.append(_cand(c, "M5_OrderBlock_Rebound", "BUY", 0.72, "LIMIT", 12.0))
        if (displacement and c.h1_dn() and c.m5_ob_bear_bot is not None
                and c.m5_ob_bear_top is not None
                and c.close >= c.m5_ob_bear_bot - 0.5 * (c.atr or 0)):
            cands.append(_cand(c, "M5_OrderBlock_Rebound", "SELL", 0.72, "LIMIT", 12.0))

    if not cands:
        base_sig.reason = "no pulse-engine match"
        return base_sig

    winner = max(cands, key=lambda x: (x["confidence"], x["strategy"]))
    agree = [x for x in cands if x["direction"] == winner["direction"]]
    aligned = c.aligned_buy if winner["direction"] == "BUY" else c.aligned_sell
    momentum = False
    targets = dynamic_target_engine.select_targets(
        c.pulse, c.atr_points, m5_adx=c.m5_adx or 0.0, atr_ratio=c.atr_ratio,
        m5_aligned=aligned, consensus=len(agree), momentum=momentum)

    point = c.point or 0.01
    sl_pts, tp_pts = targets["sl_points"], targets["tp_points"]
    if winner["direction"] == "BUY":
        sl, tp = c.close - sl_pts * point, c.close + tp_pts * point
    else:
        sl, tp = c.close + sl_pts * point, c.close - tp_pts * point

    return Signal(
        signal=winner["direction"], strategy=winner["strategy"],
        entry=round(c.close, 5), sl=round(sl, 5), tp=round(tp, 5),
        atr_points=round(c.atr_points, 1),
        confidence_score=round(min(1.0, winner["confidence"] + 0.08 * (len(agree) - 1)), 3),
        regime=regime.regime if regime else "",
        reason=f"{winner['strategy']} pulse={c.pulse:.2f} ({len(agree)} agree)",
        entry_type=winner["entry_type"], limit_price=winner["limit_price"],
        tp_points=tp_pts, sl_points=sl_pts, be_trigger=targets["be_trigger"],
        be_lock=targets["be_lock"], trail_start=targets["trail_start"],
        max_hold_minutes=targets["max_hold_minutes"], tier=targets["tier"],
        score=targets["score"],
    )
