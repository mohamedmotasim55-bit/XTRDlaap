"""
main.py
=======
Entry point for the XAUUSD Gold Scalping Bot.

Step 2 = DRY-RUN / SIGNAL SCANNER mode:
  * 1-second loop with the three safety guards.
  * Fetches recent M1 candles, computes indicators, and evaluates the
    multi-strategy brain for the active session mode.
  * Prints a clear "SIGNAL DETECTED" alert when a setup fires.
  * NO real orders are placed.
"""

from __future__ import annotations

import logging
import signal
import sys
import time as _time
from typing import Optional

import config
import indicators
import strategy_engine
from mt5_connector import MT5Connector, MT5ConnectionError
from safety_guard import SafetyGuard

log = logging.getLogger("gold_bot")

_STOP = False
_LAST_SIGNAL_TS: Optional[float] = None  # monotonic time of last printed signal


def _handle_signal(signum, frame) -> None:  # noqa: ANN001
    global _STOP
    _STOP = True
    log.info("Shutdown signal received (%s); stopping...", signum)


def _configure_logging() -> None:
    logging.basicConfig(
        level=getattr(logging, config.LOG_LEVEL, logging.INFO),
        format="%(asctime)s | %(levelname)-7s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )


def _format_status(mode, spread, spread_ok, dd_ok, acc, server_time) -> str:
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


def _scan_for_signal(connector: MT5Connector, mode: str, spread_ok: bool, dd_ok: bool) -> None:
    """Fetch candles, evaluate the brain, and print any actionable signal."""
    global _LAST_SIGNAL_TS

    if mode == config.SESSION_MODE_STOP:
        return
    if not (spread_ok and dd_ok):
        return

    try:
        point = connector.symbol_info().get("point", 0.01)
        df = connector.get_candles(count=config.CANDLE_LOOKBACK)
        df = indicators.add_indicators(df, point=point)
        sig = strategy_engine.generate_signal(df, mode)
    except MT5ConnectionError as exc:
        log.error("Signal scan failed: %s", exc)
        return

    if not sig:
        return

    # Cooldown: avoid spamming the same setup on consecutive ticks.
    now = _time.monotonic()
    if _LAST_SIGNAL_TS is not None and (now - _LAST_SIGNAL_TS) < config.COOLDOWN_SECONDS:
        return
    _LAST_SIGNAL_TS = now

    log.warning(
        "SIGNAL DETECTED: %s via %s | Entry=%.3f | SL=%.3f | TP=%.3f | ATR=%.1f pts",
        sig.signal,
        sig.strategy,
        sig.entry,
        sig.sl,
        sig.tp,
        sig.atr_points,
    )


def run() -> int:
    _configure_logging()
    log.info("Starting XAUUSD Gold Bot — Step 2 (dry-run signal scanner)")

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

    log.info("Scanner started. Press Ctrl+C to stop. (No orders are placed.)")
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

            log.info("%s", _format_status(mode, spread, spread_ok, dd_ok, acc, srv_time))
            _scan_for_signal(connector, mode, spread_ok, dd_ok)

            elapsed = _time.monotonic() - loop_start
            _time.sleep(max(0.0, config.LOOP_INTERVAL_SEC - elapsed))
    except KeyboardInterrupt:  # pragma: no cover
        log.info("KeyboardInterrupt received.")
    finally:
        connector.shutdown()
        log.info("Bot stopped.")
    return 0


if __name__ == "__main__":
    sys.exit(run())
