"""X13 strategy lab.

Screens independent strategy families on real MT5 M1 bars with the real
per-bar spread, then reports net expectancy per trade in points, split into
in-sample (2025) and out-of-sample (2026).

A family is only worth an MQL5 build when net expectancy is positive in both
halves, because a single positive half is indistinguishable from curve fitting.
"""
from __future__ import annotations

import csv
import sys
from dataclasses import dataclass

import numpy as np


POINT = 0.01


@dataclass
class Data:
    t: np.ndarray
    o: np.ndarray
    h: np.ndarray
    l: np.ndarray
    c: np.ndarray
    v: np.ndarray
    s: np.ndarray


def load(path: str) -> Data:
    ts, o, h, l, c, v, s = [], [], [], [], [], [], []
    with open(path, newline="") as fh:
        for row in csv.DictReader(fh):
            ts.append(row["time"])
            o.append(float(row["open"]))
            h.append(float(row["high"]))
            l.append(float(row["low"]))
            c.append(float(row["close"]))
            v.append(float(row["tickvol"]))
            s.append(float(row["spread"]))
    return Data(
        t=np.array(ts),
        o=np.array(o), h=np.array(h), l=np.array(l), c=np.array(c),
        v=np.array(v), s=np.array(s),
    )


def ema(x: np.ndarray, n: int) -> np.ndarray:
    a = 2.0 / (n + 1.0)
    out = np.empty_like(x)
    out[0] = x[0]
    for i in range(1, len(x)):
        out[i] = a * x[i] + (1 - a) * out[i - 1]
    return out


def atr(h, l, c, n: int) -> np.ndarray:
    prev = np.roll(c, 1)
    prev[0] = c[0]
    tr = np.maximum(h - l, np.maximum(np.abs(h - prev), np.abs(l - prev)))
    return ema(tr, n)


def rolling_mean(x: np.ndarray, n: int) -> np.ndarray:
    k = np.ones(n) / n
    return np.convolve(x, k, mode="full")[: len(x)]


def rolling_std(x: np.ndarray, n: int) -> np.ndarray:
    m = rolling_mean(x, n)
    m2 = rolling_mean(x * x, n)
    return np.sqrt(np.maximum(m2 - m * m, 0.0))


def simulate(
    d: Data,
    idx: np.ndarray,
    side: np.ndarray,
    sl_pts: np.ndarray,
    tp_pts: np.ndarray,
    max_bars: int,
) -> dict:
    """Resolve each signal on subsequent bars.

    Cost model: buy fills at open + spread, sell fills at open. Stop and target
    are then evaluated on high/low. When both are touched inside one bar the
    stop is assumed first, which keeps the result conservative.
    """
    n = len(d.c)
    pnl = np.zeros(len(idx))
    closed = 0
    for k in range(len(idx)):
        i = idx[k]
        if i + 1 >= n:
            pnl[k] = np.nan
            continue
        sp = d.s[i + 1]
        if side[k] > 0:
            entry = d.o[i + 1] + sp * POINT
            sl = entry - sl_pts[k] * POINT
            tp = entry + tp_pts[k] * POINT
        else:
            entry = d.o[i + 1]
            sl = entry + sl_pts[k] * POINT
            tp = entry - tp_pts[k] * POINT

        end = min(i + 1 + max_bars, n)
        out = None
        for j in range(i + 1, end):
            if side[k] > 0:
                if d.l[j] <= sl:
                    out = (sl - entry) / POINT
                    break
                if d.h[j] >= tp:
                    out = (tp - entry) / POINT
                    break
            else:
                if d.h[j] >= sl:
                    out = (entry - sl) / POINT
                    break
                if d.l[j] <= tp:
                    out = (entry - tp) / POINT
                    break
        if out is None:
            j = end - 1
            out = ((d.c[j] - entry) / POINT) * side[k]
        # round-turn spread already paid at entry for buys; sells pay on exit
        if side[k] < 0:
            out -= sp
        pnl[k] = out
        closed += 1
    pnl = pnl[~np.isnan(pnl)]
    if len(pnl) == 0:
        return {"trades": 0}
    wins = pnl[pnl > 0]
    losses = pnl[pnl < 0]
    gross_win = wins.sum()
    gross_loss = -losses.sum()
    eq = np.cumsum(pnl)
    peak = np.maximum.accumulate(eq)
    dd = float((peak - eq).max()) if len(eq) else 0.0
    return {
        "trades": int(len(pnl)),
        "win%": 100.0 * len(wins) / len(pnl),
        "exp_pts": float(pnl.mean()),
        "pf": float(gross_win / gross_loss) if gross_loss > 0 else float("inf"),
        "dd_pts": dd,
        "total_pts": float(pnl.sum()),
    }


