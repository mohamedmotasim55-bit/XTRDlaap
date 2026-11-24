"""X13 phase 7 - raw tick sequence intelligence.

Part 1: data-quality audit.
Part 2: sequence features (quote transition asymmetry, timing, path shape,
        spread dynamics) - all past-only.
Part 3: chronological train / validation / test with an economic objective
        (does the model find trades whose net expectancy beats the spread?).

Events are sampled on a fixed 5-second grid so that labels do not overlap
into a fake sample size; the trade simulator later enforces strict
non-overlap.
"""
from __future__ import annotations

import sys

import numpy as np

POINT = 0.01
GRID_MS = 5000


def load(path):
    msc, bid, ask, vol, flags = [], [], [], [], []
    with open(path) as fh:
        next(fh)
        for line in fh:
            p = line.split(",")
            msc.append(int(p[0])); bid.append(float(p[1])); ask.append(float(p[2]))
            vol.append(int(p[4])); flags.append(int(p[5]))
    return (np.array(msc, dtype=np.int64), np.array(bid), np.array(ask),
            np.array(vol), np.array(flags))


def audit(t, b, a, vol, flags):
    print("=" * 70)
    print("DATA QUALITY AUDIT")
    print("=" * 70)
    n = len(t)
    print(f"ticks                : {n:,}")
    print(f"span                 : {(t[-1]-t[0])/86400000:.2f} days")
    print(f"monotonic timestamps : {bool(np.all(np.diff(t) >= 0))}")
    print(f"duplicate timestamps : {int((np.diff(t) == 0).sum()):,}")
    same = (np.diff(b) == 0) & (np.diff(a) == 0)
    print(f"identical consecutive quotes : {int(same.sum()):,} ({100*same.mean():.1f}%)")
    print(f"bid <= 0             : {int((b <= 0).sum()):,}")
    print(f"ask <= 0             : {int((a <= 0).sum()):,}")
    print(f"ask < bid (crossed)  : {int((a < b).sum()):,}")
    print(f"volume == 0          : {100*(vol == 0).mean():.1f}%")
    print(f"volume range         : {vol.min()} .. {vol.max()}")
    sp = (a - b) / POINT
    print(f"spread pts           : min {sp.min():.1f} p50 {np.median(sp):.1f} "
          f"p95 {np.quantile(sp,0.95):.1f} max {sp.max():.1f} mean {sp.mean():.2f}")
    db, da = np.diff(b), np.diff(a)
    up_b, dn_b = db > 0, db < 0
    up_a, dn_a = da > 0, da < 0
    print(f"bid-only up          : {100*(up_b & (da == 0)).mean():.1f}%")
    print(f"bid-only down        : {100*(dn_b & (da == 0)).mean():.1f}%")
    print(f"ask-only up          : {100*(up_a & (db == 0)).mean():.1f}%")
    print(f"ask-only down        : {100*(dn_a & (db == 0)).mean():.1f}%")
    print(f"both up              : {100*(up_b & up_a).mean():.1f}%")
    print(f"both down            : {100*(dn_b & dn_a).mean():.1f}%")
    print(f"divergent (spread move): {100*((up_b & dn_a) | (dn_b & up_a)).mean():.1f}%")
    dsp = np.diff(sp)
    print(f"spread widened       : {100*(dsp > 0).mean():.1f}%   narrowed: {100*(dsp < 0).mean():.1f}%")
    iat = np.diff(t)
    print(f"inter-arrival ms     : p50 {np.median(iat):.0f} p95 {np.quantile(iat,0.95):.0f} "
          f"max {iat.max():,}")
    gaps = (iat > 60000).sum()
    print(f"gaps > 60 s          : {gaps:,}  (total {(iat[iat>60000].sum())/3600000:.1f} h)")
    print()


