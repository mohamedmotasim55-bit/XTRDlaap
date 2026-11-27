"""
main.py
=======
Entry point for the XAUUSD Gold Scalping Bot (Step 1: connection + guards).

Runs a 1-second loop that:
  1. Refreshes connection state.
  2. Evaluates the three safety guards (spread, session, daily drawdown).
  3. Logs a single, readable status line.

No trading entries are placed in this step. This file is intentionally small
so that strategy/execution modules can be layered on later.
"""

from __future__ import annotations

import logging
import signal
import sys
import time as _time
from typing import Optional

import config
from mt5_connector import MT5Connector, MT5ConnectionError
from safety_guard import SafetyGuard

log = logging.getLogger("gold_bot")

# Set by the SIGINT/SIGTERM handler to break the main loop cleanly.
_STOP = False


def _handle_signal(signum, frame) -> None:  # noqa: ANN001 - signal signature
    global _STOP
    _STOP = True
    log.info("Shutdown signal received (%s); stopping loop...", signum)


def _configure_logging() -> None:
    logging.basicConfig(
        level=getattr(logging, config.LOG_LEVEL, logging.INFO),
        format="%(asctime)s | %(levelname)-7s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )


def _format_status(
    mode: str,
    spread: Optional[float],
    spread_ok: bool,
    dd_ok: bool,
    acc: Optional[dict],
    server_time: Optional[str],
) -> str:
    """Build one human-readable status line."""
    spread_txt = f"{spread:5.1f} pts" if spread is not None else "  n/a  "
    if acc is not None:
        money = (
            f"Balance={acc['balance']:,.2f} Equity={acc['equity']:,.2f} "
            f"FreeMargin={acc['margin_free']:,.2f}"
        )
    else:
        money = "Balance=n/a Equity=n/a FreeMargin=n/a"
    return (
        f"Time={server_time or 'n/a'} | Mode={mode:<13} | Spread={spread_txt} "
        f"({'OK' if spread_ok else 'BLOCK'}) | DailyDD={'OK' if dd_ok else 'BLOCK'} "
        f"| {money}"
    )


def run() -> int:
    """Connect, then run the monitoring loop. Returns a process exit code."""
    _configure_logging()
    log.info("Starting XAUUSD Gold Scalping Bot — Step 1 (connection + guards)")

    connector = MT5Connector()
    try:
        connector.initialize()
    except MT5ConnectionError as exc:
        log.error("Initialisation failed: %s", exc)
        return 1

    guard = SafetyGuard(connector)

    signal.signal(signal.SIGINT, _handle_signal)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, _handle_signal)

    log.info("Monitoring started. Press Ctrl+C to stop.")
    try:
        while not _STOP:
            loop_start = _time.monotonic()

            try:
                mode = guard.check_session()
                spread = connector.current_spread_points()
                spread_ok = guard.check_spread()
                dd_ok = guard.check_daily_drawdown()
                acc = connector.account_info()
                srv_time = connector.server_time().strftime("%Y-%m-%d %H:%M:%S")
            except MT5ConnectionError as exc:
                log.error("Data refresh failed: %s", exc)
                acc, spread, spread_ok, dd_ok = None, None, False, False
                mode, srv_time = "UNKNOWN", None

            log.info(
                "%s",
                _format_status(mode, spread, spread_ok, dd_ok, acc, srv_time),
            )

            # Sleep the remainder of the interval (keeps cadence steady).
            elapsed = _time.monotonic() - loop_start
            _time.sleep(max(0.0, config.LOOP_INTERVAL_SEC - elapsed))
    except KeyboardInterrupt:  # pragma: no cover - interactive
        log.info("KeyboardInterrupt received.")
    finally:
        connector.shutdown()
        log.info("Bot stopped.")

    return 0


if __name__ == "__main__":
    sys.exit(run())
