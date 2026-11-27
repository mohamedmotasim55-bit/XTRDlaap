"""
main.py
=======
XAUUSD Gold Scalping Bot — Step 3 (live execution + position manager).

Each 1-second tick:
  1. Refresh guards (spread / session / daily drawdown) + account info.
  2. ALWAYS run trade_manager.manage_open_positions(latest_atr) first, so open
     trades are protected (break-even / trailing) even if the session changes
     or the spread spikes.
  3. If every guard passes and can_open_new_trade() is True, evaluate the
     strategy brain and execute a signal.
"""
from __future__ import annotations

import logging
import signal as _signal
import sys
import time as _time
from typing import Optional

import config
import indicators
import strategy_engine
import trade_manager as tm_module
from mt5_connector import MT5Connector, MT5ConnectionError
from safety_guard import SafetyGuard

log = logging.getLogger("gold_bot")
_STOP = False


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


def _log_positions(manager, connector) -> None:
    """Print a concise line per open bot position (profit $ / pts / SL / status)."""
    try:
        info = connector.symbol_info()
        tick = mt5_tick(connector)
    except Exception:  # noqa: BLE001 - never let logging break the loop
        return
    positions = manager._positions()
    for p in positions:
        if p.magic != config.MAGIC_NUMBER:
            continue
        point = info.get("point", 0.01)
        if p.type == 0:  # POSITION_TYPE_BUY
            pts = (tick.bid - p.price_open) / point
        else:
            pts = (p.price_open - tick.ask) / point
        status = "OPEN"
        if pts >= config.TRAILING_START_POINTS:
            status = "TRAILING"
        elif pts >= config.BREAKEVEN_TRIGGER_POINTS:
            status = "BREAKEVEN"
        log.info(
            "POS #%s %s vol=%.2f | Profit=$%.2f (%.1f pts) | SL=%.3f TP=%.3f | %s",
            p.ticket, "BUY" if p.type == 0 else "SELL", p.volume,
            p.profit, pts, p.sl, p.tp, status,
        )


def mt5_tick(connector):
    import MetaTrader5 as mt5  # local import; defensive at runtime
    return mt5.symbol_info_tick(connector.symbol)


def run() -> int:
    _configure_logging()
    log.info("Starting XAUUSD Gold Bot — Step 3 (execution + manager)")

    connector = MT5Connector()
    try:
        connector.initialize()
    except MT5ConnectionError as exc:
        log.error("Initialisation failed: %s", exc)
        return 1

    guard = SafetyGuard(connector)
    manager = tm_module.TradeManager(connector)

    _signal.signal(_signal.SIGINT, _handle_signal)
    if hasattr(_signal, "SIGTERM"):
        _signal.signal(_signal.SIGTERM, _handle_signal)

    log.info("Bot started (ENABLE_LIVE_TRADING=%s).", config.ENABLE_LIVE_TRADING)
    try:
        while not _STOP:
            loop_start = _time.monotonic()
            df = None
            latest_atr: Optional[float] = None

            try:
                mode = guard.check_session()
                spread = connector.current_spread_points()
                spread_ok = guard.check_spread()
                dd_ok = guard.check_daily_drawdown()
                acc = connector.account_info()
                srv_time = connector.server_time().strftime("%Y-%m-%d %H:%M:%S")

                if mode != config.SESSION_MODE_STOP and spread_ok and dd_ok:
                    point = connector.symbol_info().get("point", 0.01)
                    df = indicators.add_indicators(
                        connector.get_candles(count=config.CANDLE_LOOKBACK), point=point
                    )
                    latest_atr = float(df["atr_14"].iloc[-1])
            except MT5ConnectionError as exc:
                log.error("Data refresh failed: %s", exc)
                acc, spread, spread_ok, dd_ok = None, None, False, False
                mode, srv_time = "UNKNOWN", None

            log.info("%s", _format_status(mode, spread, spread_ok, dd_ok, acc, srv_time))

            # 1) Protect existing trades first — always.
            try:
                manager.manage_open_positions(latest_atr)
                _log_positions(manager, connector)
            except Exception as exc:  # noqa: BLE001
                log.error("Position management error: %s", exc)

            # 2) Consider a new entry only if all guards + gating pass.
            if df is not None and spread_ok and dd_ok and mode != config.SESSION_MODE_STOP:
                try:
                    if manager.can_open_new_trade():
                        sig = strategy_engine.generate_signal(df, mode)
                        if sig:
                            manager.execute_signal(sig)
                    elif manager.last_error:
                        log.debug("Entry blocked: %s", manager.last_error)
                except Exception as exc:  # noqa: BLE001
                    log.error("Signal/execution error: %s", exc)

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
