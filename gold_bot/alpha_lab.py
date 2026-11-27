"""
alpha_lab.py
============
60-day alpha discovery lab.

Month 1 (days 1-30) is the discovery window: every pure-scalping model is run
standalone and ranked.  Only models passing PF >= 1.15 and MaxDD <= 40% survive.  The
survivors are then combined into one portfolio and run blind on Month 2.
"""
from __future__ import annotations

import pandas as pd

import config
from backtest_runner import BacktestRunner

TOURNAMENT_OVERRIDES = dict(
    MIN_SL_POINTS=65.0, MAX_SL_POINTS=95.0, SL_ATR_MULT=0.52,
    MIN_TP_POINTS=150.0, MAX_TP_POINTS=260.0, TP_ATR_MULT=2.0,
    BREAKEVEN_TRIGGER_POINTS=45.0, BREAKEVEN_LOCK_POINTS=12.0,
    TRAILING_START_POINTS=95.0, TRAILING_ATR_MULT=0.85,
)

MIN_PF = 1.15
MAX_DD_PCT = 40.0
MIN_TRADES = 5


def split_months(m1, m5, days=30):
    cut = pd.Timestamp(m1["time"].iloc[0]) + pd.Timedelta(days=days)
    m1a = m1[pd.to_datetime(m1["time"]) < cut]
    m1b = m1[pd.to_datetime(m1["time"]) >= cut]
    m5a = m5[pd.to_datetime(m5["time"]) < cut]
    m5b = m5[pd.to_datetime(m5["time"]) >= cut]
    return m1a, m1b, m5a, m5b, cut


def select_models(results, min_pf=MIN_PF, max_dd=MAX_DD_PCT, min_trades=MIN_TRADES):
    picked = []
    for name, r in results.items():
        pf = r.get("profit_factor", 0.0)
        if pf == float("inf"):
            pf = 99.0
        if (r.get("total_trades", 0) >= min_trades and pf >= min_pf
                and r.get("max_drawdown_pct", 100.0) <= max_dd):
            picked.append(name)
    return picked


def _run(m1, m5, strategies, label, dynamic=False):
    return BacktestRunner(
        m1, m5, initial_balance=10.0, spread_points=_spread, point=_point,
        strategies=strategies, overrides=TOURNAMENT_OVERRIDES,
        use_dynamic_lots=dynamic, verbose=False,
        journal_path=f"logs/alpha_{label}.csv",
    ).run()


_spread = 26.0
_point = 0.01


def run_tournament(m1, m5, spread=26.0, point=0.01):
    global _spread, _point
    _spread, _point = float(spread), float(point)
    m1a, m1b, m5a, m5b, cut = split_months(m1, m5)
    print(f"Month 1: {m1a['time'].iloc[0]} -> {m1a['time'].iloc[-1]} ({len(m1a)} bars)")
    print(f"Month 2: {m1b['time'].iloc[0]} -> {m1b['time'].iloc[-1]} ({len(m1b)} bars)")

    print("\n########## 5-MODEL SCALPING TOURNAMENT ##########")
    print(f" {'Model':<28}{'M1 T':>5}{'WR':>6}{'PF':>6}{'Net$':>8}{'DD%':>6}"
          f" |{'M2 T':>5}{'WR':>6}{'PF':>6}{'Net$':>8}{'DD%':>6}")
    m1_results, m2_results = {}, {}
    for model in config.SCALP_MODELS:
        r1 = _run(m1a, m5a, (model,), f"{model}_m1")
        r2 = _run(m1b, m5b, (model,), f"{model}_m2")
        m1_results[model], m2_results[model] = r1, r2
        print(f" {model:<28}{r1['total_trades']:>5}{r1['win_rate']:>5.0f}%"
              f"{_pf(r1):>6}{r1['net_profit']:>8.2f}{r1['max_drawdown_pct']:>6.0f}"
              f" |{r2['total_trades']:>5}{r2['win_rate']:>5.0f}%"
              f"{_pf(r2):>6}{r2['net_profit']:>8.2f}{r2['max_drawdown_pct']:>6.0f}")

    print("\n########## DYNAMIC TARGET TIER BREAKDOWN ##########")
    for label, results in (("Month 1", m1_results), ("Month 2", m2_results)):
        agg = _agg_tiers(results)
        print(f" {label}:")
        for tier in ("T1", "T2", "T3", "NA"):
            d = agg.get(tier)
            if not d or not d["trades"]:
                continue
            wr = 100 * d["wins"] / d["trades"]
            print(f"   {tier:<4}{d['trades']:>6} trades  WR {wr:>5.1f}%  Net ${d['net']:>8.2f}")

    selected = select_models(m1_results)
    print(f"\nSelected from Month 1 (PF>={MIN_PF}, DD<={MAX_DD_PCT:.0f}%): "
          f"{selected if selected else 'NONE'}")

    portfolio = None
    if selected:
        print("\n########## BLIND OUT-OF-SAMPLE PORTFOLIO (Month 2) ##########")
        portfolio = _run(m1b, m5b, tuple(selected), "portfolio_m2", dynamic=True)
        print(f" Final: ${portfolio['final_balance']:.2f} | Net ${portfolio['net_profit']:.2f} "
              f"| PF {_pf(portfolio)} | MaxDD {portfolio['max_drawdown_pct']:.1f}% "
              f"| Trades {portfolio['total_trades']}")
    else:
        print(" No model survived Month 1 — no portfolio traded on Month 2.")

    return dict(m1=m1_results, m2=m2_results, selected=selected, portfolio=portfolio, cut=cut)


def _agg_tiers(results):
    agg = {}
    for r in results.values():
        for tier, d in (r.get("tiers") or {}).items():
            a = agg.setdefault(tier, {"trades": 0, "wins": 0, "net": 0.0})
            a["trades"] += d["trades"]
            a["wins"] += d["wins"]
            a["net"] += d["net"]
    return agg


def _pf(r):
    pf = r.get("profit_factor", 0.0)
    return "inf" if pf == float("inf") else f"{pf:.2f}"
