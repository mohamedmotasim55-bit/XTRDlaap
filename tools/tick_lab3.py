"""X13 tick study v3 - bid/ask only.

v2's imbalance feature was built on `last`, which is 0 for 100% of ticks on
this feed, so that result was an artefact. This version uses only fields that
actually exist: bid, ask, tick volume and arrival timing.

Features (all past-only):
  uptick  : (bid increases - bid decreases) / ticks over a window, in [-1,1]
  rate    : ticks per second over the window
  spr     : current spread vs its rolling median

Event backtest is strictly non-overlapping: one trade at a time, full spread
charged (enter at ask, exit at bid for longs).
"""
from __future__ import annotations

import sys

import numpy as np

POINT = 0.01


def load(path):
    msc, bid, ask, vol = [], [], [], []
    with open(path) as fh:
        next(fh)
        for line in fh:
            p = line.split(",")
            msc.append(int(p[0])); bid.append(float(p[1]))
            ask.append(float(p[2])); vol.append(int(p[4]))
    return (np.array(msc, dtype=np.int64), np.array(bid), np.array(ask), np.array(vol))


def window_feats(t, b, win_ms):
    """Uptick ratio and rate over a trailing window ending at each tick."""
    n = len(t)
    j = np.minimum(np.searchsorted(t, t - win_ms, side="left"), n - 1)
    db = np.sign(np.diff(b, prepend=b[0]))
    up = np.cumsum(db > 0)
    dn = np.cumsum(db < 0)
    cnt = np.arange(n)
    u = up - up[j]
    d = dn - dn[j]
    tot = np.maximum(cnt - j, 1)
    return (u - d) / tot, tot / (win_ms / 1000.0)


def event_bt(t, b, a, signal, hold_sec, min_gap_sec=0, deposit=10.0, lot=0.01,
             side="both", first_half_only=None):
    n = len(t)
    hold_ms = hold_sec * 1000
    gap_ms = max(min_gap_sec * 1000, hold_ms)
    trades = []
    i = 0
    span = t[-1] - t[0]
    while i < n - 1:
        if first_half_only is True and t[i] - t[0] > span // 2:
            break
        if first_half_only is False and t[i] - t[0] < span // 2:
            i += 1
            continue
        s = signal[i]
        if s != 0 and (side == "both" or (side == "long" and s > 0) or (side == "short" and s < 0)):
            j = int(np.searchsorted(t, t[i] + hold_ms, side="left"))
            if j >= n:
                break
            pts = ((b[j] - a[i]) if s > 0 else (b[i] - a[j])) / POINT
            trades.append(pts)
            i = int(np.searchsorted(t, t[i] + gap_ms, side="left"))
            continue
        i += 1
    return np.array(trades) if trades else np.array([])


def summarize(name, pnl, lot=0.01):
    if len(pnl) < 20:
        return None
    money = pnl * POINT * 100 * lot  # 1 point = 0.01 USD per 0.01 lot
    money = pnl * 0.01 * lot / 0.01
    w = money[money > 0]; l = money[money < 0]
    eq = 10 + np.cumsum(money)
    dd = float((np.maximum.accumulate(eq) - eq).max())
    t = pnl.mean() / (pnl.std(ddof=1) / np.sqrt(len(pnl))) if pnl.std() > 0 else 0
    return (f"{name:34s} n={len(pnl):5d} win={100*len(w)/len(pnl):5.1f}% "
            f"PF={(w.sum()/-l.sum()) if len(l) and l.sum()<0 else 9.99:5.2f} "
            f"exp={pnl.mean():+7.1f} net=${money.sum():+7.2f} final=${eq[-1]:7.2f} "
            f"DD=${dd:6.2f} t={t:+5.1f}")


def main(path):
    t, b, a, vol = load(path)
    spread = (a - b) / POINT
    print(f"ticks={len(t):,}  days={(t[-1]-t[0])/86400000:.1f}  "
          f"spread mean={spread.mean():.1f} median={np.median(spread):.1f}")

    up5, rate5 = window_feats(t, b, 5000)
    up30, rate30 = window_feats(t, b, 30000)
    print(f"uptick5s quantiles {np.round(np.quantile(up5,[0.05,0.5,0.95]),2)}")
    print(f"rate5s   quantiles {np.round(np.quantile(rate5,[0.05,0.5,0.95]),1)}")

    print("\n=== non-overlapping event backtests ===")
    for hold in (60, 300, 900):
        for thr in (0.4, 0.6, 0.8):
            sig = np.where(up5 >= thr, 1, np.where(up5 <= -thr, -1, 0))
            for side in ("long", "both"):
                pnl = event_bt(t, b, a, sig, hold, side=side)
                line = summarize(f"up5>={thr} hold{hold}s {side}", pnl)
                if line:
                    print(line)

    print("\n=== slow filter: uptick over 30s, hold 900s ===")
    for thr in (0.3, 0.5, 0.7):
        sig = np.where(up30 >= thr, 1, np.where(up30 <= -thr, -1, 0))
        for side in ("long", "both"):
            pnl = event_bt(t, b, a, sig, 900, side=side)
            line = summarize(f"up30>={thr} hold900s {side}", pnl)
            if line:
                print(line)

    print("\n=== walk-forward split (up30>=0.5, hold 900, both) ===")
    sig = np.where(up30 >= 0.5, 1, np.where(up30 <= -0.5, -1, 0))
    for label, fh in (("first half", True), ("second half", False)):
        pnl = event_bt(t, b, a, sig, 900, side="both", first_half_only=fh)
        line = summarize(f"  {label}", pnl)
        if line:
            print(line)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "artifacts/tk1/backtest-ticks1/X13_TICKS.csv")
