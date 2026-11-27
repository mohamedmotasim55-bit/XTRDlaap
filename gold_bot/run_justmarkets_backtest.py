"""
run_justmarkets_backtest.py
===========================
Live JustMarkets validation over a full month.

Fetches 40,000 M1 (~30 trading days) and 8,500 M5 candles, then runs:
  1. 30-day continuous simulation with the anti-Martingale lot sizer.
  2. In-sample (first half) vs out-of-sample (second half) walk-forward.

Prints the Institutional Backtest Report for each window plus a side-by-side
summary so overfitting is visible at a glance.
"""
from __future__ import annotations
import sys
import config
from backtest_runner import BacktestRunner
from mt5_connector import MT5Connector, MT5ConnectionError

M1_BARS = 40000
M5_BARS = 8500


def _fmt_pf(pf):
    return "inf" if pf == float("inf") else f"{pf:.2f}"


def _summary(label, r):
    print(f" {label:<14}{r['total_trades']:>7}{r['win_rate']:>7.1f}%"
          f"{_fmt_pf(r['profit_factor']):>7}{r['net_profit']:>9.2f}"
          f"{r['max_drawdown_pct']:>8.1f}%{r['final_balance']:>9.2f}")


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

    common = dict(initial_balance=10.0, spread_points=spread, point=info["point"],
                  use_dynamic_lots=True)

    print("\n########## 30-DAY CONTINUOUS (dynamic lots) ##########")
    r30 = BacktestRunner(m1, m5, journal_path="logs/backtest_30d.csv", **common).run()

    cut = m1["time"].iloc[len(m1) // 2]
    m1_is, m1_oos = m1[m1["time"] < cut], m1[m1["time"] >= cut]
    m5_is, m5_oos = m5[m5["time"] < cut], m5[m5["time"] >= cut]
    print(f"\nWalk-forward cut at {cut} | IS M1={len(m1_is)} OOS M1={len(m1_oos)}")

    print("\n########## IN-SAMPLE (first 15 days) ##########")
    r_is = BacktestRunner(m1_is, m5_is, journal_path="logs/backtest_is.csv", **common).run()
    print("\n########## OUT-OF-SAMPLE (last 15 days) ##########")
    r_oos = BacktestRunner(m1_oos, m5_oos, journal_path="logs/backtest_oos.csv", **common).run()

    print("\n########## WALK-FORWARD SUMMARY ##########")
    print(f" {'Window':<14}{'Trades':>7}{'Win%':>8}{'PF':>7}{'Net$':>9}{'MaxDD%':>8}{'Final$':>9}")
    _summary("30-day", r30)
    _summary("In-sample", r_is)
    _summary("Out-of-sample", r_oos)

    conn.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
