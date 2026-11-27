"""
main.py
=======
XAUUSD Gold Scalping Bot — Step 4 (news shield + M5 filter + analytics).

Each 1-second tick:
  1. Refresh guards + account + news state.
  2. ALWAYS manage open positions first (break-even / trailing).
  3. Close positions ahead of a high-impact news release if required.
  4. If guards + news + loss-cooldown + gating all pass, evaluate the brain
     (M1 + M5 trend filter) and execute a signal.
  5. Sync analytics from MT5 history and print a summary every 15 minutes.
"""
from __future__ import annotations

import logging
import signal as _signal
import sys
import time as _time
from datetime import datetime, timezone
from typing import Optional

import config
import indicators
import regime_detector
import strategy_engine
import trade_manager as tm_module
from adaptive_brain import AdaptiveBrain
from analytics_logger import AnalyticsLogger
from state_persistence import StatePersistence
from mt5_connector import MT5Connector, MT5ConnectionError
from news_filter import NewsFilter
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


def _format_status(mode, spread, spread_ok, dd_ok, news_ok, acc, server_time) -> str:
    spread_txt = f"{spread:5.1f} pts" if spread is not None else "  n/a  "
    if acc is not None:
        money = (f"Bal={acc['balance']:,.2f} Eq={acc['equity']:,.2f} "
                 f"FreeM={acc['margin_free']:,.2f}")
    else:
        money = "Bal=n/a Eq=n/a FreeM=n/a"
    return (f"Time={server_time or 'n/a'} | Mode={mode:<13} | Spread={spread_txt} "
            f"({'OK' if spread_ok else 'BLOCK'}) | DD={'OK' if dd_ok else 'BLOCK'} | "
            f"News={'OK' if news_ok else 'BLOCK'} | {money}")


def _register_new_position(manager, analytics, sig, mode, spread_pts, atr):
    """Find a freshly-opened bot position and log it to the journal."""
    try:
        existing = set(analytics.open_trades.keys())
        for p in manager._positions():
            if p.magic != config.MAGIC_NUMBER or p.ticket in existing:
                continue
            analytics.log_open(
                ticket=p.ticket, strategy=sig.strategy, session_mode=mode,
                direction=sig.signal, entry_price=p.price_open, sl=p.sl, tp=p.tp,
                spread_at_entry=spread_pts or 0.0, atr_at_entry=atr or 0.0,
            )
            return
    except Exception as exc:  # noqa: BLE001
        log.error("Failed to register new position: %s", exc)


def _try_reconnect(connector, attempts: int = 3) -> bool:
    """Self-healing watchdog: shut down and re-initialise MT5 with backoff."""
    for i in range(attempts):
        try:
            connector.shutdown()
        except Exception:  # noqa: BLE001
            pass
        try:
            connector.initialize()
            log.warning("MT5 reconnected (attempt %d/%d).", i + 1, attempts)
            return True
        except MT5ConnectionError as exc:
            log.error("Reconnect attempt %d/%d failed: %s", i + 1, attempts, exc)
            _time.sleep(min(30, 5 * (i + 1)))
    log.error("MT5 reconnect failed after %d attempts; will retry next loop.", attempts)
    return False


