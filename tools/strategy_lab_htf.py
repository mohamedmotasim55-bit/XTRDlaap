"""X13 strategy lab, higher timeframes.

The M1 screen found zero gross edge across 322k trades: every family lost
about one spread per trade. This script asks the next question: does any
edge exist when the target is large enough that the spread stops dominating?

Bars are resampled from the M1 export, so the results stay tied to real ticks.
"""
from __future__ import annotations

import sys

import numpy as np

from strategy_lab import Data, atr, ema, load, rolling_mean, rolling_std, simulate, POINT


def resample(d: Data, minutes: int) -> Data:
    ts, o, h, l, c, v, s = [], [], [], [], [], [], []
    bucket = None
    bo = bh = bl = bc = bv = bs = 0.0
    nb = 0
    for i in range(len(d.c)):
        hh = int(d.t[i][11:13])
        stamp = d.t[i][:11] + f"{(hh * 60 // minutes) * minutes // 60:02d}"
        if stamp != bucket:
            if bucket is not None:
                ts.append(bucket); o.append(bo); h.append(bh); l.append(bl)
                c.append(bc); v.append(bv); s.append(bs / max(nb, 1))
            bucket = stamp
            bo, bh, bl, bc, bv, bs, nb = d.o[i], d.h[i], d.l[i], d.c[i], d.v[i], d.s[i], 1
        else:
            bh = max(bh, d.h[i]); bl = min(bl, d.l[i]); bc = d.c[i]
            bv += d.v[i]; bs += d.s[i]; nb += 1
    ts.append(bucket); o.append(bo); h.append(bh); l.append(bl)
    c.append(bc); v.append(bv); s.append(bs / max(nb, 1))
    return Data(t=np.array(ts), o=np.array(o), h=np.array(h), l=np.array(l),
                c=np.array(c), v=np.array(v), s=np.array(s))


def donchian(h, l, n):
    from numpy.lib.stride_tricks import sliding_window_view
    hi = np.empty(len(h)); lo = np.empty(len(l))
    m = min(n, len(h))
    hi[:m] = h[:m].max(); lo[:m] = l[:m].min()
    if len(h) > n:
        hi[n:] = sliding_window_view(h, n)[:-1].max(axis=1)
        lo[n:] = sliding_window_view(l, n)[:-1].min(axis=1)
    return hi, lo


def build(d: Data, tf: str) -> dict:
    o, h, l, c = d.o, d.h, d.l, d.c
    n = len(c)
    a = atr(h, l, c, 14)
    e50, e200 = ema(c, 50), ema(c, 200)
    i = np.arange(210, n - 1)
    out = {}

    hi20, lo20 = donchian(h, l, 20)
    hi55, lo55 = donchian(h, l, 55)

    up = (c[i] > hi20[i]) & (e50[i] > e200[i])
    dn = (c[i] < lo20[i]) & (e50[i] < e200[i])
    idx = np.concatenate([i[up], i[dn]])
    side = np.concatenate([np.ones(up.sum()), -np.ones(dn.sum())])
    sl = np.maximum(a[idx] * 2.0 / POINT, 300)
    out["brk20_trend"] = (idx, side, sl, sl * 3.0)
    # affordable variants: fixed stops a $10 account can actually hold
    out["brk20_sl400"] = (idx, side, np.full(len(idx), 400.0), np.full(len(idx), 1200.0))
    out["brk20_sl600"] = (idx, side, np.full(len(idx), 600.0), np.full(len(idx), 1800.0))

    up2 = (c[i] > hi55[i]) & (e50[i] > e200[i])
    dn2 = (c[i] < lo55[i]) & (e50[i] < e200[i])
    idx = np.concatenate([i[up2], i[dn2]])
    side = np.concatenate([np.ones(up2.sum()), -np.ones(dn2.sum())])
    sl = np.maximum(a[idx] * 2.5 / POINT, 400)
    out["brk55_trend"] = (idx, side, sl, sl * 4.0)
    out["brk55_sl400"] = (idx, side, np.full(len(idx), 400.0), np.full(len(idx), 1200.0))
    out["brk55_sl600"] = (idx, side, np.full(len(idx), 600.0), np.full(len(idx), 1800.0))

    # trend continuation: deep pullback inside a strong trend
    pu = (e50[i] > e200[i]) & (l[i] <= e50[i]) & (c[i] > e50[i])
    pd = (e50[i] < e200[i]) & (h[i] >= e50[i]) & (c[i] < e50[i])
    idx = np.concatenate([i[pu], i[pd]])
    side = np.concatenate([np.ones(pu.sum()), -np.ones(pd.sum())])
    sl = np.maximum(a[idx] * 2.0 / POINT, 250)
    out["pullback_trend"] = (idx, side, sl, sl * 3.0)
    out["pullback_sl400"] = (idx, side, np.full(len(idx), 400.0), np.full(len(idx), 1200.0))
    out["pullback_sl500"] = (idx, side, np.full(len(idx), 500.0), np.full(len(idx), 1500.0))

    # volatility breakout
    ve = (a > np.roll(a, 20) * 1.8) & (np.abs(c - o) > a * 0.8)
    vu, vd = ve & (c > o), ve & (c < o)
    idx = np.concatenate([i[vu[i]], i[vd[i]]])
    side = np.concatenate([np.ones(vu[i].sum()), -np.ones(vd[i].sum())])
    sl = np.maximum(a[idx] * 2.0 / POINT, 300)
    out["vol_break"] = (idx, side, sl, sl * 3.0)

    # mean reversion against 2.5 sigma stretch
    sd = rolling_std(c, 50)
    z = (c - e50) / np.maximum(sd, 1e-9)
    mu, md = z[i] < -2.5, z[i] > 2.5
    idx = np.concatenate([i[mu], i[md]])
    side = np.concatenate([np.ones(mu.sum()), -np.ones(md.sum())])
    sl = np.maximum(a[idx] * 3.0 / POINT, 350)
    out["meanrev_2.5s"] = (idx, side, sl, sl * 1.5)

    return out


def main(path: str):
    d = load(path)
    for minutes, label, max_bars in ((60, "H1", 400), (240, "H4", 300)):
        htf = resample(d, minutes)
        print(f"\n===== {label}: {len(htf.c)} bars =====")
        year = np.array([x[:4] for x in htf.t])
        is_mask = year == "2025"
        for name, (idx, side, sl, tp) in build(htf, label).items():
            if len(idx) < 30:
                print(f"{name:16s} too few signals ({len(idx)})")
                continue
            m = is_mask[idx]
            if m.sum() < 20 or (~m).sum() < 20:
                print(f"{name:16s} split too small")
                continue
            a = simulate(htf, idx, side, sl, tp, max_bars)
            b = simulate(htf, idx[m], side[m], sl[m], tp[m], max_bars)
            o = simulate(htf, idx[~m], side[~m], sl[~m], tp[~m], max_bars)
            flag = "  <== POSITIVE BOTH" if b["exp_pts"] > 0 and o["exp_pts"] > 0 else ""
            print(f"{name:16s} ALL n={a['trades']:5d} win={a['win%']:5.1f}% exp={a['exp_pts']:+8.1f} "
                  f"| IS {b['exp_pts']:+8.1f} | OOS {o['exp_pts']:+8.1f}{flag}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "artifacts/exp/backtest-export1/X13_M1.csv")