def session_hour(d: Data) -> np.ndarray:
    return np.array([int(x[11:13]) for x in d.t])


def families(d: Data, h1: int) -> dict:
    """Return name -> (idx, side, sl_pts, tp_pts)."""
    o, h, l, c = d.o, d.h, d.l, d.c
    n = len(c)
    a14 = atr(h, l, c, 14)
    e50 = ema(c, 50)
    e200 = ema(c, 200)
    hr = session_hour(d)

    out = {}
    i = np.arange(210, n - 1)

    # 1. Donchian breakout with EMA trend filter
    from numpy.lib.stride_tricks import sliding_window_view
    hi20 = np.empty(n); lo20 = np.empty(n)
    hi20[:20] = h[:20].max(); lo20[:20] = l[:20].min()
    hi20[20:] = sliding_window_view(h, 20)[:-1].max(axis=1)
    lo20[20:] = sliding_window_view(l, 20)[:-1].min(axis=1)
    up = (c[i] > hi20[i]) & (e50[i] > e200[i])
    dn = (c[i] < lo20[i]) & (e50[i] < e200[i])
    idx = np.concatenate([i[up], i[dn]])
    side = np.concatenate([np.ones(up.sum()), -np.ones(dn.sum())])
    sl = np.maximum(a14[idx] * 1.2 / POINT, 120)
    out["breakout_trend"] = (idx, side, sl, sl * 2.0)

    # 2. False breakout reversal (stop run)
    fu = (h[i] > hi20[i]) & (c[i] < hi20[i]) & (e50[i] < e200[i])
    fd = (l[i] < lo20[i]) & (c[i] > lo20[i]) & (e50[i] > e200[i])
    idx = np.concatenate([i[fu], i[fd]])
    side = np.concatenate([-np.ones(fu.sum()), np.ones(fd.sum())])
    sl = np.maximum(a14[idx] * 1.0 / POINT, 110)
    out["false_breakout"] = (idx, side, sl, sl * 1.5)

    # 3. Pullback to EMA50 in trend
    pu = (e50[i] > e200[i]) & (l[i] <= e50[i]) & (c[i] > e50[i]) & (c[i] > o[i])
    pd = (e50[i] < e200[i]) & (h[i] >= e50[i]) & (c[i] < e50[i]) & (c[i] < o[i])
    idx = np.concatenate([i[pu], i[pd]])
    side = np.concatenate([np.ones(pu.sum()), -np.ones(pd.sum())])
    sl = np.maximum(a14[idx] * 1.2 / POINT, 120)
    out["pullback"] = (idx, side, sl, sl * 2.0)

    # 4. Mean reversion: z-score of close vs EMA50
    sd = rolling_std(c, 50)
    z = (c - e50) / np.maximum(sd, 1e-9)
    rng_ok = (np.abs(e50 - e200) / np.maximum(a14, 1e-9)) < 0.6  # weak trend
    mu = (z[i] < -2.0) & rng_ok[i]
    md = (z[i] > 2.0) & rng_ok[i]
    idx = np.concatenate([i[mu], i[md]])
    side = np.concatenate([np.ones(mu.sum()), -np.ones(md.sum())])
    sl = np.maximum(a14[idx] * 1.5 / POINT, 150)
    out["mean_reversion"] = (idx, side, sl, sl * 1.2)

    # 5. Momentum burst
    body = c - o
    burst = np.abs(body) > a14 * 0.8
    bu = burst & (body > 0) & (c > e50)
    bd = burst & (body < 0) & (c < e50)
    bu[:210] = False
    bd[:210] = False
    idx = np.concatenate([i[bu[i]], i[bd[i]]])
    side = np.concatenate([np.ones(bu[i].sum()), -np.ones(bd[i].sum())])
    sl = np.maximum(a14[idx] * 1.0 / POINT, 110)
    out["momentum_burst"] = (idx, side, sl, sl * 2.0)

    # 6. Compression breakout
    sd20 = rolling_std(c, 20)
    sd_avg = rolling_mean(sd20, 200)
    sd_pct = np.where(sd20 < sd_avg * 0.8, 0.1, 0.9)
    cu = (sd_pct[i] < 0.2) & (c[i] > hi20[i])
    cd = (sd_pct[i] < 0.2) & (c[i] < lo20[i])
    idx = np.concatenate([i[cu], i[cd]])
    side = np.concatenate([np.ones(cu.sum()), -np.ones(cd.sum())])
    sl = np.maximum(a14[idx] * 1.2 / POINT, 120)
    out["compression_break"] = (idx, side, sl, sl * 2.5)

    # 7. Session momentum: first hour of London and NY
    lon = (hr == h1) & (body > a14 * 0.5)
    ny = (hr == 13) & (body < -a14 * 0.5)
    lu = lon
    idx = np.concatenate([i[lu[i]], i[ny[i]]])
    side = np.concatenate([np.ones(lu[i].sum()), -np.ones(ny[i].sum())])
    sl = np.maximum(a14[idx] * 1.0 / POINT, 110)
    out["session_momentum"] = (idx, side, sl, sl * 2.0)

    # 8. Volatility expansion after contraction
    ve = (a14 > np.roll(a14, 50) * 1.6) & (np.abs(body) > a14 * 0.6)
    vu = ve & (body > 0)
    vd = ve & (body < 0)
    idx = np.concatenate([i[vu[i]], i[vd[i]]])
    side = np.concatenate([np.ones(vu[i].sum()), -np.ones(vd[i].sum())])
    sl = np.maximum(a14[idx] * 1.2 / POINT, 130)
    out["vol_expansion"] = (idx, side, sl, sl * 2.0)

    return out


