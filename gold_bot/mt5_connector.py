"""
mt5_connector.py
================
Defensive wrapper around the ``MetaTrader5`` Python package.

Responsibilities
----------------
* Initialise / shut down the terminal connection.
* Verify that AutoTrading (algo trading) is enabled on the terminal.
* Auto-detect the broker's symbol suffix (XAUUSD -> XAUUSDm / XAUUSD.raw ...).
* Expose symbol metadata (point, tick size, stops level, live spread).
* Return recent OHLCV candles as a ``pandas.DataFrame``.
* Provide lightweight account info helpers.

The module imports ``MetaTrader5`` lazily so that importing it on a
non-Windows machine (where the package is unavailable) does not crash;
calls that actually need MT5 raise :class:`MT5ConnectionError` instead.
"""

from __future__ import annotations

import logging
from typing import Dict, Optional

try:  # pandas is required at runtime; keep import defensive for portability.
    import pandas as pd  # type: ignore
except ImportError:  # pragma: no cover - expected on minimal hosts
    pd = None  # type: ignore

try:  # MT5 is Windows-only; keep import defensive for portability.
    import MetaTrader5 as mt5  # type: ignore
except ImportError:  # pragma: no cover - expected on non-Windows hosts
    mt5 = None  # type: ignore

import config

log = logging.getLogger(__name__)


class MT5ConnectionError(RuntimeError):
    """Raised when the terminal connection or a required MT5 call fails."""


