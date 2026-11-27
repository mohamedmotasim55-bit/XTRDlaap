"""
run_justmarkets_backtest.py
===========================
Standalone live-data backtest against the connected JustMarkets MT5 terminal.
Fetches real M1 (10,000) and M5 (2,500) XAUUSD candles + real point/tick_value/
live spread, runs BacktestRunner at $10 balance, prints the Institutional
Backtest Report, then a parameter-sensitivity sweep over
BREAKEVEN_TRIGGER_POINTS [35,45,60] x TP_ATR_MULT [1.3,1.6,2.0].
"""
from __future__ import annotations
import sys
import config
from backtest_runner import BacktestRunner
from mt5_connector import MT5Connector, MT5ConnectionError


def _fmt_pf(pf):
    return "inf" if pf == float("inf") else f"{pf:.2f}"


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
        m1 = conn.get_candles(count=10000, timeframe_name="M1")
        m5 = conn.get_candles(count=2500, timeframe_name="M5")
        print(f"Fetched M1={len(m1)} bars, M5={len(m5)} bars")
    except MT5ConnectionError as exc:
        print(f"[ABORT] data fetch failed: {exc}")
        return 1

    common = dict(initial_balance=10.0, spread_points=spread, point=info["point"])

    print("\n########## BASELINE (current settings) ##########")
    BacktestRunner(m1, m5, journal_path="logs/backtest_baseline.csv", **common).run()

    print("\n########## PARAMETER SENSITIVITY ##########")
    print(f"{'BE':>4} {'TP':>5} {'PF':>6} {'MaxDD$':>8} {'Net$':>8} {'Trades':>7}")
    orig_be, orig_tp = config.BREAKEVEN_TRIGGER_POINTS, config.TP_ATR_MULT
    rows = []
    try:
        for be in (35, 45, 60):
            for tp in (1.3, 1.6, 2.0):
                config.BREAKEVEN_TRIGGER_POINTS = be
                config.TP_ATR_MULT = tp
                r = BacktestRunner(m1, m5, journal_path=f"logs/bt_be{be}_tp{tp}.csv",
                                   verbose=False, **common).run()
                rows.append((be, tp, r))
                print(f"{be:>4} {tp:>5} {_fmt_pf(r['profit_factor']):>6} "
                      f"{r['max_drawdown_usd']:>8.2f} {r['net_profit']:>8.2f} "
                      f"{r['total_trades']:>7}")
    finally:
        config.BREAKEVEN_TRIGGER_POINTS, config.TP_ATR_MULT = orig_be, orig_tp

    def score(r):
        pf = r["profit_factor"] if r["profit_factor"] != float("inf") else 99.0
        return pf - r["max_drawdown_usd"] / 10.0

    best = max(rows, key=lambda x: score(x[2]))
    print(f"\nBEST: BE={best[0]} TP={best[1]} PF={_fmt_pf(best[2]['profit_factor'])} "
          f"MaxDD=${best[2]['max_drawdown_usd']:.2f} Net=${best[2]['net_profit']:.2f}")
    conn.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
