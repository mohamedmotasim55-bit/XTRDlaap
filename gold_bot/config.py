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
LOT_SIZE: float = 0.01               # fixed lot for the $10 micro-account
MAX_SPREAD_POINTS: float = 38.0      # JustMarkets base ~26 pts; 38 tolerates normal vol
MAX_OPEN_TRADES: int = 1             # strict single-position cap to protect $10
DAILY_LOSS_LIMIT_USD: float = 3.00   # stop for the day past this realised+floating loss
RISK_PER_TRADE_PCT: float = 1.0      # kept for reference / future dynamic sizing
MAX_DAILY_DRAWDOWN_PCT: float = 4.0  # legacy % cap (superseded by DAILY_LOSS_LIMIT_USD)

# ---------------------------------------------------------------------------
# Trading sessions (broker / server time)
# ---------------------------------------------------------------------------
# Session windows use EXCLUSIVE end times, so the last active minute is
# (end - 1 minute). This makes the intended ranges inclusive:
#   ASIAN   : 01:00 .. 09:29  -> END = 09:30
#   MOMENTUM: 09:30 .. 21:00  -> END = 21:01
#   STOP    : 21:01 .. 00:59  (everything else)
ASIAN_RANGE_START: time = time(1, 0)
ASIAN_RANGE_END: time = time(9, 30)

# London/NY session -> momentum mode.
MOMENTUM_START: time = time(9, 30)
MOMENTUM_END: time = time(21, 1)

# Canonical session-mode strings returned by safety_guard.check_session().
SESSION_MODE_ASIAN: str = "ASIAN_RANGE"
SESSION_MODE_MOMENTUM: str = "MOMENTUM"
SESSION_MODE_STOP: str = "STOP"

# ---------------------------------------------------------------------------
# Strategy parameters
# ---------------------------------------------------------------------------
ATR_PERIOD: int = 14
MIN_ATR_POINTS: float = 35.0     # skip dead market (spread cannot be covered)
SL_ATR_MULT: float = 1.6         # momentum-mode stop distance (x ATR)
TP_ATR_MULT: float = 2.4         # momentum-mode target distance (x ATR)
COOLDOWN_SECONDS: int = 45       # wait after a close before a new entry

# Indicator periods
EMA_FAST: int = 9
EMA_MID: int = 21
EMA_SLOW: int = 50
RSI_PERIOD: int = 7
BB_PERIOD: int = 20
BB_STD: float = 2.0
VOL_MA_PERIOD: int = 10
SWING_LOOKBACK: int = 15

# Range-mode (Asian) tighter targets
RANGE_SL_ATR_MULT: float = 1.3
RANGE_TP_ATR_MULT: float = 1.8

# ---------------------------------------------------------------------------
# Execution & trade management
# ---------------------------------------------------------------------------
ENABLE_LIVE_TRADING: bool = True        # master switch: send real/demo orders to MT5
DEVIATION_POINTS: int = 20              # max allowed slippage (points)
BREAKEVEN_TRIGGER_POINTS: float = 32.0  # profit needed before SL moves to break-even
BREAKEVEN_LOCK_POINTS: float = 5.0      # lock this many points beyond entry at BE
TRAILING_START_POINTS: float = 45.0     # profit needed before trailing begins
TRAILING_ATR_MULT: float = 1.0          # trailing distance = mult * current ATR
MIN_FREE_MARGIN_USD: float = 3.50       # keep this free-margin buffer on the $10 account
SL_SAFETY_BUFFER_POINTS: float = 5.0    # extra SL distance beyond broker stops_level
TRAIL_MIN_STEP_POINTS: float = 3.0      # ignore SL moves smaller than this (avoid spam)

# ---------------------------------------------------------------------------
# News filter & resilience
# ---------------------------------------------------------------------------
ENABLE_NEWS_FILTER: bool = True     # block entries around High-Impact USD news
NEWS_PAUSE_BEFORE_MIN: int = 15     # stop entering this many minutes BEFORE a release
NEWS_PAUSE_AFTER_MIN: int = 15      # resume this many minutes AFTER a release
NEWS_FORCE_CLOSE_MIN: int = 5       # close open positions if a release is this close
CONSECUTIVE_LOSS_COOLDOWN_MIN: int = 30  # pause after 3 consecutive losses
CONSECUTIVE_LOSS_TRIGGER: int = 3
ANALYTICS_PRINT_INTERVAL_SEC: int = 900  # 15 minutes

# ---------------------------------------------------------------------------
# Friday / weekend shield
# ---------------------------------------------------------------------------
FRIDAY_STOP_HOUR: int = 19
FRIDAY_STOP_MINUTE: int = 30
FRIDAY_FORCE_CLOSE_HOUR: int = 20
FRIDAY_FORCE_CLOSE_MINUTE: int = 15
SESSION_MODE_WEEKEND_CLOSE: str = "WEEKEND_CLOSE"
SESSION_MODE_WEEKEND_SLEEP: str = "WEEKEND_SLEEP"

# ---------------------------------------------------------------------------
# Regime thresholds
# ---------------------------------------------------------------------------
ADX_TREND_THRESHOLD: float = 25.0
ATR_SPIKE_FACTOR: float = 1.4

# ---------------------------------------------------------------------------
# Adaptive brain
# ---------------------------------------------------------------------------
ROLLING_WINDOW: int = 20
STRATEGY_MUTE_MINUTES: int = 120
MIN_CONFIDENCE_TO_TRADE: float = 0.62
REGIME_BOOST: float = 0.15

# ---------------------------------------------------------------------------
# Zero-risk pyramiding
# ---------------------------------------------------------------------------
MAX_BASE_TRADES: int = 1
MAX_TOTAL_TRADES_WITH_PYRAMID: int = 2
ENABLE_ZERO_RISK_PYRAMID: bool = True

# ---------------------------------------------------------------------------
# Daily profit ratchet (equity lock)
# ---------------------------------------------------------------------------
PROFIT_RATCHET_START_USD: float = 3.00
PROFIT_RATCHET_KEEP_PCT: float = 0.70

# ---------------------------------------------------------------------------
# Dynamic lot sizing / compounding
# ---------------------------------------------------------------------------
MAX_LOT_SIZE: float = 0.50
COMPOUND_EQUITY_STEP_USD: float = 15.0
COMPOUND_START_EQUITY_USD: float = 20.0
DD_THROTTLE_PCT: float = 0.08
DD_RECOVER_PCT: float = 0.03
MARGIN_FREE_FRACTION: float = 0.40

# ---------------------------------------------------------------------------
# State persistence / log rotation
# ---------------------------------------------------------------------------
STATE_SAVE_INTERVAL_SEC: int = 30
LOG_ROTATE_MAX_BYTES: int = 5 * 1024 * 1024

# ---------------------------------------------------------------------------
# Loop / logging
# ---------------------------------------------------------------------------
LOOP_INTERVAL_SEC: float = 1.0
LOG_LEVEL: str = os.getenv("GOLD_BOT_LOG_LEVEL", "INFO").upper()
