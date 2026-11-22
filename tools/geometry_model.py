#!/usr/bin/env python3
"""Barrier/expectancy model for a fixed spread, used to size SL/TP geometry.

This is not a backtest. It answers one question with arithmetic: given a spread
of c points, how much predictive edge does a (SL, TP) pair require before it can
be profitable?

Notation, for a long entry at ask A with spread c and mid M = A - c/2:
  * the TP price A+T is reached when the mid reaches A+T+c/2  -> up distance T + c/2
  * the SL price A-S is reached when the mid reaches A-S+c/2  -> down distance S - c/2

P/L relative to the entry price is exactly +T or -S, so the break-even hit rate is
    p* = S / (S + T)
A driftless random walk hits the upper barrier first with probability
    p0 = (S - c/2) / (S + T)
and the gap p* - p0 = (c/2)/(S+T) is the edge the signal must supply. The gap
shrinks as the targets grow relative to the spread, which is why a 32-point stop
cannot work against a 30-point spread.

Usage: python3 tools/geometry_model.py [--spread 30] [--lot 0.01] [--equity 100]
"""

from __future__ import annotations

import argparse


def evaluate(sl: float, tp: float, spread: float, lot: float, equity: float, point_value: float = 1.0):
    up = tp + spread / 2.0
    down = sl - spread / 2.0
    if down <= 0:
        return {
            "sl": sl, "tp": tp, "rr": tp / sl, "p_star": None, "p0": None,
            "edge_needed": None, "immediate_stop": True,
            "cost_pct": 100.0 * spread * lot * point_value / equity,
        }
    p_star = sl / (sl + tp)
    p0 = down / (sl + tp)
    return {
        "sl": sl,
        "tp": tp,
        "rr": tp / sl,
        "p_star": p_star,
        "p0": p0,
        "edge_needed": p_star - p0,
        "immediate_stop": False,
        "cost_pct": 100.0 * spread * lot * point_value / equity,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--spread", type=float, default=30.0)
    ap.add_argument("--lot", type=float, default=0.01)
    ap.add_argument("--equity", type=float, default=100.0)
    ap.add_argument("--point-value", type=float, default=1.0, help="USD per point per 1.0 lot")
    ap.add_argument("--trades", type=int, default=100)
    args = ap.parse_args()

    cases = [
        ("v2.23 baseline (SL 32 / TP 45)", 32.0, 45.0),
        ("v2.23 stretched (SL 48 / TP 70)", 48.0, 70.0),
        ("v2.30 spread floors (SL 180 / TP 270)", 180.0, 270.0),
        ("v2.30 wide (SL 240 / TP 360)", 240.0, 360.0),
        ("very wide (SL 300 / TP 450)", 300.0, 450.0),
    ]

    print(f"spread={args.spread:.0f} pts  lot={args.lot}  equity={args.equity:.0f} USD")
    print(f"round-trip spread cost per trade: {args.spread * args.lot * args.point_value:.2f} USD "
          f"({100.0 * args.spread * args.lot * args.point_value / args.equity:.2f}% of equity)")
    print()
    header = f"{'configuration':38} {'RR':>5} {'p*':>7} {'p0':>7} {'edge':>7} {'spread bleed':>13}"
    print(header)
    print("-" * len(header))
    for name, sl, tp in cases:
        r = evaluate(sl, tp, args.spread, args.lot, args.equity, args.point_value)
        bleed = r["cost_pct"] * args.trades
        if r["immediate_stop"]:
            print(f"{name:38} {r['rr']:5.2f} {'-':>7} {'-':>7} {'STOP IN SPREAD':>7} {bleed:12.1f}%")
            continue
        print(
            f"{name:38} {r['rr']:5.2f} {r['p_star']*100:6.1f}% {r['p0']*100:6.1f}% "
            f"{r['edge_needed']*100:6.1f}% {bleed:12.1f}%"
        )
    print()
    print("p*  = break-even hit rate,  p0 = hit rate of a driftless random walk,")
    print("edge = p* - p0 = predictive skill the signal must supply.")
    print(f"spread bleed = total spread paid over {args.trades} trades, as % of starting equity.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