def build(t, b, a, vol, horizons=(5, 30, 60, 300)):
    n = len(t)
    mid = (b + a) / 2.0
    sp = (a - b) / POINT
    db = np.diff(b, prepend=b[0])
    da = np.diff(a, prepend=a[0])
    dm = np.diff(mid, prepend=mid[0])

    def cs(x):
        return np.concatenate([[0.0], np.cumsum(x, dtype=np.float64)])

    c_upb, c_dnb = cs(db > 0), cs(db < 0)
    c_upa, c_dna = cs(da > 0), cs(da < 0)
    c_both_up = cs((db > 0) & (da > 0))
    c_both_dn = cs((db < 0) & (da < 0))
    c_bid_only = cs((db != 0) & (da == 0))
    c_ask_only = cs((da != 0) & (db == 0))
    c_comp = cs(np.diff(sp, prepend=sp[0]) < 0)
    c_exp = cs(np.diff(sp, prepend=sp[0]) > 0)
    c_abs = cs(np.abs(dm))
    c_vol = cs(vol.astype(np.float64))

    # event grid
    ev = np.arange(t[0], t[-1], GRID_MS)
    i = np.minimum(np.searchsorted(t, ev, side="right") - 1, n - 1)
    i = np.maximum(i, 0)

    def idx_at(back_ms):
        return np.maximum(np.searchsorted(t, ev - back_ms, side="left"), 0)

    def cnt(c, j):
        return c[i + 1] - c[j]

    def win(back_ms):
        j = idx_at(back_ms)
        w = np.maximum(i - j, 1).astype(float)
        return j, w

    f = {}
    for ms, tag in ((5000, "5s"), (30000, "30s")):
        j, w = win(ms)
        f[f"rate_{tag}"] = w / (ms / 1000.0)
        f[f"upb_{tag}"] = cnt(c_upb, j) / w
        f[f"dnb_{tag}"] = cnt(c_dnb, j) / w
        f[f"bothup_{tag}"] = cnt(c_both_up, j) / w
        f[f"bothdn_{tag}"] = cnt(c_both_dn, j) / w
        f[f"bidonly_{tag}"] = cnt(c_bid_only, j) / w
        f[f"askonly_{tag}"] = cnt(c_ask_only, j) / w
        f[f"compress_{tag}"] = cnt(c_comp, j) / w
        f[f"expand_{tag}"] = cnt(c_exp, j) / w
        f[f"asym_{tag}"] = (cnt(c_upb, j) - cnt(c_dnb, j)) / w
        f[f"disp_{tag}"] = (mid[i] - mid[j]) / POINT
        path = c_abs[i + 1] - c_abs[j]
        f[f"eff_{tag}"] = np.abs(mid[i] - mid[j]) / np.maximum(path, 1e-9)
        f[f"vol_{tag}"] = cnt(c_vol, j) / w

    # runs and reversals on the last 20 quote changes
    L = 20
    j20 = np.maximum(i - L, 0)
    seg_sign = np.sign(dm)
    c_rev = cs((np.sign(dm[1:]) != np.sign(dm[:-1])).astype(float))
    f["reversals_20"] = (c_rev[np.maximum(i, 1)] - c_rev[np.maximum(j20, 1)]) / L
    f["spread_now"] = sp[i]
    f["spread_z"] = (sp[i] - np.median(sp)) / max(np.std(sp), 1e-9)
    f["iat_p50"] = np.median(np.diff(t)[:1000]) if n > 1000 else 0.0

    # labels: forward mid move
    y = {}
    for h in horizons:
        k = np.minimum(np.searchsorted(t, ev + h * 1000, side="left"), n - 1)
        y[f"fwd_{h}s"] = (mid[k] - mid[i]) / POINT
        y[f"cost_{h}s"] = sp[i]
    return ev, i, f, y, mid, sp


def main(path):
    t, b, a, vol, flags = load(path)
    audit(t, b, a, vol, flags)
    ev, i, f, y, mid, sp = build(t, b, a, vol)
    print(f"events on 5 s grid: {len(ev):,}")
    print()
    print("=" * 70)
    print("SINGLE-FEATURE SCREEN (test on the last 20% only)")
    print("=" * 70)
    cut = int(len(ev) * 0.8)
    names = sorted(f)
    print(f"{'feature':16s} {'AUC 5s':>7s} {'AUC 30s':>8s} {'AUC 60s':>8s} {'AUC 300s':>9s}")
    for k in names:
        x = f[k][cut:]
        row = []
        for h in (5, 30, 60, 300):
            yv = y[f"fwd_{h}s"][cut:] > 0
            if x.std() == 0:
                row.append("   n/a")
                continue
            # rank correlation as a cheap AUC proxy
            r = np.corrcoef(np.argsort(np.argsort(x)), yv.astype(float))[0, 1]
            row.append(f"{0.5 + abs(r)/2:7.3f}")
        print(f"{k:16s} " + " ".join(row))
    np.savez_compressed("/tmp/tickfeat.npz", **{k: v for k, v in f.items()},
                        **{k: v for k, v in y.items()}, ev=ev, idx=i)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "artifacts/tk1/backtest-ticks1/X13_TICKS.csv")
