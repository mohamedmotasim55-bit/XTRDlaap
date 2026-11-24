"""X13 tick predictability study v2.

Fixes the unit error of v1 (values were price units, not points) and reports
the DRIFT-ADJUSTED conditional edge, because the unconditional drift of the
sample is negative and would otherwise be mistaken for a signal.
"""
from __future__ import annotations

import sys

import numpy as np

POINT = 0.01
HORIZONS = [1, 5, 10, 30, 60, 180, 300, 600, 900]


def load(path):
    msc, bid, ask, last, vol, flags = [], [], [], [], [], []
    with open(path) as fh:
        next(fh)
        for line in fh:
            p = line.split(",")
            msc.append(int(p[0]))
            bid.append(float(p[1]))
            ask.append(float(p[2]))
            last.append(float(p[3]))
            vol.append(int(p[4]))
            flags.append(int(p[5]))
    return (np.array(msc, dtype=np.int64), np.array(bid), np.array(ask),
            np.array(last), np.array(vol), np.array(flags))


def fwd(mid, t, h):
    j = np.minimum(np.searchsorted(t, t + h * 1000, side="left"), len(t) - 1)
    return (mid[j] - mid) / POINT


def tstat(x):
    n = len(x)
    if n < 200:
        return None
    m = x.mean()
    se = x.std(ddof=1) / np.sqrt(n)
    return n, m, se, m / se if se > 0 else 0.0


def main(path):
    t, b, a, last, vol, flags = load(path)
    mid = (b + a) / 2.0
    spread = (a - b) / POINT
    n = len(t)
    print(f"ticks={n:,}  span={(t[-1]-t[0])/86400000:.1f} days")
    print(f"spread pts mean={spread.mean():.1f} median={np.median(spread):.1f}")

    last_valid = (flags & 32) != 0
    print(f"ticks carrying a last price: {100*last_valid.mean():.1f}%")
    print(f"bid changes: {100*(np.diff(b)!=0).mean():.1f}%   ask changes: {100*(np.diff(a)!=0).mean():.1f}%")
    print()

    base = {h: fwd(mid, t, h) for h in HORIZONS}
    print("=== unconditional (points) ===")
    print(f"{'h':>5s} {'mean|mv|':>9s} {'mean':>8s} {'P(up)':>6s} {'P(|mv|>sp)':>11s}")
    for h in HORIZONS:
        f = base[h]
        print(f"{h:5d} {np.abs(f).mean():9.1f} {f.mean():+8.1f} {100*(f>0).mean():5.1f}% "
              f"{100*(np.abs(f)>spread.mean()).mean():10.1f}%")

    # past-only features, in points
    def past(h):
        j = np.minimum(np.searchsorted(t, t - h * 1000, side="left"), n - 1)
        return (mid - mid[j]) / POINT

    r1, r5, r30 = past(1), past(5), past(30)
    j5 = np.minimum(np.searchsorted(t, t - 5000, side="left"), n - 1)
    ticks5 = (np.arange(n) - j5).astype(float)
    imb = np.where(spread > 0, (last - mid) / POINT / np.maximum(spread, 1e-9), 0.0)
    imb[~last_valid] = 0.0
    accel = r1 - past(2)

    feats = {"ret1s": r1, "ret5s": r5, "ret30s": r30, "ticks5s": ticks5,
             "accel1s": accel, "imbalance": imb}

    print()
    print("=== drift-adjusted conditional edge (points), deciles ===")
    print(f"{'feature/bucket':26s} {'n':>9s} " + " ".join(f"{'h'+str(h):>17s}" for h in (30, 60, 300, 900)))
    best = []
    for name, v in feats.items():
        q = np.quantile(v, [0.1, 0.5, 0.9])
        for label, mask in ((f"{name} LOW", v <= q[0]), (f"{name} MID", (v > q[0]) & (v < q[2])),
                            (f"{name} HIGH", v >= q[2])):
            cells = []
            for h in (30, 60, 300, 900):
                s = tstat(base[h][mask])
                if s:
                    edge = s[1] - base[h].mean()
                    cells.append(f"{edge:+7.1f}(t{s[3]:+5.1f})")
                    best.append((name, label, h, edge, s[3], s[0]))
                else:
                    cells.append("      n/a      ")
            print(f"{label:26s} {mask.sum():9,d} " + " ".join(f"{c:>17s}" for c in cells))

    print()
    print("=== cells with edge above the spread (26 pts) and |t|>3 ===")
    hits = [x for x in best if x[3] > spread.mean() and abs(x[4]) > 3]
    for name, label, h, edge, tt, cnt in sorted(hits, key=lambda x: -x[3]):
        print(f"  {label:26s} h={h:4d}s edge={edge:+7.1f} t={tt:+5.1f} n={cnt:,d} "
              f"net={edge - spread.mean():+7.1f}")
    if not hits:
        print("  none")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "artifacts/tk1/backtest-ticks1/X13_TICKS.csv")
