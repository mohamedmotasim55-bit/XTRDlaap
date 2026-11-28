"""
tick_engine.py
==============
Sub-second tick flow engine ported from XTRD OMIGA GOLD HUNTER v1.29.

Keeps a 512-tick circular buffer of (mid, time_msc) and derives the
microstructure metrics used by the ``Tick_Impulse_Stacker`` engine:

* ``fast_speed``        - points travelled over the last 6 ticks
* ``slow_speed``        - points travelled over the last 24 ticks
* ``acceleration_ratio``- |fast| / |slow|
* ``directional_ratio`` - share of ticks moving with the net direction
* ``path_efficiency``   - |net move| / sum(|tick moves|)

v1.29 flaws fixed here:
* ``MIN_FAST_MOVE_POINTS`` raised to 20.0 points (the old 1.2 was
  smaller than the 26-point spread, so the trigger was pure noise).
* ``candle_rejects`` / ``is_overextended`` guards, so the engine never
  enters into a rejection wick or an already stretched candle.
"""
from __future__ import annotations

from collections import deque
from typing import Deque, Optional, Tuple

import config

BUFFER_SIZE = 512
FAST_TICKS = 6
SLOW_TICKS = 24

MIN_FAST_MOVE_POINTS = 20.0
MIN_ACCELERATION_RATIO = 1.20
MIN_DIRECTIONAL_RATIO = 0.62
MIN_PATH_EFFICIENCY = 0.25
MAX_OPPOSING_WICK_RATIO = 0.55
MAX_ENTRY_EXTENSION_ATR = 0.55
SMALL_BODY_RATIO = 0.45


class TickFlow:
    """Circular buffer of mid prices with the v1.29 microstructure metrics."""

    def __init__(self, size: int = BUFFER_SIZE, point: float = 0.01) -> None:
        self.mid: Deque[float] = deque(maxlen=size)
        self.time_msc: Deque[int] = deque(maxlen=size)
        self.point = point or 0.01

    # ------------------------------------------------------------------ feed
    def add(self, mid: float, time_msc: int) -> None:
        self.mid.append(float(mid))
        self.time_msc.append(int(time_msc))

    def __len__(self) -> int:
        return len(self.mid)

    # --------------------------------------------------------------- metrics
    def _move_points(self, ticks: int) -> Optional[float]:
        if len(self.mid) <= ticks:
            return None
        return (self.mid[-1] - self.mid[-1 - ticks]) / self.point

    @property
    def fast_speed(self) -> Optional[float]:
        """Points per tick over the last 6 ticks."""
        move = self._move_points(FAST_TICKS)
        return None if move is None else move / FAST_TICKS

    @property
    def slow_speed(self) -> Optional[float]:
        """Points per tick over the last 24 ticks."""
        move = self._move_points(SLOW_TICKS)
        return None if move is None else move / SLOW_TICKS

    @property
    def fast_move(self) -> Optional[float]:
        return self._move_points(FAST_TICKS)

    @property
    def acceleration_ratio(self) -> float:
        fast, slow = self.fast_speed, self.slow_speed
        if fast is None or not slow:
            return 0.0
        return abs(fast) / max(abs(slow), 1e-9)

    @property
    def directional_ratio(self) -> float:
        if len(self.mid) < SLOW_TICKS + 1:
            return 0.0
        window = list(self.mid)[-(SLOW_TICKS + 1):]
        diffs = [b - a for a, b in zip(window, window[1:])]
        net = window[-1] - window[0]
        if net == 0:
            return 0.0
        sign = 1.0 if net > 0 else -1.0
        return sum(1 for d in diffs if d * sign > 0) / len(diffs)

    @property
    def path_efficiency(self) -> float:
        if len(self.mid) < SLOW_TICKS + 1:
            return 0.0
        window = list(self.mid)[-(SLOW_TICKS + 1):]
        diffs = [abs(b - a) for a, b in zip(window, window[1:])]
        total = sum(diffs)
        if total <= 0:
            return 0.0
        return abs(window[-1] - window[0]) / total

    def impulse_direction(self, min_move_points: float = MIN_FAST_MOVE_POINTS) -> Optional[str]:
        fast = self.fast_speed
        if fast is None or abs(self.fast_move or 0.0) < min_move_points:
            return None
        if self.acceleration_ratio < MIN_ACCELERATION_RATIO:
            return None
        if self.directional_ratio < MIN_DIRECTIONAL_RATIO:
            return None
        if self.path_efficiency < MIN_PATH_EFFICIENCY:
            return None
        return "BUY" if fast > 0 else "SELL"

    # backwards-compatible alias
    def signal(self, min_move_points: float = MIN_FAST_MOVE_POINTS) -> Optional[str]:
        return self.impulse_direction(min_move_points)


