"""
safety_guard.py
===============
Pre-trade safety checks. These are read-only guards; they never place orders.

Public API
----------
* ``check_spread()``          -> bool   (True = spread acceptable)
* ``check_session()``         -> str    ("ASIAN_RANGE" | "MOMENTUM" | "STOP")
* ``check_daily_drawdown()``  -> bool   (True = within daily loss limit)

The daily-drawdown guard combines *realised* PnL from today's closed deals
with *floating* PnL from open positions, and compares the loss against the
balance at the start of the trading day.
"""

from __future__ import annotations

import logging
from datetime import datetime, time as dtime
from typing import Optional

try:  # Windows-only; keep import defensive.
    import MetaTrader5 as mt5  # type: ignore
except ImportError:  # pragma: no cover
    mt5 = None  # type: ignore

import config
from mt5_connector import MT5Connector, MT5ConnectionError

log = logging.getLogger(__name__)


class SafetyGuard:
    """Evaluates the three pre-trade safety conditions."""

    def __init__(self, connector: MT5Connector) -> None:
        self.conn = connector

    # ------------------------------------------------------------------ spread
    def check_spread(self) -> bool:
        """Return ``True`` if the live spread is within the configured maximum."""
        try:
            spread = self.conn.current_spread_points()
        except MT5ConnectionError as exc:
            log.error("Spread check failed: %s", exc)
            return False
        if spread is None:
            log.warning("Spread unavailable (no tick); treating as unsafe.")
            return False
        ok = spread <= config.MAX_SPREAD_POINTS
        if not ok:
            log.warning(
                "Spread %.1f pts exceeds max %.1f pts.",
                spread,
                config.MAX_SPREAD_POINTS,
            )
        return ok

    # ----------------------------------------------------------------- session
    def check_session(self, now: Optional[datetime] = None) -> str:
        """Return the active session mode based on broker/server time.

        ``now`` defaults to the broker server time. The function is
        deliberately pure/stateless so it can be unit-tested with a fixed
        timestamp.
        """
        if now is None:
            try:
                now = self.conn.server_time().to_pydatetime()
            except MT5ConnectionError:
                # Fall back to local time only to keep the monitor alive.
                log.warning("Server time unavailable; using local clock for session check.")
                now = datetime.now()

        t: dtime = now.time()
        if self._in_window(t, config.ASIAN_RANGE_START, config.ASIAN_RANGE_END):
            return config.SESSION_MODE_ASIAN
        if self._in_window(t, config.MOMENTUM_START, config.MOMENTUM_END):
            return config.SESSION_MODE_MOMENTUM
        return config.SESSION_MODE_STOP

    @staticmethod
    def _in_window(t: dtime, start: dtime, end: dtime) -> bool:
        """Inclusive-start, exclusive-end window test (handles overnight wrap)."""
        if start <= end:
            return start <= t < end
        # Window wraps midnight, e.g. 22:00 -> 02:00.
        return t >= start or t < end

    # --------------------------------------------------------- daily drawdown
    def check_daily_drawdown(self) -> bool:
        """Return ``True`` if today's total loss is within the allowed limit.

        Daily PnL = realised PnL of today's closed deals + floating PnL of
        open positions. The reference balance is the balance at the start of
        the day (current balance minus today's realised PnL).
        """
        if mt5 is None:
            log.error("MT5 unavailable; cannot evaluate daily drawdown.")
            return False

        try:
            acc = mt5.account_info()
            if acc is None:
                raise MT5ConnectionError("account_info() returned None.")

            day_start = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
            now = datetime.now()

            realised = self._realised_pnl_since(day_start, now)
            floating = self._floating_pnl()

            # Balance at day start = current balance - today's realised PnL.
            day_start_balance = acc.balance - realised
            if day_start_balance <= 0:
                day_start_balance = acc.balance or 1.0

            daily_pnl = realised + floating
            loss_pct = (-daily_pnl / day_start_balance) * 100.0 if daily_pnl < 0 else 0.0

            ok = loss_pct < config.MAX_DAILY_DRAWDOWN_PCT
            if not ok:
                log.warning(
                    "Daily drawdown limit hit: loss=%.2f%% (realised=%.2f, "
                    "floating=%.2f) vs max %.2f%%.",
                    loss_pct,
                    realised,
                    floating,
                    config.MAX_DAILY_DRAWDOWN_PCT,
                )
            return ok
        except MT5ConnectionError as exc:
            log.error("Daily drawdown check failed: %s", exc)
            return False

    @staticmethod
    def _realised_pnl_since(start: datetime, end: datetime) -> float:
        """Sum profit + swap + commission for deals closed in [start, end]."""
        if mt5 is None:
            return 0.0
        deals = mt5.history_deals_get(start, end)
        if not deals:
            return 0.0
        total = 0.0
        for d in deals:
            # DEAL_ENTRY_OUT / OUT_BY mark closing deals; include any profit-bearing deal.
            total += float(d.profit) + float(d.swap) + float(d.commission)
        return total

    @staticmethod
    def _floating_pnl() -> float:
        """Sum current floating profit across all open positions."""
        if mt5 is None:
            return 0.0
        positions = mt5.positions_get()
        if not positions:
            return 0.0
        return float(sum(p.profit + p.swap for p in positions))
