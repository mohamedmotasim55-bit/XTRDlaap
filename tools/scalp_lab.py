"""X13 scalping lab.

Decisive diagnostic: measure GROSS expectancy (before spread) for every
scalping family. If gross expectancy is below the spread, no exit logic,
sizing or trailing can make the family profitable, because the cost is fixed
per round turn and cannot be scaled down at 0.01 lot.

Reports gross and net side by side for several target sizes.
"""
from __future__ import annotations

import sys

import numpy as np

from strategy_lab import Data, atr, ema, load, rolling_mean, rolling_std, POINT


def simulate(d: Data, idx, side, sl_pts, tp_pts, max_bars, spread: bool):
    n = len(d.c)
    out = []
    for k in range(len(idx)):
        i = idx[k]
        if i + 1 >= n:
            continue
        sp = d.s[i + 1] if spread else 0.0
        if side[k] > 0:
            entry = d.o[i + 1] + sp * POINT
            sl = entry - sl_pts[k] * POINT
            tp = entry + tp_pts[k] * POINT
        else:
            entry = d.o[i + 1]
            sl = entry + sl_pts[k] * POINT
            tp = entry - tp_pts[k] * POINT

        end = min(i + 1 + max_bars, n)
        res = None
        for j in range(i + 1, end):
            if side[k] > 0:
                if d.l[j] <= sl:
                    res = (sl - entry) / POINT
                    break
                if d.h[j] >= tp:
                    res = (tp - entry) / POINT
                    break
            else:
                if d.h[j] >= sl:
                    res = (entry - sl) / POINT
                    break
                if d.l[j] <= tp:
                    res = (entry - tp) / POINT
                    break
        if res is None:
            j = end - 1
            res = ((d.c[j] - entry) / POINT) * side[k]
        if side[k] < 0 and spread:
            res -= sp
        out.append(res)
    a = np.array(out)
    if len(a) == 0:
        return None
    w = a[a > 0]
    l = a[a < 0]
    return {
        "n": len(a),
        "win": 100.0 * len(w) / len(a),
        "exp": float(a.mean()),
        "pf": float(w.sum() / -l.sum()) if len(l) and l.sum() < 0 else float("inf"),
    }


def variants(d: Data) -> dict:
    o, h, l, c, v = d.o, d.h, d.l, d.c, d.v
    n = len(c)
    a = atr(h, l, c, 14)
    e50 = ema(c, 50)
    e200 = ema(c, 200)
    rng = h - l
    body = c - o
    i = np.arange(210, n - 1)

    # tick-activity proxy: volume per point of range
    vpr = v / np.maximum(rng / POINT, 1.0)
    vpr_ma = rolling_mean(vpr, 50)

    out = {}

    # 1. micro momentum burst
    bu = (body > a * 0.6) & (c > e50)
    bd = (body < -a * 0.6) & (c < e50)
    out["micro_burst"] = (np.concatenate([i[bu[i]], i[bd[i]]]),
                          np.concatenate([np.ones(bu[i].sum()), -np.ones(bd[i].sum())]))

    # 2. tick-activity burst (volume per point spikes = genuine participation)
    ta = (vpr > vpr_ma * 2.0) & (body > a * 0.4)
    tb = (vpr > vpr_ma * 2.0) & (body < -a * 0.4)
    out["tick_activity"] = (np.concatenate([i[ta[i]], i[tb[i]]]),
                            np.concatenate([np.ones(ta[i].sum()), -np.ones(tb[i].sum())]))

    # 3. micro breakout of 5 bars
    from numpy.lib.stride_tricks import sliding_window_view
    hi5 = np.empty(n); lo5 = np.empty(n)
    hi5[:5] = h[:5].max(); lo5[:5] = l[:5].min()
    hi5[5:] = sliding_window_view(h, 5)[:-1].max(axis=1)
    lo5[5:] = sliding_window_view(l, 5)[:-1].min(axis=1)
    xb = c[i] > hi5[i]
    xs = c[i] < lo5[i]
    out["micro_break5"] = (np.concatenate([i[xb], i[xs]]),
                           np.concatenate([np.ones(xb.sum()), -np.ones(xs.sum())]))

    # 4. micro pullback to ema20
    e20 = ema(c, 20)
    pu = (e50[i] > e200[i]) & (l[i] <= e20[i]) & (c[i] > e20[i]) & (c[i] > o[i])
    pd = (e50[i] < e200[i]) & (h[i] >= e20[i]) & (c[i] < e20[i]) & (c[i] < o[i])
    out["micro_pullback"] = (np.concatenate([i[pu], i[pd]]),
                             np.concatenate([np.ones(pu.sum()), -np.ones(pd.sum())]))

    # 5. mean reversion z-score
    sd = rolling_std(c, 50)
    z = (c - e50) / np.maximum(sd, 1e-9)
    mu = z[i] < -2.0
    md = z[i] > 2.0
    out["micro_reversion"] = (np.concatenate([i[mu], i[md]]),
                              np.concatenate([np.ones(mu.sum()), -np.ones(md.sum())]))

    # 6. exhaustion: long wick against the move
    upwick = h - np.maximum(c, o)
    dnwick = np.minimum(c, o) - l
    ex = (upwick[i] > a[i] * 1.2) & (body[i] > 0)
    ex2 = (dnwick[i] > a[i] * 1.2) & (body[i] < 0)
    out["exhaustion"] = (np.concatenate([i[ex], i[ex2]]),
                         np.concatenate([-np.ones(ex.sum()), np.ones(ex2.sum())]))

    # 7. volatility expansion
    ve = (a > np.roll(a, 20) * 1.8)
    vu = ve & (body > 0)
    vd = ve & (body < 0)
    out["vol_expand"] = (np.concatenate([i[vu[i]], i[vd[i]]]),
                         np.concatenate([np.ones(vu[i].sum()), -np.ones(vd[i].sum())]))

    return out


def main(path: str):
    d = load(path)
    print(f"bars={len(d.c)}  {d.t[0]} -> {d.t[-1]}")
    print("spread pts: mean %.1f  median %.1f" % (d.s.mean(), np.median(d.s)))
    print()
    hdr = f"{'family':16s} {'n':>7s} {'win%':>6s} | " + " | ".join(
        f"TP{int(tp):>4d}" for tp in (40, 80, 150, 300))
    print(hdr)
    rng = np.random.default_rng(7)
    for name, (idx, side) in variants(d).items():
        if len(idx) < 200:
            continue
        if len(idx) > 20000:
            keep = np.sort(rng.choice(len(idx), 20000, replace=False))
            idx, side = idx[keep], side[keep]
        row = f"{name:16s} {len(idx):7d}"
        cells = []
        for tp in (40, 80, 150, 300):
            sl = np.full(len(idx), max(tp * 0.6, 30.0))
            t = np.full(len(idx), float(tp))
            g = simulate(d, idx, side, sl, t, 60, spread=False)
            cells.append(f"{g['exp']:+7.2f}/{g['win']:4.1f}" if g else "   n/a    ")
        print(f"{row:24s} | " + " | ".join(cells))
    print()
    print("cell = gross expectancy (pts) / win% ; spread ~ %.1f pts is the hurdle" % d.s.mean())


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "artifacts/exp/backtest-export1/X13_M1.csv")
