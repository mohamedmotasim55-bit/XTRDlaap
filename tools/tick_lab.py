"""X13 tick predictability study.

For every horizon and every past-only feature, measure the conditional
forward move of the mid price in points, its t-statistic, and the net result
after paying one full spread. A cell is only interesting when the mean
forward move exceeds the spread with t > 2.

No future information is used to build a feature; the future is only used to
measure what happened next.
"""
from __future__ import annotations

import sys

import numpy as np

POINT = 0.01
HORIZONS = [1, 5, 10, 30, 60, 180, 300, 600, 900]


def load(path: str):
    msc, bid, ask, last, vol = [], [], [], [], []
    with open(path) as fh:
        next(fh)
        for line in fh:
            p = line.split(",")
            msc.append(int(p[0]))
            bid.append(float(p[1]))
            ask.append(float(p[2]))
            last.append(float(p[3]))
            vol.append(int(p[4]))
    t = np.array(msc, dtype=np.int64)
    b = np.array(bid)
    a = np.array(ask)
    return t, b, a, np.array(last), np.array(vol)


def forward(mid, t, h_sec):
    """Mid change to the first tick at or after t + h."""
    target = t + h_sec * 1000
    j = np.searchsorted(t, target, side="left")
    j = np.minimum(j, len(t) - 1)
    return mid[j] - mid


def stats(x):
    n = len(x)
    if n < 100:
        return None
    m = x.mean()
    se = x.std(ddof=1) / np.sqrt(n)
    return n, m, se, m / se if se > 0 else 0.0


def main(path: str):
    t, b, a, last, vol = load(path)
    mid = (b + a) / 2.0
    spread = (a - b) / POINT
    n = len(t)
    print(f"ticks={n:,}  span={(t[-1]-t[0])/86400000:.1f} days")
    print(f"spread pts: mean {spread.mean():.1f}  median {np.median(spread):.1f}")
    print()

    # --- past-only features ---
    feats = {}
    for h in (1, 5, 30):
        j = np.searchsorted(t, t - h * 1000, side="left")
        feats[f"ret{h}s"] = mid - mid[j]
    j5 = np.searchsorted(t, t - 5000, side="left")
    ticks5 = np.arange(n) - j5
    feats["ticks5s"] = ticks5.astype(float)
    j1 = np.searchsorted(t, t - 1000, side="left")
    feats["accel1s"] = (mid - mid[j1]) - (mid[j1] - mid[np.searchsorted(t, t - 2000, side="left")])
    feats["imbalance"] = np.where(spread > 0, (last - mid) / POINT / np.maximum(spread, 1e-9), 0.0)

    print("=== unconditional forward move (points) ===")
    print(f"{'h':>6s} {'mean|move|':>11s} {'P(up)':>7s} {'mean move':>10s}")
    for h in HORIZONS:
        f = forward(mid, t, h)
        print(f"{h:6d} {np.abs(f).mean():11.1f} {100*(f>0).mean():6.1f}% {f.mean():+10.3f}")

    print()
    print("=== conditional: top/bottom deciles of each feature ===")
    for name, v in feats.items():
        lo = np.quantile(v, 0.10)
        hi = np.quantile(v, 0.90)
        for label, mask in ((f"{name} LOW", v <= lo), (f"{name} HIGH", v >= hi)):
            row = []
            for h in (5, 30, 60, 300):
                f = forward(mid, t, h)[mask]
                s = stats(f)
                if s:
                    row.append(f"h{h}:{s[1]:+7.2f}(t{s[3]:+5.1f})")
            print(f"  {label:22s} n={mask.sum():7,d}  " + "  ".join(row))

    print()
    print("=== how often does a move beat the spread? ===")
    for h in (60, 300, 900):
        f = forward(mid, t, h)
        sp = np.median(spread)
        print(f"  h={h:4d}s  P(|move| > spread={sp:.0f}) = {100*(np.abs(f) > sp).mean():.1f}%"
              f"   P(move > 2*spread) = {100*(np.abs(f) > 2*sp).mean():.1f}%")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "artifacts/tk1/backtest-ticks1/X13_TICKS.csv")
