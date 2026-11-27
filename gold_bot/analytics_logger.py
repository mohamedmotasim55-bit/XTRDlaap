"""
analytics_logger.py
===================
Trade journal + live performance tracker.

* Writes every opened/closed trade to ``logs/trades_journal.csv``.
* Tracks live session metrics: trades, wins, losses, win rate, net profit,
  profit factor, max consecutive losses, and a per-strategy breakdown.
* Detects bot-position closes from MT5 history deals and updates the journal.
* Prints a clean performance-summary box every 15 minutes and on shutdown.
"""

from __future__ import annotations

import csv
import logging
import os
import time
from datetime import datetime, timedelta
from typing import Dict, List, Optional

import config

log = logging.getLogger(__name__)

JOURNAL_COLUMNS = [
    "timestamp", "ticket", "strategy", "session_mode", "direction",
    "entry_price", "sl", "tp", "close_price", "profit_usd", "profit_points",
    "spread_at_entry", "atr_at_entry", "close_reason",
]


class AnalyticsLogger:
    def __init__(self, journal_path: Optional[str] = None,
                 print_interval_sec: Optional[int] = None) -> None:
        self.path = journal_path or os.path.join("logs", "trades_journal.csv")
        parent = os.path.dirname(self.path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        self._ensure_header()

        self.closed_trades: List[dict] = []
        self.open_trades: Dict[int, dict] = {}
        self.print_interval_sec = (
            print_interval_sec
            if print_interval_sec is not None
            else getattr(config, "ANALYTICS_PRINT_INTERVAL_SEC", 900)
        )
        self._last_print = 0.0
        self._consec_losses = 0
        self._max_consec_losses = 0
        self._last_loss_ts: Optional[datetime] = None

    # --------------------------------------------------------------- journal
    def _ensure_header(self) -> None:
        if not os.path.exists(self.path):
            with open(self.path, "w", newline="", encoding="utf-8") as fh:
                csv.writer(fh).writerow(JOURNAL_COLUMNS)

    def _append_row(self, rec: dict) -> None:
        try:
            with open(self.path, "a", newline="", encoding="utf-8") as fh:
                csv.writer(fh).writerow([rec.get(c, "") for c in JOURNAL_COLUMNS])
        except OSError as exc:  # pragma: no cover
            log.warning("Journal write failed: %s", exc)

    # ---------------------------------------------------------------- events
    def log_open(self, ticket: int, strategy: str, session_mode: str, direction: str,
                 entry_price: float, sl: float, tp: float,
                 spread_at_entry: float = 0.0, atr_at_entry: float = 0.0) -> None:
        rec = {
            "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "ticket": ticket, "strategy": strategy, "session_mode": session_mode,
            "direction": direction, "entry_price": entry_price, "sl": sl, "tp": tp,
            "close_price": "", "profit_usd": "", "profit_points": "",
            "spread_at_entry": spread_at_entry, "atr_at_entry": atr_at_entry,
            "close_reason": "",
        }
        self.open_trades[int(ticket)] = rec
        self._append_row(rec)

    def log_close(self, ticket: int, close_price: float, profit_usd: float,
                  profit_points: float = 0.0, close_reason: str = "") -> None:
        rec = self.open_trades.pop(int(ticket), None)
        if rec is None:
            return
        rec.update(
            close_price=close_price, profit_usd=round(float(profit_usd), 2),
            profit_points=round(float(profit_points), 1), close_reason=close_reason,
        )
        self.closed_trades.append(rec)

        if profit_usd < 0:
            self._consec_losses += 1
            self._max_consec_losses = max(self._max_consec_losses, self._consec_losses)
            self._last_loss_ts = datetime.now()
        else:
            self._consec_losses = 0

        self._append_row(rec)

    def sync_from_mt5(self, mt5, now: Optional[datetime] = None) -> None:
        """Detect bot-position closes in MT5 history and log them."""
        if mt5 is None or not self.open_trades:
            return
        now = now or datetime.now()
        frm = now - timedelta(days=3)
        to = now + timedelta(minutes=5)
        deals = mt5.history_deals_get(frm, to) or []
        for d in deals:
            if getattr(d, "magic", None) != config.MAGIC_NUMBER:
                continue
            if getattr(d, "entry", None) != getattr(mt5, "DEAL_ENTRY_OUT", 1):
                continue
            pid = getattr(d, "position_id", None)
            if pid in self.open_trades:
                profit = float(getattr(d, "profit", 0.0)) + float(getattr(d, "swap", 0.0)) \
                    + float(getattr(d, "commission", 0.0))
                self.log_close(pid, close_price=float(getattr(d, "price", 0.0)),
                               profit_usd=profit, close_reason="SL/TP")

    # --------------------------------------------------------------- metrics
    def metrics(self) -> dict:
        trades = self.closed_trades
        n = len(trades)
        wins = sum(1 for t in trades if float(t["profit_usd"]) > 0)
        losses = sum(1 for t in trades if float(t["profit_usd"]) < 0)
        gross_profit = sum(float(t["profit_usd"]) for t in trades if float(t["profit_usd"]) > 0)
        gross_loss = -sum(float(t["profit_usd"]) for t in trades if float(t["profit_usd"]) < 0)
        if gross_loss > 0:
            pf = gross_profit / gross_loss
        else:
            pf = float("inf") if gross_profit > 0 else 0.0

        by_strategy: Dict[str, dict] = {}
        for t in trades:
            s = t.get("strategy", "?")
            d = by_strategy.setdefault(s, {"n": 0, "wins": 0, "net": 0.0})
            d["n"] += 1
            d["net"] += float(t["profit_usd"])
            if float(t["profit_usd"]) > 0:
                d["wins"] += 1

        return {
            "total": n,
            "wins": wins,
            "losses": losses,
            "win_rate": (100.0 * wins / n) if n else 0.0,
            "net": sum(float(t["profit_usd"]) for t in trades),
            "pf": pf,
            "max_consec_losses": self._max_consec_losses,
            "by_strategy": by_strategy,
        }

    def consecutive_losses(self) -> int:
        return self._consec_losses

    def in_loss_cooldown(self, now: Optional[datetime] = None) -> bool:
        """True if we are within CONSECUTIVE_LOSS_COOLDOWN_MIN after a 3-loss streak."""
        if self._consec_losses < getattr(config, "CONSECUTIVE_LOSS_TRIGGER", 3):
            return False
        if self._last_loss_ts is None:
            return False
        now = now or datetime.now()
        return (now - self._last_loss_ts).total_seconds() < config.CONSECUTIVE_LOSS_COOLDOWN_MIN * 60

    # --------------------------------------------------------------- summary
    def print_summary(self) -> None:
        m = self.metrics()
        pf = "inf" if m["pf"] == float("inf") else f"{m['pf']:.2f}"
        lines = [
            "=" * 62,
            " PERFORMANCE SUMMARY",
            "-" * 62,
            f" Trades: {m['total']:<6} Wins: {m['wins']:<6} Losses: {m['losses']}",
            f" Win rate: {m['win_rate']:.1f}%   Net: ${m['net']:.2f}   PF: {pf}",
            f" Max consecutive losses: {m['max_consec_losses']}   "
            f"Current streak: {self._consec_losses}",
            "-" * 62,
            " By strategy:",
        ]
        if m["by_strategy"]:
            for name, d in m["by_strategy"].items():
                wr = (100.0 * d["wins"] / d["n"]) if d["n"] else 0.0
                lines.append(
                    f"   {name:<18} n={d['n']:<3} win={wr:5.1f}% net=${d['net']:.2f}"
                )
        else:
            lines.append("   (no closed trades yet)")
        lines.append("=" * 62)
        print("\n".join(lines))

    def maybe_print_summary(self, force: bool = False) -> None:
        now = time.monotonic()
        if force or (now - self._last_print) >= self.print_interval_sec:
            self.print_summary()
            self._last_print = now
