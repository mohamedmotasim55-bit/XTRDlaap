"""
backtest_runner.py
==================
Realistic bar-based MT5 simulator for the whole bot pipeline:
Regime + 7 Strategies + AdaptiveBrain + spread + BE/trailing + pyramid +
daily drawdown/ratchet.  Accepts local DataFrames (offline) or CSV.
"""
from __future__ import annotations

import csv
import logging
import os
from typing import Optional

import pandas as pd

import config
import indicators
import regime_detector
import strategy_engine
from adaptive_brain import AdaptiveBrain
from dynamic_lot_sizer import DynamicLotSizer

log = logging.getLogger(__name__)


def _session_mode(ts):
    try:
        t = ts.time()
    except Exception:  # noqa: BLE001
        return config.SESSION_MODE_MOMENTUM
    if config.ASIAN_RANGE_START <= t < config.ASIAN_RANGE_END:
        return config.SESSION_MODE_ASIAN
    if config.MOMENTUM_START <= t < config.MOMENTUM_END:
        return config.SESSION_MODE_MOMENTUM
    return config.SESSION_MODE_STOP


class BacktestRunner:
    def __init__(self, m1_df, m5_df=None, initial_balance=10.0, spread_points=26.0,
                 point=0.01, warmup=60, journal_path="logs/backtest_results.csv",
                 verbose=True, use_dynamic_lots=True):
        self.point = point
        self.spread_points = float(spread_points)
        self.initial_balance = float(initial_balance)
        self.warmup = int(warmup)
        self.journal_path = journal_path
        self.verbose = verbose
        self.use_dynamic_lots = use_dynamic_lots
        self._sizer = DynamicLotSizer(mt5_module=None)
        self.m1 = indicators.add_indicators(m1_df.copy().reset_index(drop=True), point=point)
        self.m5 = m5_df.reset_index(drop=True) if m5_df is not None else None

    def _m5_slice(self, i):
        if self.m5 is None:
            return None
        return self.m5.iloc[: max(1, i // 5 + 1)]

    def run(self):
        m1 = self.m1
        n = len(m1)
        balance = self.initial_balance
        positions, trades = [], []
        brain = AdaptiveBrain()
        peak_equity, max_dd = balance, 0.0
        day = None
        day_start_equity, ratchet_peak, ratchet_locked = balance, 0.0, False
        ticket = 1
        audit = dict(raw=0, conf=0, spread=0, cooldown=0, margin=0,
                     daily_dd=0, pause=0, opened=0)
        last_entry_i = -10 ** 9
        consec_losses = 0
        pause_until_i = -1

        def close_pos(p, price, reason):
            nonlocal balance, consec_losses
            raw = (price - p["entry"]) / self.point if p["dir"] == "BUY" else (p["entry"] - price) / self.point
            net = raw - self.spread_points
            pnl = net * p["lots"]
            balance += pnl
            trades.append(dict(ticket=p["ticket"], strategy=p["strategy"], direction=p["dir"],
                               entry_price=round(p["entry"], 3), sl=round(p["sl"], 3),
                               tp=round(p["tp"], 3), close_price=round(price, 3),
                               profit_usd=round(pnl, 2), profit_points=round(net, 1),
                               confidence=p.get("conf", 0.0), close_reason=reason))
            brain.record_trade(p["strategy"], pnl)
            consec_losses = consec_losses + 1 if pnl < 0 else 0

        for i in range(self.warmup, n):
            row = m1.iloc[i]
            ts = row["time"]
            d = ts.date() if hasattr(ts, "date") else None
            if d != day:
                day, day_start_equity, ratchet_peak, ratchet_locked = d, balance, 0.0, False

            for p in list(positions):
                if p["dir"] == "BUY":
                    if row["low"] <= p["sl"]:
                        close_pos(p, p["sl"], "SL"); positions.remove(p); continue
                    if row["high"] >= p["tp"]:
                        close_pos(p, p["tp"], "TP"); positions.remove(p); continue
                    prof = (row["close"] - p["entry"]) / self.point
                    if prof >= config.BREAKEVEN_TRIGGER_POINTS and p["sl"] < p["entry"]:
                        p["sl"] = p["entry"] + config.BREAKEVEN_LOCK_POINTS * self.point
                    if prof >= config.TRAILING_START_POINTS:
                        atr = float(row.get("atr_14", 0.0) or 0.0)
                        if atr > 0:
                            cand = row["close"] - config.TRAILING_ATR_MULT * atr
                            if cand > p["sl"]:
                                p["sl"] = cand
                else:
                    if row["high"] >= p["sl"]:
                        close_pos(p, p["sl"], "SL"); positions.remove(p); continue
                    if row["low"] <= p["tp"]:
                        close_pos(p, p["tp"], "TP"); positions.remove(p); continue
                    prof = (p["entry"] - row["close"]) / self.point
                    if prof >= config.BREAKEVEN_TRIGGER_POINTS and (p["sl"] == 0 or p["sl"] > p["entry"]):
                        p["sl"] = p["entry"] - config.BREAKEVEN_LOCK_POINTS * self.point
                    if prof >= config.TRAILING_START_POINTS:
                        atr = float(row.get("atr_14", 0.0) or 0.0)
                        if atr > 0:
                            cand = row["close"] + config.TRAILING_ATR_MULT * atr
                            if cand < p["sl"]:
                                p["sl"] = cand

            floating = 0.0
            for p in positions:
                if p["dir"] == "BUY":
                    floating += ((row["close"] - p["entry"]) / self.point - self.spread_points) * p["lots"]
                else:
                    floating += ((p["entry"] - row["close"]) / self.point - self.spread_points) * p["lots"]
            equity = balance + floating
            peak_equity = max(peak_equity, equity)
            max_dd = max(max_dd, peak_equity - equity)

            day_pnl = equity - day_start_equity
            ratchet_peak = max(ratchet_peak, day_pnl)
            if ratchet_peak >= config.PROFIT_RATCHET_START_USD and \
                    day_pnl < config.PROFIT_RATCHET_KEEP_PCT * ratchet_peak:
                ratchet_locked = True
            if ratchet_locked:
                continue

            mode = _session_mode(ts)
            if mode == config.SESSION_MODE_STOP:
                continue

            if consec_losses >= config.CONSECUTIVE_LOSS_TRIGGER:
                pause_until_i = max(pause_until_i,
                                    i + int(config.CONSECUTIVE_LOSS_PAUSE_MIN))
                consec_losses = 0
            if i < pause_until_i:
                audit["pause"] += 1
                continue

            if day_pnl <= -config.DAILY_LOSS_LIMIT_USD:
                audit["daily_dd"] += 1
                continue

            sub = m1.iloc[: i + 1]
            m5sub = self._m5_slice(i)
            regime = regime_detector.RegimeDetector.classify(sub, m5sub)
            sig = strategy_engine.generate_signal(sub, mode, m5sub, regime=regime)
            if not sig:
                continue
            audit["raw"] += 1

            allowed, conf, _ = brain.evaluate(sig, regime)
            if not allowed:
                audit["conf"] += 1
                continue

            sl_points = abs(row["close"] - sig.sl) / self.point
            if (self.spread_points > config.MAX_SPREAD_POINTS
                    or self.spread_points > config.SPREAD_SL_RATIO * sl_points):
                audit["spread"] += 1
                continue

            n_open = len(positions)
            can = n_open == 0
            if not can and n_open == 1 and config.ENABLE_ZERO_RISK_PYRAMID \
                    and n_open < config.MAX_TOTAL_TRADES_WITH_PYRAMID:
                ex = positions[0]
                same = ex["dir"] == sig.signal
                risk_free = (ex["sl"] >= ex["entry"]) if ex["dir"] == "BUY" else (ex["sl"] <= ex["entry"] and ex["sl"] > 0)
                can = same and risk_free
            if not can:
                continue

            cooldown_bars = max(1, int(config.COOLDOWN_SECONDS // 60))
            if i - last_entry_i < cooldown_bars:
                audit["cooldown"] += 1
                continue

            lot = config.LOT_SIZE
            if self.use_dynamic_lots:
                lot = self._sizer.size(equity, peak_equity, price=row["close"])
                if n_open >= 1:
                    lot = min(lot, 0.01)

            margin_needed = lot * config.CONTRACT_SIZE * row["close"] / config.ACCOUNT_LEVERAGE
            if (equity - margin_needed) < config.MIN_FREE_MARGIN_USD:
                audit["margin"] += 1
                continue

            positions.append(dict(ticket=ticket, dir=sig.signal, entry=row["close"],
                                  sl=sig.sl, tp=sig.tp, lots=lot,
                                  strategy=sig.strategy, conf=conf))
            ticket += 1
            last_entry_i = i
            audit["opened"] += 1

        if positions:
            last = m1.iloc[-1]
            for p in list(positions):
                close_pos(p, last["close"], "EOD"); positions.remove(p)

        return self._report(trades, balance, max_dd, audit)

    def _report(self, trades, final_balance, max_dd, audit=None):
        n = len(trades)
        wins = sum(1 for t in trades if t["profit_usd"] > 0)
        losses = sum(1 for t in trades if t["profit_usd"] < 0)
        gp = sum(t["profit_usd"] for t in trades if t["profit_usd"] > 0)
        gl = -sum(t["profit_usd"] for t in trades if t["profit_usd"] < 0)
        pf = gp / gl if gl > 0 else (float("inf") if gp > 0 else 0.0)
        by = {}
        for t in trades:
            s = by.setdefault(t["strategy"], {"n": 0, "wins": 0, "net": 0.0})
            s["n"] += 1; s["net"] += t["profit_usd"]
            if t["profit_usd"] > 0: s["wins"] += 1
        res = dict(initial_balance=self.initial_balance, final_balance=round(final_balance, 2),
                   total_trades=n, wins=wins, losses=losses,
                   win_rate=(100 * wins / n if n else 0.0), profit_factor=pf,
                   net_profit=round(final_balance - self.initial_balance, 2),
                   max_drawdown_usd=round(max_dd, 2),
                   max_drawdown_pct=(100 * max_dd / self.initial_balance if self.initial_balance else 0.0),
                   by_strategy=by, signal_audit=audit or {})
        self._save(trades)
        if self.verbose:
            self._print(res)
        return res

    def _save(self, trades):
        try:
            parent = os.path.dirname(self.journal_path)
            if parent:
                os.makedirs(parent, exist_ok=True)
            cols = ["ticket", "strategy", "direction", "entry_price", "sl", "tp",
                    "close_price", "profit_usd", "profit_points", "confidence", "close_reason"]
            with open(self.journal_path, "w", newline="", encoding="utf-8") as fh:
                w = csv.writer(fh); w.writerow(cols)
                for t in trades:
                    w.writerow([t.get(c, "") for c in cols])
        except OSError as exc:
            log.warning("Could not save backtest results: %s", exc)

    def _print(self, r):
        pf = "inf" if r["profit_factor"] == float("inf") else f"{r['profit_factor']:.2f}"
        print("=" * 64)
        print(" INSTITUTIONAL BACKTEST REPORT")
        print("-" * 64)
        print(f" Initial: ${r['initial_balance']:.2f}  Final: ${r['final_balance']:.2f}  Net: ${r['net_profit']:.2f}")
        print(f" Trades: {r['total_trades']}  W:{r['wins']}  L:{r['losses']}  WinRate: {r['win_rate']:.1f}%")
        print(f" Profit Factor: {pf}  MaxDD: ${r['max_drawdown_usd']:.2f} ({r['max_drawdown_pct']:.1f}%)")
        a = r.get("signal_audit") or {}
        print(f" Signals: raw={a.get('raw',0)} conf_rej={a.get('conf',0)} "
              f"spread_rej={a.get('spread',0)} cool_rej={a.get('cooldown',0)} "
              f"margin_rej={a.get('margin',0)} dailyDD_rej={a.get('daily_dd',0)} "
              f"pause_rej={a.get('pause',0)} opened={a.get('opened',0)}")
        print("-" * 64)
        print(f" {'Strategy':<22}{'Trades':>7}{'Win%':>8}{'Net$':>10}")
        for name, d in r["by_strategy"].items():
            wr = (100 * d["wins"] / d["n"]) if d["n"] else 0.0
            print(f" {name:<22}{d['n']:>7}{wr:>8.1f}{d['net']:>10.2f}")
        print("=" * 64)


def load_csv(path):
    df = pd.read_csv(path)
    df["time"] = pd.to_datetime(df["time"])
    return df
