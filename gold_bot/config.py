"""
config.py
=========
Central configuration for the XAUUSD Gold Scalping Bot.

Every tunable parameter lives here; no other module should hard-code
trading values. Import this module and read the constants.

Sessions are expressed in *broker/server time* (the time returned by the
MT5 terminal), not local machine time.
"""

from __future__ import annotations

import os
from datetime import time
from typing import List

# ---------------------------------------------------------------------------
# MT5 / symbol
# ---------------------------------------------------------------------------
# Base symbol name. Brokers often append a suffix (XAUUSDm, XAUUSD.raw, ...).
# The connector will try each candidate below and pick the first one that
# exists on the account.
SYMBOL_BASE: str = "XAUUSD"
SYMBOL_SUFFIX_CANDIDATES: List[str] = [
    "",        # XAUUSD
    "m",       # XAUUSDm
    ".m",      # XAUUSD.m
    ".raw",    # XAUUSD.raw
    "r",       # XAUUSDr
    ".r",      # XAUUSD.r
    "micro",   # XAUUSDmicro
    ".pro",    # XAUUSD.pro
    ".ecn",    # XAUUSD.ecn
]

# Chart timeframe used for signal/candle logic (M1 = 1 minute).
TIMEFRAME_NAME: str = "M1"
CANDLE_LOOKBACK: int = 300  # number of recent candles fetched per call

# Unique identifier so the bot only manages its own orders/positions.
MAGIC_NUMBER: int = 202699

# ---------------------------------------------------------------------------
# Risk / safety
# ---------------------------------------------------------------------------
MAX_SPREAD_POINTS: float = 30.0      # block entries when spread (points) exceeds this
RISK_PER_TRADE_PCT: float = 1.0      # % of account balance risked per trade
MAX_DAILY_DRAWDOWN_PCT: float = 4.0  # stop trading for the day past this loss %

# ---------------------------------------------------------------------------
# Trading sessions (broker / server time)
# ---------------------------------------------------------------------------
# Asian session -> range/mean-reversion mode.
ASIAN_RANGE_START: time = time(1, 0)
ASIAN_RANGE_END: time = time(9, 0)

# London/NY session -> momentum mode.
MOMENTUM_START: time = time(9, 30)
MOMENTUM_END: time = time(21, 0)

# Dead zone (no trading): 21:01 -> 00:59 is implied by being outside both
# windows above, so no explicit constant is required.

# Canonical session-mode strings returned by safety_guard.check_session().
SESSION_MODE_ASIAN: str = "ASIAN_RANGE"
SESSION_MODE_MOMENTUM: str = "MOMENTUM"
SESSION_MODE_STOP: str = "STOP"

# ---------------------------------------------------------------------------
# Loop / logging
# ---------------------------------------------------------------------------
LOOP_INTERVAL_SEC: float = 1.0
LOG_LEVEL: str = os.getenv("GOLD_BOT_LOG_LEVEL", "INFO").upper()
