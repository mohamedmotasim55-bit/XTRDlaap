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

        ticks = None
        try:
            import pandas as _pd
            start = _pd.Timestamp(m1["time"].iloc[0]).to_pydatetime()
            end = _pd.Timestamp(m1["time"].iloc[-1]).to_pydatetime() + _pd.Timedelta(minutes=1)
            ticks = conn.get_real_ticks(start, end, max_ticks=6_000_000)
            print(f"Real ticks loaded: {len(ticks)} (COPY_TICKS_ALL, no synthetic data)")
            import tick_engine as _te
            _dirs, _audit = _te.build_bar_tick_features(m1, ticks, info["point"])
            print("========== TICK DATA AUTHENTICITY AUDIT ==========")
            print(f" total real ticks      : {_audit['total_ticks']}")
            print(f" median tick interval  : {_audit['median_interval_ms']} ms")
            print(f" spread bid/ask p25/50/75 : "
                  f"{_audit['spread_p25']:.3f} / {_audit['spread_p50']:.3f} / {_audit['spread_p75']:.3f} USD")
            print(f" median spread (points)   : {_audit['spread_pts_p50']}")
            print(f" M1 bars with real burst  : {_audit['bars_with_burst']}")
            print(f" synthetic ticks          : {_audit['synthetic']}")
            print("=================================================")
        except Exception as exc:  # noqa: BLE001
            print(f"[WARN] real ticks unavailable: {exc}")
    except MT5ConnectionError as exc:
        print(f"[ABORT] data fetch failed: {exc}")
        return 1

    run_tournament(m1, m5, spread=spread, point=info["point"], ticks=ticks)
    conn.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
