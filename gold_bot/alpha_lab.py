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
    MIN_SL_POINTS=58.0, MAX_SL_POINTS=74.0, SL_ATR_MULT=0.58,
    MIN_TP_POINTS=155.0, MAX_TP_POINTS=420.0, TP_ATR_MULT=2.5,
    BREAKEVEN_TRIGGER_POINTS=38.0, BREAKEVEN_LOCK_POINTS=12.0,
    TRAILING_START_POINTS=65.0, TRAILING_ATR_MULT=0.75,
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


def _line(label, r):
    pf = r.get("profit_factor", 0.0)
    pf = "inf" if pf == float("inf") else f"{pf:.2f}"
    return (f" {label:<34}{r['total_trades']:>6}{r['win_rate']:>6.1f}%"
            f"{pf:>7}{r['net_profit']:>9.2f}{r['max_drawdown_pct']:>7.1f}")


def _dir_line(label, r):
    d = r.get("by_direction") or {}
    buy = d.get("BUY", {"n": 0, "wins": 0, "net": 0.0})
    sell = d.get("SELL", {"n": 0, "wins": 0, "net": 0.0})
    bwr = 100 * buy["wins"] / buy["n"] if buy["n"] else 0.0
    swr = 100 * sell["wins"] / sell["n"] if sell["n"] else 0.0
    print(f" {label}: BUY {buy['n']:>3} ({bwr:>4.1f}% WR, ${buy['net']:>6.2f})"
          f" | SELL {sell['n']:>3} ({swr:>4.1f}% WR, ${sell['net']:>6.2f})")


def run_tournament(m1, m5, spread=26.0, point=0.01):
    global _spread, _point
    _spread, _point = float(spread), float(point)
    m1a, m1b, m5a, m5b, cut = split_months(m1, m5)
    print(f"Month 1: {m1a['time'].iloc[0]} -> {m1a['time'].iloc[-1]} ({len(m1a)} bars)")
    print(f"Month 2: {m1b['time'].iloc[0]} -> {m1b['time'].iloc[-1]} ({len(m1b)} bars)")

    print(f"\n########## {len(config.PULSE_MODELS)}-ENGINE TOURNAMENT ##########")
    header = (f" {'Engine':<34}{'T':>6}{'WR':>7}{'PF':>7}{'Net$':>9}{'DD%':>7}")
    print(header)
    m1_results, m2_results, rows = {}, {}, []
    for model in config.PULSE_MODELS:
        r1 = _run(m1a, m5a, (model,), f"{model}_m1")
        r2 = _run(m1b, m5b, (model,), f"{model}_m2")
        m1_results[model], m2_results[model] = r1, r2
        rows.append((model, r1, r2))

    print(" -- Month 1 (in-sample) --")
    for model, r1, _ in sorted(rows, key=lambda x: -x[1]["net_profit"]):
        print(_line(model, r1))
    print(" -- Month 2 (blind) --")
    for model, _, r2 in sorted(rows, key=lambda x: -x[2]["net_profit"]):
        print(_line(model, r2))

    winners = [m for m, r1, r2 in sorted(rows, key=lambda x: -(x[1]["net_profit"] + x[2]["net_profit"]))
               if r1["net_profit"] > 0 and r2["net_profit"] > 0 and r1["total_trades"] >= 5]
    print(f"\nDual-month winners (net > 0 in BOTH months, >= 5 M1 trades): {winners or 'NONE'}")
    if winners:
        ens = _run(m1b, m5b, tuple(winners), "ensemble_m2", dynamic=True)
        print(" Ensemble Month 2 (blind):")
        print(_line(" ".join(w[:12] for w in winners), ens))
        print(f" ${ens['initial_balance']:.2f} -> ${ens['final_balance']:.2f}"
              f" | Trades {ens['total_trades']} | WR {ens['win_rate']:.1f}%"
              f" | PF {_pf(ens)} | MaxDD {ens['max_drawdown_pct']:.1f}%")
        _dir_line("Ensemble M2", ens)

    production = tuple(winners) or tuple(config.PULSE_MODELS)
    print(f"\n########## PRODUCTION PORTFOLIO ({len(production)} dual-month engines) ##########")
    p1 = _run(m1a, m5a, production, "portfolio_m1", dynamic=True)
    p2 = _run(m1b, m5b, production, "portfolio_m2", dynamic=True)
    print(f" {'Window':<34}{'T':>6}{'WR':>7}{'PF':>7}{'Net$':>9}{'DD%':>7}")
    print(_line("Month 1", p1))
    print(_line("Month 2 (blind)", p2))
    print(f" Month 1: ${p1['initial_balance']:.2f} -> ${p1['final_balance']:.2f}"
          f" | Month 2: ${p2['initial_balance']:.2f} -> ${p2['final_balance']:.2f}")
    _dir_line("Month 1", p1)
    _dir_line("Month 2", p2)

    full = _run(m1, m5, production, "portfolio_full60", dynamic=True)
    print("\n########## FULL 60-DAY CONTINUOUS RUN (dynamic lots) ##########")
    print(_line("Full 60 days", full))
    _dir_line("Full 60 days", full)

    print("\n########## PRODUCTION READINESS REPORT ##########")
    print(f" Initial ${full['initial_balance']:.2f} -> Final ${full['final_balance']:.2f}"
          f" ({100 * (full['final_balance'] / full['initial_balance'] - 1):+.1f}%)")
    print(f" Total trades {full['total_trades']} | WR {full['win_rate']:.1f}%"
          f" | PF {_pf(full)} | MaxDD {full['max_drawdown_pct']:.1f}%")
    _dir_line("BUY vs SELL", full)
    print(" Engine-by-engine contribution (full 60 days):")
    for name, d in sorted((full.get("by_strategy") or {}).items(), key=lambda x: -x[1]["net"]):
        n = d.get("n", d.get("trades", 0))
        wr = 100 * d["wins"] / n if n else 0.0
        print(f"  {name:<32}{n:>5} trades  WR {wr:>5.1f}%  Net ${d['net']:>7.2f}")

    print("\n########## TARGET TIER BREAKDOWN ##########")
    for label, r in (("Month 1", p1), ("Month 2", p2)):
        for tier in ("T1", "T2", "T3"):
            d = (r.get("tiers") or {}).get(tier)
            if not d or not d["trades"]:
                continue
            wr = 100 * d["wins"] / d["trades"]
            print(f" {label} {tier}: {d['trades']:>4} trades  WR {wr:>5.1f}%  Net ${d['net']:>7.2f}")

    return dict(m1=m1_results, m2=m2_results, portfolio_m1=p1, portfolio_m2=p2,
                portfolio_full=full, cut=cut)


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
