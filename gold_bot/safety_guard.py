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
        # Daily profit ratchet state
        self.peak_daily_profit: float = 0.0
        self.ratchet_locked: bool = False
        self._ratchet_day = None

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
        weekday = now.weekday()  # Mon=0 .. Sun=6

        # Weekend: no trading at all.
        if weekday >= 5:
            return config.SESSION_MODE_WEEKEND_SLEEP

        # Friday: stop new entries at 19:30, force-close from 20:15.
        if weekday == 4:
            stop_t = dtime(config.FRIDAY_STOP_HOUR, config.FRIDAY_STOP_MINUTE)
            close_t = dtime(config.FRIDAY_FORCE_CLOSE_HOUR, config.FRIDAY_FORCE_CLOSE_MINUTE)
            if t >= close_t:
                return config.SESSION_MODE_WEEKEND_CLOSE
            if t >= stop_t:
                return config.SESSION_MODE_STOP

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
            loss_usd = -daily_pnl if daily_pnl < 0 else 0.0

            ok = loss_usd < config.DAILY_LOSS_LIMIT_USD
            if not ok:
                log.warning(
                    "Daily loss limit hit: loss=$%.2f (realised=%.2f, "
                    "floating=%.2f) vs max $%.2f.",
                    loss_usd,
                    realised,
                    floating,
                    config.DAILY_LOSS_LIMIT_USD,
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

    def _daily_pnl(self) -> float:
        """Today's realised + floating PnL in USD."""
        day_start = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
        return self._realised_pnl_since(day_start, datetime.now()) + self._floating_pnl()

    def check_profit_ratchet(self, daily_pnl: Optional[float] = None,
                             now: Optional[datetime] = None) -> bool:
        """Return True if trading may continue; False once gains are locked in.

        Once peak daily profit >= PROFIT_RATCHET_START_USD, if current daily
        profit falls below PROFIT_RATCHET_KEEP_PCT * peak, lock the day.
        """
        now = now or datetime.now()
        if self._ratchet_day != now.date():
            self._ratchet_day = now.date()
            self.peak_daily_profit = 0.0
            self.ratchet_locked = False

        if daily_pnl is None:
            try:
                daily_pnl = self._daily_pnl()
            except Exception:  # noqa: BLE001
                daily_pnl = 0.0

        if daily_pnl > self.peak_daily_profit:
            self.peak_daily_profit = daily_pnl

        if self.peak_daily_profit >= config.PROFIT_RATCHET_START_USD:
            if daily_pnl < config.PROFIT_RATCHET_KEEP_PCT * self.peak_daily_profit:
                if not self.ratchet_locked:
                    log.warning(
                        "PROFIT RATCHET locked: daily=%.2f < %.0f%% of peak=%.2f",
                        daily_pnl, config.PROFIT_RATCHET_KEEP_PCT * 100,
                        self.peak_daily_profit,
                    )
                self.ratchet_locked = True

        return not self.ratchet_locked

    @staticmethod
    def _floating_pnl() -> float:
        """Sum current floating profit across all open positions."""
        if mt5 is None:
            return 0.0
        positions = mt5.positions_get()
        if not positions:
            return 0.0
        return float(sum(p.profit + p.swap for p in positions))
