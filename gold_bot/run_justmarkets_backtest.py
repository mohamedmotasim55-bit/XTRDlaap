"""
run_justmarkets_backtest.py
===========================
Live JustMarkets 60-day alpha discovery run.

Fetches 80,000 M1 (~60 days) and 16,000 M5 candles, then delegates to
``alpha_lab.run_tournament``: 8 models ranked on Month 1, survivors combined
and validated blind on Month 2.
"""
from __future__ import annotations

import sys

from alpha_lab import run_tournament
from mt5_connector import MT5Connector, MT5ConnectionError

M1_BARS = 80000
M5_BARS = 16000


def main() -> int:
    print("Connecting to JustMarkets MT5 ...")
    conn = MT5Connector()
    try:
        conn.initialize()
    except MT5ConnectionError as exc:
        print(f"[ABORT] MT5 unavailable: {exc}")
        return 1

    try:
        info = conn.symbol_info()
        spread = conn.current_spread_points()
        print(f"Symbol={info['symbol']} point={info['point']} "
              f"tick_value={info['tick_value']} stops={info['stops_level']} "
              f"spread={spread:.1f}pts")
        m1 = conn.get_candles(count=M1_BARS, timeframe_name="M1")
        m5 = conn.get_candles(count=M5_BARS, timeframe_name="M5")
        print(f"Fetched M1={len(m1)} bars, M5={len(m5)} bars "
              f"({m1['time'].iloc[0]} -> {m1['time'].iloc[-1]})")
    except MT5ConnectionError as exc:
        print(f"[ABORT] data fetch failed: {exc}")
        return 1

    run_tournament(m1, m5, spread=spread, point=info["point"])
    conn.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