def candle_rejects(direction: str, open_: float, high: float, low: float, close: float,
                   max_opposing_wick_ratio: float = MAX_OPPOSING_WICK_RATIO,
                   small_body_ratio: float = SMALL_BODY_RATIO) -> bool:
    """True when a small-body candle shows a rejection against ``direction``."""
    rng = high - low
    if rng <= 0:
        return False
    body = abs(close - open_)
    if body > small_body_ratio * rng:
        return False
    if direction == "BUY":
        opposing = high - max(open_, close)
    else:
        opposing = min(open_, close) - low
    return opposing >= max_opposing_wick_ratio * rng


def is_overextended(direction: str, close: float, ema5: float, atr: float,
                    max_extension_atr: float = MAX_ENTRY_EXTENSION_ATR) -> bool:
    if not atr or ema5 is None:
        return False
    extension = (close - ema5) if direction == "BUY" else (ema5 - close)
    return extension > max_extension_atr * atr


def ema_alignment_ok(direction: str, m1_up: bool, m5_up: bool) -> bool:
    return m1_up if direction == "BUY" else (not m1_up and not m5_up) if m5_up is not None else not m1_up


def evaluate(tf: TickFlow, direction: str, row, ema5: Optional[float],
             atr: Optional[float], m1_up: bool, m5_up: bool) -> Tuple[bool, str]:
    """Final v1.29 entry gate for a candidate direction."""
    if candle_rejects(direction, row["open"], row["high"], row["low"], row["close"]):
        return False, "candle_reject"
    if is_overextended(direction, row["close"], ema5, atr or 0.0):
        return False, "overextended"
    if direction == "BUY" and not m1_up:
        return False, "m1_ema_not_aligned"
    if direction == "SELL" and m1_up:
        return False, "m1_ema_not_aligned"
    return True, "ok"


def build_bar_tick_features(m1, ticks, point: float = 0.01):
    """Map authentic ticks onto M1 bars.

    Returns ``(dirs, audit)`` where ``dirs[i]`` is "BUY"/"SELL"/None for bar i,
    derived only from real broker ticks (no synthetic interpolation).
    """
    import numpy as np
    import pandas as pd

    audit = dict(total_ticks=int(len(ticks)) if ticks is not None else 0, synthetic=False,
                 median_interval_ms=None, spread_p25=None, spread_p50=None,
                 spread_p75=None, spread_pts_p50=None, bars_with_burst=0)

    if ticks is None or len(ticks) == 0:
        return [None] * len(m1), audit

    bid = pd.to_numeric(ticks["bid"], errors="coerce").to_numpy(dtype="float64")
    ask = pd.to_numeric(ticks["ask"], errors="coerce").to_numpy(dtype="float64")
    msc = pd.to_numeric(ticks["time_msc"], errors="coerce").to_numpy(dtype="int64")
    ok = (bid > 0) & (ask > 0)
    bid, ask, msc = bid[ok], ask[ok], msc[ok]
    if len(bid) < 64:
        return [None] * len(m1), audit

    spread = ask - bid
    audit["median_interval_ms"] = float(np.median(np.diff(msc))) if len(msc) > 1 else None
    audit["spread_p25"] = float(np.percentile(spread, 25))
    audit["spread_p50"] = float(np.percentile(spread, 50))
    audit["spread_p75"] = float(np.percentile(spread, 75))
    audit["spread_pts_p50"] = round(audit["spread_p50"] / point, 1)

    mid = (bid + ask) / 2.0
    s = pd.Series(mid)
    diff = s.diff()
    fast_move = (s - s.shift(FAST_TICKS)) / point
    # v1.29 measures path efficiency over the same burst window, plus a
    # hard 4-second ceiling between the first and last tick of the burst.
    burst_path = diff.abs().rolling(FAST_TICKS).sum()
    path_eff = ((s - s.shift(FAST_TICKS)).abs() / burst_path).fillna(0.0)
    span_ms = pd.Series(msc).diff(FAST_TICKS)

    qualify = (fast_move.abs() >= 18.0) & (path_eff >= 0.30) & (span_ms <= 4000)
    if not qualify.any():
        return [None] * len(m1), audit

    times = pd.to_datetime(m1["time"]).astype("int64") // 10 ** 6  # ms
    idx = np.searchsorted(times.to_numpy(), msc, side="right") - 1
    sel = qualify.to_numpy() & (idx >= 0) & (idx < len(m1))
    dirs = [None] * len(m1)
    if sel.any():
        bars = idx[sel]
        signs = np.where(fast_move.to_numpy()[sel] > 0, 1, -1)
        frame = pd.DataFrame(dict(bar=bars, sign=signs))
        last = frame.groupby("bar")["sign"].last()
        for bar, sign in last.items():
            dirs[int(bar)] = "BUY" if sign > 0 else "SELL"
        audit["bars_with_burst"] = int(len(last))
    return dirs, audit
