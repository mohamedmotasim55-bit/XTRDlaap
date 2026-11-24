"""X13 tick event backtest.

The decile study found that extreme positive tick imbalance predicts an
upward move of ~+156 points over 15 minutes. Decile cells overlap heavily
(consecutive ticks in one burst are not independent), so this script builds
a strict non-overlapping event stream and reports a realistic equity curve
with the full spread charged on every round turn.
"""
from __future__ import annotations

import sys

import numpy as np

POINT = 0.01


def load(path):
    msc, bid, ask, last, flags = [], [], [], [], []
    with open(path) as fh:
        next(fh)
        for line in fh:
            p = line.split(",")
            msc.append(int(p[0])); bid.append(float(p[1])); ask.append(float(p[2]))
            last.append(float(p[3])); flags.append(int(p[5]))
    return (np.array(msc, dtype=np.int64), np.array(bid), np.array(ask),
            np.array(last), np.array(flags))


def run(t, b, a, last, flags, hold_sec, thr, side_filter, deposit=10.0, lot=0.01):
    mid = (b + a) / 2.0
    spread = (a - b) / POINT
    imb = np.where(spread > 0, (last - mid) / POINT / np.maximum(spread, 1e-9), 0.0)
    imb[(flags & 32) == 0] = 0.0

    n = len(t)
    hold_ms = hold_sec * 1000
    i = 0
    trades = []
    while i < n - 1:
        if imb[i] >= thr and side_filter in ("long", "both"):
            entry = a[i]                       # buy at ask
            j = int(np.searchsorted(t, t[i] + hold_ms, side="left"))
            if j >= n:
                break
            exitp = b[j]                       # sell at bid
            trades.append(((exitp - entry) / POINT, t[i]))
            i = j + 1
            continue
        if imb[i] <= -thr and side_filter in ("short", "both"):
            entry = b[i]                       # sell at bid
            j = int(np.searchsorted(t, t[i] + hold_ms, side="left"))
            if j >= n:
                break
            exitp = a[j]                       # buy at ask
            trades.append(((entry - exitp) / POINT, t[i]))
            i = j + 1
            continue
        i += 1

    if not trades:
        return None
    pnl = np.array([x[0] for x in trades])
    money = pnl * POINT * 100 * lot / 0.01 * 0.01  # 1 pt = 0.01 USD at 0.01 lot
    money = pnl * 0.01 * lot / 0.01
    w = money[money > 0]; l = money[money < 0]
    eq = deposit + np.cumsum(money)
    peak = np.maximum.accumulate(eq)
    dd = float((peak - eq).max())
    days = (t[-1] - t[0]) / 86400000
    return {
        "n": len(trades), "per_day": len(trades) / days,
        "win": 100 * len(w) / len(trades),
        "pf": (w.sum() / -l.sum()) if len(l) and l.sum() < 0 else float("inf"),
        "exp_pts": pnl.mean(), "net_usd": money.sum(),
        "final": eq[-1], "dd": dd, "t_stat": pnl.mean() / (pnl.std(ddof=1) / np.sqrt(len(pnl))),
        "avg_w": w.mean() if len(w) else 0, "avg_l": l.mean() if len(l) else 0,
    }


def main(path):
    t, b, a, last, flags = load(path)
    mid = (b + a) / 2.0
    spread = (a - b) / POINT
    imb = np.where(spread > 0, (last - mid) / POINT / np.maximum(spread, 1e-9), 0.0)
    imb[(flags & 32) == 0] = 0.0
    print(f"ticks={len(t):,}  spread median={np.median(spread):.0f}  imb p99={np.quantile(imb,0.99):.2f}")
    print(f"imb>1.0 : {100*(imb>1.0).mean():.2f}% of ticks   imb>2.0: {100*(imb>2.0).mean():.2f}%")
    print()
    print(f"{'hold':>6s} {'thr':>5s} {'side':>6s} {'n':>6s} {'/day':>6s} {'win%':>6s} {'PF':>6s} "
          f"{'exp pts':>8s} {'net$':>8s} {'final$':>8s} {'DD$':>7s} {'t':>6s}")
    for hold in (300, 900):
        for thr in (1.0, 1.5, 2.0):
            for side in ("long", "both"):
                r = run(t, b, a, last, flags, hold, thr, side)
                if not r or r["n"] < 30:
                    continue
                print(f"{hold:6d} {thr:5.1f} {side:>6s} {r['n']:6d} {r['per_day']:6.1f} "
                      f"{r['win']:6.1f} {r['pf']:6.2f} {r['exp_pts']:+8.1f} {r['net_usd']:+8.2f} "
                      f"{r['final']:8.2f} {r['dd']:7.2f} {r['t_stat']:+6.1f}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "artifacts/tk1/backtest-ticks1/X13_TICKS.csv")