def report(name, res_all, res_is, res_oos):
    def fmt(r):
        if r.get("trades", 0) == 0:
            return "no trades"
        return (f"n={r['trades']:5d} win={r['win%']:5.1f}% "
                f"exp={r['exp_pts']:+7.2f} pf={r['pf']:.2f}")
    print(f"{name:20s} ALL {fmt(res_all)}")
    print(f"{'':20s} IS  {fmt(res_is)}")
    print(f"{'':20s} OOS {fmt(res_oos)}")


def main(path: str):
    d = load(path)
    print(f"bars={len(d.c)}  {d.t[0]} -> {d.t[-1]}")
    year = np.array([x[:4] for x in d.t])
    is_mask = year == "2025"

    results = {}
    for h1 in (8, 10, 13, 15):
        fams = families(d, h1)
        for name, (idx, side, sl, tp) in fams.items():
            if len(idx) < 50:
                continue
            if h1 != 8 and "session" not in name:
                continue
            key = name if "session" not in name else f"{name}_h{h1}"
            m_is = is_mask[idx]
            r_all = simulate(d, idx, side, sl, tp, 240)
            r_is = simulate(d, idx[m_is], side[m_is], sl[m_is], tp[m_is], 240)
            r_oos = simulate(d, idx[~m_is], side[~m_is], sl[~m_is], tp[~m_is], 240)
            results[key] = (r_all, r_is, r_oos)

    print()
    ranked = sorted(results.items(), key=lambda kv: -kv[1][2].get("exp_pts", -99))
    for name, (a, i_, o) in ranked:
        report(name, a, i_, o)
        print()

    print("=== families positive in BOTH halves ===")
    for name, (a, i_, o) in ranked:
        if i_.get("exp_pts", -1) > 0 and o.get("exp_pts", -1) > 0 and o.get("trades", 0) > 100:
            print(f"  {name}: IS {i_['exp_pts']:+.2f} pts | OOS {o['exp_pts']:+.2f} pts "
                  f"| OOS n={o['trades']}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "artifacts/exp/backtest-export1/X13_M1.csv")
