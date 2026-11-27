# XAUUSD Gold Scalping Bot — Step 1 (Architecture, MT5 Connection, Safety Guards)

A modular Python bot skeleton that connects to MetaTrader 5, auto-detects the
broker's XAUUSD symbol variant, and evaluates three pre-trade safety guards.
**No trading entries are placed in this step.**

## Structure

```
gold_bot/
├── config.py           # All tunable parameters (symbol, risk, sessions, ...)
├── mt5_connector.py    # MT5 init, AutoTrading check, symbol detection, candles
├── safety_guard.py     # check_spread / check_session / check_daily_drawdown
├── main.py             # 1-second monitoring loop + logging
├── requirements.txt
└── README.md
```

## Requirements

- Windows host with **MetaTrader 5** installed, running, and logged in.
- Python 3.10+.
- `pip install -r requirements.txt`

## Run

```bat
python main.py
```

You should see a status line every second, e.g.:

```
2026-11-27 14:00:01 | INFO | gold_bot | Time=2026-11-27 14:00:00 | Mode=MOMENTUM | Spread= 26.0 pts (OK) | DailyDD=OK | Balance=10.00 Equity=10.00 FreeMargin=10.00
```

## Configuration (`config.py`)

| Parameter | Default | Meaning |
|---|---|---|
| `SYMBOL_BASE` | `XAUUSD` | Base symbol; suffix auto-detected (`m`, `.raw`, ...) |
| `TIMEFRAME_NAME` | `M1` | Candle timeframe |
| `MAGIC_NUMBER` | `202699` | Bot order/position tag |
| `MAX_SPREAD_POINTS` | `30` | Block entries above this spread |
| `RISK_PER_TRADE_PCT` | `1.0` | Risk per trade (% of balance) |
| `MAX_DAILY_DRAWDOWN_PCT` | `4.0` | Stop trading past this daily loss |
| `ASIAN_RANGE_*` | `01:00–09:00` | Range mode window |
| `MOMENTUM_*` | `09:30–21:00` | Momentum mode window |
| Dead zone | `21:01–00:59` | No trading (implied) |

## Safety guards (`safety_guard.py`)

- `check_spread()` → `False` if live spread > `MAX_SPREAD_POINTS`.
- `check_session()` → `"ASIAN_RANGE"`, `"MOMENTUM"`, or `"STOP"` (server time).
- `check_daily_drawdown()` → `False` if today's realised + floating loss exceeds
  `MAX_DAILY_DRAWDOWN_PCT` of the day-start balance.

## Next steps

Step 2 will add strategy logic, position sizing, and execution — building on
these verified guards.
