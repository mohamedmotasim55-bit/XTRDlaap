"""X13 phase 7 part 2 - sequence model with an economic objective.

The audit proved the feed carries exactly one information channel: the mid
price path. No volume, no spread variation, no bid/ask divergence.

This script therefore asks the only question that is still open: can the
shape of the recent price path predict a barrier outcome (TP hit before SL)
well enough to beat the 26-point spread?

Protocol:
  - 15 s event grid, chronological 60 / 20 / 20 train / validation / test
  - barrier: long enters at ask, TP +tp, SL -sl, timeout 300 s
  - cost is embedded in the fills (buy ask, sell bid)
  - trades are non-overlapping inside the simulator
"""
from __future__ import annotations

import sys

import numpy as np
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score

POINT = 0.01
GRID_MS = 15000
HOLD_S = 300


def load(path):
    msc, bid, ask = [], [], []
    with open(path) as fh:
        next(fh)
        for line in fh:
            p = line.split(",")
            msc.append(int(p[0])); bid.append(float(p[1])); ask.append(float(p[2]))
    return np.array(msc, dtype=np.int64), np.array(bid), np.array(ask)


def features(t, b, a):
    n = len(t)
    mid = (b + a) / 2.0
    dm = np.diff(mid, prepend=mid[0])

    def cs(x):
        return np.concatenate([[0.0], np.cumsum(x, dtype=np.float64)])

    c_abs = cs(np.abs(dm))
    c_pos = cs((dm > 0).astype(float))
    c_neg = cs((dm < 0).astype(float))
    c_rev = cs((np.sign(dm[1:]) != np.sign(dm[:-1])).astype(float))

    ev = np.arange(t[0], t[-1], GRID_MS)
    i = np.clip(np.searchsorted(t, ev, side="right") - 1, 0, n - 1)

    def j_at(ms):
        return np.clip(np.searchsorted(t, ev - ms, side="left"), 0, n - 1)

    cols, names = [], []

    def add(name, arr):
        names.append(name); cols.append(arr.astype(np.float32))

    for ms, tag in ((5000, "5s"), (15000, "15s"), (60000, "60s"), (300000, "300s")):
        j = j_at(ms)
        w = np.maximum(i - j, 1).astype(float)
        add(f"disp_{tag}", (mid[i] - mid[j]) / POINT)
        add(f"eff_{tag}", np.abs(mid[i] - mid[j]) / np.maximum(c_abs[i + 1] - c_abs[j], 1e-9))
        add(f"posfrac_{tag}", (c_pos[i + 1] - c_pos[j]) / w)
        add(f"negfrac_{tag}", (c_neg[i + 1] - c_neg[j]) / w)
        add(f"ticks_{tag}", w)

    j20 = np.clip(i - 20, 0, n - 1)
    add("reversals_20", (c_rev[np.maximum(i, 1)] - c_rev[np.maximum(j20, 1)]) / 20.0)
    add("absdisp_60s", np.abs(mid[i] - mid[j_at(60000)]) / POINT)

    X = np.column_stack(cols)
    return ev, i, X, names, mid, b, a


def barrier_labels(t, b, a, i, tp_pts, sl_pts, hold_s=HOLD_S, side=1):
    """+1 TP first, -1 SL first, 0 timeout. Fills at ask for buys, bid for sells."""
    n = len(t)
    out = np.zeros(len(i), dtype=np.int8)
    end_ms = t + hold_s * 1000
    for k in range(len(i)):
        s = i[k]
        e = int(np.searchsorted(t, end_ms[s], side="left"))
        e = min(max(e, s + 2), n)
        if side > 0:
            entry = a[s]
            tp = entry + tp_pts * POINT
            sl = entry - sl_pts * POINT
            hi = a[s + 1:e] >= tp
            lo = b[s + 1:e] <= sl
        else:
            entry = b[s]
            tp = entry - tp_pts * POINT
            sl = entry + sl_pts * POINT
            lo = b[s + 1:e] <= tp
            hi = a[s + 1:e] >= sl
        itp = np.argmax(hi) if hi.any() else 10 ** 9
        isl = np.argmax(lo) if lo.any() else 10 ** 9
        if itp == isl == 10 ** 9:
            out[k] = 0
        elif itp <= isl:
            out[k] = 1
        else:
            out[k] = -1
    return out


def main(path):
    t, b, a = load(path)
    ev, i, X, names, mid, b, a = features(t, b, a)
    print(f"events={len(ev):,}  features={len(names)}")
    print("features:", ", ".join(names))

    n = len(ev)
    tr, va = int(n * 0.6), int(n * 0.8)
    for tp, sl in ((60, 40), (100, 60), (150, 90)):
        y = barrier_labels(t, b, a, i, tp, sl)
        mask = y != 0
        yb = (y == 1).astype(int)
        base = yb[mask].mean()
        print(f"\n--- TP {tp} / SL {sl} : resolved {mask.sum():,} "
              f"({100*mask.mean():.0f}%), base TP-rate {100*base:.1f}% ---")

        for name, mdl in (("logit", LogisticRegression(max_iter=1000)),
                          ("gbm", HistGradientBoostingClassifier(max_iter=200, max_depth=4,
                                                                 learning_rate=0.06))):
            Xtr, ytr = X[:tr][mask[:tr]], yb[:tr][mask[:tr]]
            Xva, yva = X[tr:va][mask[tr:va]], yb[tr:va][mask[tr:va]]
            Xte, yte = X[va:][mask[va:]], yb[va:][mask[va:]]
            mdl.fit(Xtr, ytr)
            pva = mdl.predict_proba(Xva)[:, 1]
            pte = mdl.predict_proba(Xte)[:, 1]
            auc_v = roc_auc_score(yva, pva)
            auc_t = roc_auc_score(yte, pte)
            print(f"  {name:6s} AUC val={auc_v:.3f} test={auc_t:.3f}")

            for thr in (0.5, 0.55, 0.6):
                sel = pte >= thr
                if sel.sum() < 50:
                    continue
                wr = yte[sel].mean()
                exp_pts = wr * tp - (1 - wr) * sl
                print(f"     thr={thr:.2f} trades={sel.sum():5d} win={100*wr:5.1f}% "
                      f"exp={exp_pts:+7.1f} pts  net_per_day=${exp_pts*0.01*sel.sum()/10:+.2f}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "artifacts/tk1/backtest-ticks1/X13_TICKS.csv")