class MT5Connector:
    """Owns the MT5 connection and exposes read-only market/account helpers."""

    def __init__(self) -> None:
        self.symbol: Optional[str] = None
        self._initialized: bool = False

    # ------------------------------------------------------------------ setup
    def initialize(self) -> bool:
        """Connect to MT5, verify AutoTrading, and resolve the symbol.

        Returns ``True`` on success. Raises :class:`MT5ConnectionError` on any
        fatal problem so callers can fail fast.
        """
        if mt5 is None:
            raise MT5ConnectionError(
                "The 'MetaTrader5' package is not available. Install it on a "
                "Windows host (pip install MetaTrader5) with the MT5 terminal "
                "running and logged in."
            )

        if not mt5.initialize():
            code, msg = mt5.last_error()
            raise MT5ConnectionError(f"mt5.initialize() failed: [{code}] {msg}")

        self._initialized = True

        terminal = mt5.terminal_info()
        if terminal is None:
            raise MT5ConnectionError("terminal_info() returned None.")
        if not terminal.trade_allowed:
            # Not fatal for read-only monitoring, but warn loudly.
            log.warning(
                "AutoTrading is DISABLED in the terminal. Enable it before "
                "live entries (Tools > Options > Expert Advisors)."
            )
        log.info(
            "Connected to MT5: %s (build %s), trade_allowed=%s, dlls_allowed=%s",
            terminal.company,
            terminal.build,
            terminal.trade_allowed,
            terminal.dlls_allowed,
        )

        self.symbol = self._detect_symbol()
        self._ensure_symbol_selected(self.symbol)
        info = mt5.symbol_info(self.symbol)
        if info is None:
            raise MT5ConnectionError(f"symbol_info('{self.symbol}') returned None.")
        log.info(
            "Symbol resolved: %s | digits=%s point=%s tick_size=%s "
            "stops_level=%s spread=%s pts",
            self.symbol,
            info.digits,
            info.point,
            info.trade_tick_size,
            info.trade_stops_level,
            self.current_spread_points(),
        )
        return True

    def shutdown(self) -> None:
        """Cleanly close the MT5 connection."""
        if mt5 is not None and self._initialized:
            mt5.shutdown()
            self._initialized = False
            log.info("MT5 connection closed.")

    # ------------------------------------------------------------- discovery
    def _detect_symbol(self) -> str:
        """Return the first existing symbol name from the suffix candidates."""
        if mt5 is None:
            raise MT5ConnectionError("MT5 package unavailable.")
        for suffix in config.SYMBOL_SUFFIX_CANDIDATES:
            candidate = f"{config.SYMBOL_BASE}{suffix}"
            if mt5.symbol_info(candidate) is not None:
                return candidate
        raise MT5ConnectionError(
            "Could not find any of the candidate symbols "
            f"{[config.SYMBOL_BASE + s for s in config.SYMBOL_SUFFIX_CANDIDATES]}. "
            "Check that the symbol is available on this account."
        )

    @staticmethod
    def _ensure_symbol_selected(symbol: str) -> None:
        """Make sure ``symbol`` is visible in Market Watch (required for ticks)."""
        if mt5 is None:
            return
        info = mt5.symbol_info(symbol)
        if info is not None and not info.visible:
            if not mt5.symbol_select(symbol, True):
                log.warning("symbol_select(%s, True) failed; ticks may be stale.", symbol)

    # --------------------------------------------------------------- metadata
    def symbol_info(self) -> Dict[str, float]:
        """Return a dict of the most useful symbol metadata."""
        if mt5 is None or self.symbol is None:
            raise MT5ConnectionError("Not initialised.")
        info = mt5.symbol_info(self.symbol)
        if info is None:
            raise MT5ConnectionError(f"symbol_info('{self.symbol}') returned None.")
        return {
            "symbol": self.symbol,
            "digits": info.digits,
            "point": info.point,
            "tick_size": info.trade_tick_size,
            "tick_value": info.trade_tick_value,
            "stops_level": info.trade_stops_level,
            "volume_min": info.volume_min,
            "volume_step": info.volume_step,
            "spread_points": self.current_spread_points(),
        }

    def current_spread_points(self) -> Optional[float]:
        """Return the live spread in points, or ``None`` if no tick is available."""
        if mt5 is None or self.symbol is None:
            return None
        info = mt5.symbol_info(self.symbol)
        tick = mt5.symbol_info_tick(self.symbol)
        if info is None or tick is None or info.point <= 0:
            return None
        return (tick.ask - tick.bid) / info.point

    def account_info(self) -> Dict[str, float]:
        """Return key account figures (balance, equity, margin, free margin)."""
        if mt5 is None:
            raise MT5ConnectionError("MT5 package unavailable.")
        acc = mt5.account_info()
        if acc is None:
            raise MT5ConnectionError("account_info() returned None.")
        return {
            "login": acc.login,
            "balance": acc.balance,
            "equity": acc.equity,
            "margin": acc.margin,
            "margin_free": acc.margin_free,
            "profit": acc.profit,
            "currency": acc.currency,
            "leverage": acc.leverage,
        }

    def server_time(self):
        """Return the broker server datetime (from the latest tick)."""
        if mt5 is None or self.symbol is None:
            raise MT5ConnectionError("Not initialised.")
        if pd is None:
            raise MT5ConnectionError("pandas is required for server_time().")
        tick = mt5.symbol_info_tick(self.symbol)
        if tick is None:
            raise MT5ConnectionError("symbol_info_tick() returned None.")
        return pd.Timestamp(tick.time, unit="s")

    # ---------------------------------------------------------------- candles
    def get_real_ticks(self, date_from, date_to, day_chunk: int = 5,
                       max_ticks: int = 3_000_000):
        """Fetch 100% authentic broker ticks (bid/ask/time_msc) via COPY_TICKS_ALL.

        The range is fetched in ``day_chunk`` windows so the terminal never
        times out on multi-week requests, then the newest ``max_ticks`` are kept.
        """
        if mt5 is None or self.symbol is None:
            raise MT5ConnectionError("Not initialised.")
        import datetime as _dt
        frames = []
        cur = date_from
        while cur < date_to:
            end = min(cur + _dt.timedelta(days=day_chunk), date_to)
            ticks = mt5.copy_ticks_range(self.symbol, cur, end, mt5.COPY_TICKS_ALL)
            if ticks is not None and len(ticks):
                frames.append(pd.DataFrame(ticks))
            cur = end
        if not frames:
            raise MT5ConnectionError("copy_ticks_range returned no ticks.")
        df = pd.concat(frames, ignore_index=True)
        if len(df) > max_ticks:
            df = df.iloc[-max_ticks:]
        return df.reset_index(drop=True)

    def get_candles(self, count: int = None, timeframe_name: str = None) -> pd.DataFrame:
        """Return the most recent OHLCV candles as a DataFrame.

        Columns: ``time, open, high, low, close, tick_volume, spread, real_volume``.
        ``time`` is a timezone-naive ``pandas.Timestamp`` in server time.
        """
        if mt5 is None or self.symbol is None:
            raise MT5ConnectionError("Not initialised.")
        if pd is None:
            raise MT5ConnectionError("pandas is required for get_candles().")
        count = count or config.CANDLE_LOOKBACK
        timeframe_name = timeframe_name or config.TIMEFRAME_NAME

        tf = self._resolve_timeframe(timeframe_name)
        rates = mt5.copy_rates_from_pos(self.symbol, tf, 0, count)
        if rates is None or len(rates) == 0:
            code, msg = mt5.last_error()
            raise MT5ConnectionError(f"copy_rates_from_pos returned no data: [{code}] {msg}")

        df = pd.DataFrame(rates)
        df["time"] = pd.to_datetime(df["time"], unit="s")
        df = df.rename(
            columns={
                "tick_volume": "tick_volume",
                "real_volume": "real_volume",
            }
        )
        return df[
            ["time", "open", "high", "low", "close", "tick_volume", "spread", "real_volume"]
        ]

    @staticmethod
    def _resolve_timeframe(name: str) -> int:
        """Map a timeframe name ("M1", "M5", ...) to an MT5 constant."""
        if mt5 is None:
            raise MT5ConnectionError("MT5 package unavailable.")
        mapping = {
            "M1": mt5.TIMEFRAME_M1,
            "M5": mt5.TIMEFRAME_M5,
            "M15": mt5.TIMEFRAME_M15,
            "M30": mt5.TIMEFRAME_M30,
            "H1": mt5.TIMEFRAME_H1,
            "H4": mt5.TIMEFRAME_H4,
            "D1": mt5.TIMEFRAME_D1,
        }
        if name not in mapping:
            raise MT5ConnectionError(f"Unsupported timeframe: {name}")
        return mapping[name]