def run() -> int:
    _configure_logging()
    log.info("Starting XAUUSD Gold Bot — Step 5 (7-strategy matrix + regime + weekend)")

    connector = MT5Connector()
    try:
        connector.initialize()
    except MT5ConnectionError as exc:
        log.error("Initialisation failed: %s", exc)
        return 1

    guard = SafetyGuard(connector)
    manager = tm_module.TradeManager(connector)
    brain = AdaptiveBrain()
    adaptive_fed = 0
    news = NewsFilter()
    analytics = AnalyticsLogger()
    news.refresh()

    # --- restore persisted 30-day state -------------------------------------
    sp = StatePersistence()
    _state = sp.load()
    if _state:
        try:
            brain.import_state(_state.get("adaptive_brain"))
            manager.peak_equity = float(_state.get("peak_equity", 0.0) or 0.0)
            guard.peak_daily_profit = float(_state.get("peak_daily_profit", 0.0) or 0.0)
            guard.ratchet_locked = bool(_state.get("ratchet_locked", False))
            log.info("State restored: peak_equity=%.2f peak_daily=%.2f locked=%s",
                     manager.peak_equity, guard.peak_daily_profit, guard.ratchet_locked)
        except Exception as exc:  # noqa: BLE001
            log.warning("State restore failed: %s", exc)

    _signal.signal(_signal.SIGINT, _handle_signal)
    if hasattr(_signal, "SIGTERM"):
        _signal.signal(_signal.SIGTERM, _handle_signal)

    log.info("Bot started (LIVE=%s, NEWS=%s).", config.ENABLE_LIVE_TRADING,
             config.ENABLE_NEWS_FILTER)
    try:
        while not _STOP:
            loop_start = _time.monotonic()
            df = df_m5 = None
            latest_atr = None
            news_ok = True
            try:
                mode = guard.check_session()
                spread = connector.current_spread_points()
                spread_ok = guard.check_spread()
                dd_ok = guard.check_daily_drawdown()
                acc = connector.account_info()
                srv_time = connector.server_time().strftime("%Y-%m-%d %H:%M:%S")

                # --- Friday / weekend shield ---
                if mode == config.SESSION_MODE_WEEKEND_SLEEP:
                    log.info("Weekend sleep — market closed, no trading.")
                elif mode == config.SESSION_MODE_WEEKEND_CLOSE:
                    closed = manager.close_all_positions("Weekend Close")
                    log.warning("Friday weekend close: closed %d position(s).", closed)

                # --- news shield ---
                now_utc = datetime.now(timezone.utc)
                if config.ENABLE_NEWS_FILTER:
                    danger, title = news.is_news_danger_zone(now_utc)
                    news_ok = not danger
                    if danger:
                        log.info("NEWS DANGER: %s — entries paused.", title)
                    if news.should_close_before_news(now_utc):
                        closed = manager.close_all_positions("news")
                        if closed:
                            log.warning("Closed %d position(s) before news.", closed)

                df_m15 = None
                tradeable = (
                    mode in (config.SESSION_MODE_ASIAN, config.SESSION_MODE_MOMENTUM)
                    and spread_ok and dd_ok
                )
                if tradeable:
                    point = connector.symbol_info().get("point", 0.01)
                    df = indicators.add_indicators(
                        connector.get_candles(count=config.CANDLE_LOOKBACK), point=point)
                    latest_atr = float(df["atr_14"].iloc[-1])
                    df_m5 = connector.get_candles(count=120, timeframe_name="M5")
                    try:
                        df_m15 = connector.get_candles(count=120, timeframe_name="M15")
                    except MT5ConnectionError:
                        df_m15 = None
            except MT5ConnectionError as exc:
                log.error("Data refresh failed: %s", exc)
                acc, spread, spread_ok, dd_ok = None, None, False, False
                mode, srv_time, news_ok = "UNKNOWN", None, False
                _try_reconnect(connector)

            log.info("%s", _format_status(mode, spread, spread_ok, dd_ok, news_ok, acc, srv_time))

            # 1) Protect existing trades first.
            try:
                manager.manage_open_positions(latest_atr)
                analytics.sync_from_mt5(tm_module.mt5)
                while adaptive_fed < len(analytics.closed_trades):
                    _t = analytics.closed_trades[adaptive_fed]
                    brain.record_trade(_t.get("strategy", ""),
                                       float(_t.get("profit_usd", 0) or 0))
                    adaptive_fed += 1
            except Exception as exc:  # noqa: BLE001
                log.error("Position management error: %s", exc)

            # 2) Consider a new entry.
            if df is not None and spread_ok and dd_ok and news_ok \
                    and mode in (config.SESSION_MODE_ASIAN, config.SESSION_MODE_MOMENTUM):
                try:
                    if analytics.in_loss_cooldown():
                        log.debug("Entry blocked: consecutive-loss cooldown.")
                    elif not guard.check_profit_ratchet():
                        log.debug("Entry blocked: daily profit ratchet locked.")
                    else:
                        regime = regime_detector.RegimeDetector.classify(df, df_m5)
                        sig = strategy_engine.generate_signal(
                            df, mode, df_m5, regime=regime, df_m15=df_m15)
                        if sig:
                            allowed, conf, why = brain.evaluate(sig, regime)
                            if not allowed:
                                log.debug("Signal blocked by brain: %s", why)
                            elif manager.can_open_new_trade(sig.signal) \
                                    and manager.execute_signal(sig):
                                _register_new_position(manager, analytics, sig, mode,
                                                       spread, latest_atr)
                except Exception as exc:  # noqa: BLE001
                    log.error("Signal/execution error: %s", exc)

            # Active dynamic lot (for the status line / monitoring).
            try:
                _eq = float(getattr(acc, "equity", 0.0) or 10.0) if acc else 10.0
                _lot = manager.lot_sizer.size(_eq, manager.peak_equity or _eq)
                log.info("Dynamic lot=%.2f | %s", _lot, manager.lot_sizer.last_reason)
            except Exception:  # noqa: BLE001
                pass

            # Persist state (interval-gated) + rotate oversized logs.
            sp.update(peak_equity=manager.peak_equity,
                      peak_daily_profit=guard.peak_daily_profit,
                      ratchet_locked=guard.ratchet_locked,
                      adaptive_brain=brain.export_state())
            sp.save()
            if int(_time.time()) % 300 == 0:
                sp.rotate_logs_if_needed()

            analytics.maybe_print_summary()
            elapsed = _time.monotonic() - loop_start
            _time.sleep(max(0.0, config.LOOP_INTERVAL_SEC - elapsed))
    except KeyboardInterrupt:  # pragma: no cover
        log.info("KeyboardInterrupt received.")
    finally:
        try:
            analytics.print_summary()
        except Exception:  # noqa: BLE001
            pass
        connector.shutdown()
        log.info("Bot stopped.")
    return 0


if __name__ == "__main__":
    sys.exit(run())
