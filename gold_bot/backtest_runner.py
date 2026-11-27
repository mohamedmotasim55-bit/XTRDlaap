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
import adaptive_trailing
import indicators
import regime_detector
import strategy_engine
from adaptive_brain import AdaptiveBrain
from dynamic_lot_sizer import DynamicLotSizer

log = logging.getLogger(__name__)


def _limit_hit(direction, limit, low, high):
    return (direction == "BUY" and low <= limit) or (direction == "SELL" and high >= limit)


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


_PREP_CACHE = {}


def _prepare_frames(m1_df, m5_df, point):
    key = (id(m1_df), len(m1_df), id(m5_df) if m5_df is not None else None, point)
    hit = _PREP_CACHE.get(key)
    if hit is not None:
        return hit
    m1 = indicators.add_indicators(m1_df.copy().reset_index(drop=True), point=point)
    m5 = None
    if m5_df is not None:
        m5 = m5_df.reset_index(drop=True).copy()
        if {"high", "low", "close"}.issubset(m5.columns):
            m5["m5_ema_21"] = m5["close"].ewm(span=21, adjust=False).mean()
            m5["m5_ema_50"] = m5["close"].ewm(span=config.EMA_SLOW, adjust=False).mean()
            m5["m5_ema21_slope"] = m5["m5_ema_21"].diff()
            m5["m5_adx_14"] = indicators._adx(m5, 14)
            v, up, lo = indicators.vwap_bands(m5, 1.75)
            m5["m5_vwap"], m5["m5_vwap_upper"], m5["m5_vwap_lower"] = v, up, lo
            prev_close = m5["close"].shift(1)
            tr = pd.concat([m5["high"] - m5["low"],
                            (m5["high"] - prev_close).abs(),
                            (m5["low"] - prev_close).abs()], axis=1).max(axis=1)
            m5_atr = tr.rolling(14).mean()
            body = (m5["close"] - m5["open"]).abs()
            m5["m5_ob_bull"] = ((m5["close"] > m5["open"]) & (body > 1.2 * m5_atr)).astype(int)
            m5["m5_ob_bear"] = ((m5["close"] < m5["open"]) & (body > 1.2 * m5_atr)).astype(int)
            m5["order_block_bull"] = m5["m5_ob_bull"]
            m5["order_block_bear"] = m5["m5_ob_bear"]
            m5["fvg_bull"] = (m5["low"] > m5["high"].shift(2)).astype(int)
            m5["fvg_bear"] = (m5["high"] < m5["low"].shift(2)).astype(int)
            m5["swing_high_20"] = m5["high"].rolling(20).max().shift(1)
            m5["swing_low_20"] = m5["low"].rolling(20).min().shift(1)
            m5["inside_bar"] = ((m5["high"] < m5["high"].shift(1))
                                & (m5["low"] > m5["low"].shift(1))).astype(int)
            st, st_dir = indicators._supertrend(m5, 10, 2.5)
            m5["supertrend"] = st
            m5["supertrend_dir"] = st_dir
            indicators.add_zone_levels(m5, ("fvg_bull", "fvg_bear",
                                            "order_block_bull", "order_block_bear"), 10)
    m15 = BacktestRunner._resample_m15(m1_df)
    if m15 is not None:
        m15 = indicators.add_indicators(m15, point=point)
    if len(_PREP_CACHE) > 8:
        _PREP_CACHE.clear()
    _PREP_CACHE[key] = (m1, m5, m15)
    return m1, m5, m15


class BacktestRunner:
    def __init__(self, m1_df, m5_df=None, initial_balance=10.0, spread_points=26.0,
                 point=0.01, warmup=60, journal_path="logs/backtest_results.csv",
                 verbose=True, use_dynamic_lots=True, strategies=None, overrides=None):
        self.point = point
        self.spread_points = float(spread_points)
        self.initial_balance = float(initial_balance)
        self.warmup = int(warmup)
        self.journal_path = journal_path
        self.verbose = verbose
        self.use_dynamic_lots = use_dynamic_lots
        self.overrides = dict(overrides or {})
        if strategies is not None:
            self.overrides["ENABLED_STRATEGIES"] = tuple(strategies)
        self._sizer = DynamicLotSizer(mt5_module=None)
        self.m1, self.m5, self.m15 = _prepare_frames(m1_df, m5_df, point)

    @staticmethod
    def _resample_m15(m1_df):
        if m1_df is None or "time" not in m1_df.columns or len(m1_df) < 15:
            return None
        d = m1_df.copy()
        d["time"] = pd.to_datetime(d["time"])
        agg = dict(open="first", high="max", low="min", close="last")
        if "tick_volume" in d.columns:
            agg["tick_volume"] = "sum"
        g = d.set_index("time").resample("15min").agg(agg).dropna(
            subset=["open", "high", "low", "close"]).reset_index()
        return g if len(g) else None

    def _m15_slice(self, i):
        if self.m15 is None:
            return None
        return self.m15.iloc[: max(1, i // 15 + 1)]

    def _m5_slice(self, i):
        if self.m5 is None:
            return None
        return self.m5.iloc[: max(1, i // 5 + 1)]

    def run(self):
        if not self.overrides:
            return self._run()
        old = {k: getattr(config, k) for k in self.overrides}
        try:
            for k, v in self.overrides.items():
                setattr(config, k, v)
            return self._run()
        finally:
            for k, v in old.items():
                setattr(config, k, v)

    def _run(self):
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
                     daily_dd=0, pause=0, daycap=0, opened=0,
                     limit_placed=0, limit_filled=0, limit_expired=0)
        pending = None
        trades_today = 0
        last_entry_i = -10 ** 9
        consec_losses = 0
        pause_until_i = -1
        cur_time = None  # simulated clock so brain mutes expire in bar-time

        def close_pos(p, price, reason):
            nonlocal balance, consec_losses
            raw = (price - p["entry"]) / self.point if p["dir"] == "BUY" else (p["entry"] - price) / self.point
            net = raw - self.spread_points
            pnl = net * p["lots"]
            balance += pnl
            tier = p.get("tier") or "NA"
            trades.append(dict(ticket=p["ticket"], strategy=p["strategy"], direction=p["dir"],
                               entry_price=round(p["entry"], 3), sl=round(p["sl"], 3),
                               tp=round(p["tp"], 3), close_price=round(price, 3),
                               profit_usd=round(pnl, 2), profit_points=round(net, 1),
                               confidence=p.get("conf", 0.0), close_reason=reason,
                               tier=tier))
            tt = audit.setdefault("tiers", {}).setdefault(
                tier, {"trades": 0, "wins": 0, "net": 0.0})
            tt["trades"] += 1
            tt["net"] += pnl
            if pnl > 0:
                tt["wins"] += 1
            brain.record_trade(p["strategy"], pnl, now=cur_time)
            consec_losses = consec_losses + 1 if pnl < 0 else 0

        def open_position(i, direction, entry, sl, tp, strategy, conf, ts, meta=None):
            nonlocal ticket, last_entry_i, trades_today
            n_open = len(positions)
            can = n_open == 0
            if not can and n_open == 1 and config.ENABLE_ZERO_RISK_PYRAMID \
                    and n_open < config.MAX_TOTAL_TRADES_WITH_PYRAMID:
                ex = positions[0]
                same = ex["dir"] == direction
                risk_free = (ex["sl"] >= ex["entry"]) if ex["dir"] == "BUY" else (ex["sl"] <= ex["entry"] and ex["sl"] > 0)
                can = same and risk_free
            if not can:
                return False
            cooldown_bars = max(1, int(config.COOLDOWN_SECONDS // 60))
            if i - last_entry_i < cooldown_bars:
                audit["cooldown"] += 1
                return False
            lot = config.LOT_SIZE
            if self.use_dynamic_lots:
                lot = self._sizer.size(equity, peak_equity, price=entry)
                if n_open >= 1:
                    lot = min(lot, 0.01)
            margin_needed = lot * config.CONTRACT_SIZE * entry / config.ACCOUNT_LEVERAGE
            if (equity - margin_needed) < config.MIN_FREE_MARGIN_USD:
                audit["margin"] += 1
                return False
            pos = dict(ticket=ticket, dir=direction, entry=entry,
                       sl=sl, tp=tp, lots=lot, strategy=strategy, conf=conf,
                       open_time=ts)
            if meta:
                pos.update(meta)
            positions.append(pos)
            ticket += 1
            last_entry_i = i
            trades_today += 1
            audit["opened"] += 1
            return True

        for i in range(self.warmup, n):
            row = m1.iloc[i]
            ts = row["time"]
            cur_time = ts
            d = ts.date() if hasattr(ts, "date") else None
            if d != day:
                day, day_start_equity, ratchet_peak, ratchet_locked = d, balance, 0.0, False
                trades_today = 0

            for p in list(positions):
                if p["dir"] == "BUY":
                    if row["low"] <= p["sl"]:
                        close_pos(p, p["sl"], "SL"); positions.remove(p); continue
                    if row["high"] >= p["tp"]:
                        close_pos(p, p["tp"], "TP"); positions.remove(p); continue
                    prof = (row["close"] - p["entry"]) / self.point
                    if p.get("tier") in ("T1", "T2", "T3"):
                        new_sl = self._adaptive_sl(p, row, i, m1)
                        if new_sl is not None and new_sl > p["sl"]:
                            p["sl"] = new_sl
                    else:
                        if prof >= p.get("be_trigger", config.BREAKEVEN_TRIGGER_POINTS) \
                                and p["sl"] < p["entry"]:
                            p["sl"] = p["entry"] + p.get("be_lock", config.BREAKEVEN_LOCK_POINTS) * self.point
                        if prof >= p.get("trail_start", config.TRAILING_START_POINTS):
                            atr = float(row.get("atr_14", 0.0) or 0.0)
                            if atr > 0:
                                cand = row["close"] - config.TRAILING_ATR_MULT * atr
                                if cand > p["sl"]:
                                    p["sl"] = cand
                    if self._scalp_expired(p, ts):
                        close_pos(p, row["close"], "TIME"); positions.remove(p); continue
                else:
                    if row["high"] >= p["sl"]:
                        close_pos(p, p["sl"], "SL"); positions.remove(p); continue
                    if row["low"] <= p["tp"]:
                        close_pos(p, p["tp"], "TP"); positions.remove(p); continue
                    prof = (p["entry"] - row["close"]) / self.point
                    if p.get("tier") in ("T1", "T2", "T3"):
                        new_sl = self._adaptive_sl(p, row, i, m1)
                        if new_sl is not None and (p["sl"] == 0 or new_sl < p["sl"]):
                            p["sl"] = new_sl
                    else:
                        if prof >= p.get("be_trigger", config.BREAKEVEN_TRIGGER_POINTS) \
                                and (p["sl"] == 0 or p["sl"] > p["entry"]):
                            p["sl"] = p["entry"] - p.get("be_lock", config.BREAKEVEN_LOCK_POINTS) * self.point
                        if prof >= p.get("trail_start", config.TRAILING_START_POINTS):
                            atr = float(row.get("atr_14", 0.0) or 0.0)
                            if atr > 0:
                                cand = row["close"] + config.TRAILING_ATR_MULT * atr
                                if cand < p["sl"]:
                                    p["sl"] = cand
                    if self._scalp_expired(p, ts):
                        close_pos(p, row["close"], "TIME"); positions.remove(p); continue

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

            if pending is not None:
                if positions:
                    pending = None
                else:
                    hit = _limit_hit(pending["dir"], pending["limit"],
                                     row["low"], row["high"])
                    if hit and i > pending["placed_i"]:
                        delta = pending["limit"] - pending["sig"].entry
                        if open_position(i, pending["dir"], pending["limit"],
                                         pending["sl"] + delta, pending["tp"] + delta,
                                         pending["strategy"], pending["conf"], ts,
                                         pending.get("meta")):
                            audit["limit_filled"] += 1
                        pending = None
                    elif i - pending["placed_i"] >= pending["ttl"]:
                        audit["limit_expired"] += 1
                        pending = None

            sub = m1.iloc[: i + 1]
            m5sub = self._m5_slice(i)
            m15sub = self._m15_slice(i)
            regime = regime_detector.RegimeDetector.classify(sub, m5sub)
            sig = strategy_engine.generate_signal(sub, mode, m5sub, regime=regime,
                                                  df_m15=m15sub)
            if not sig:
                continue
            audit["raw"] += 1

            allowed, conf, _ = brain.evaluate(sig, regime, now=ts)
            if not allowed:
                audit["conf"] += 1
                continue

            sl_points = abs(row["close"] - sig.sl) / self.point
            if (self.spread_points > config.MAX_SPREAD_POINTS
                    or self.spread_points > config.SPREAD_SL_RATIO * sl_points
                    or sig.atr_points < config.ATR_SPREAD_MULT * self.spread_points):
                audit["spread"] += 1
                continue

            if trades_today >= config.MAX_TRADES_PER_DAY:
                audit["daycap"] += 1
                continue

            if sig.entry_type == "LIMIT" and sig.limit_price > 0 and pending is None:
                pending = dict(sig=sig, dir=sig.signal, limit=sig.limit_price,
                               sl=sig.sl, tp=sig.tp, strategy=sig.strategy,
                               conf=conf, placed_i=i, ttl=1, meta=self._meta(sig))
                audit["limit_placed"] += 1
                continue

            open_position(i, sig.signal, row["close"], sig.sl, sig.tp,
                          sig.strategy, conf, ts, self._meta(sig))

        if positions:
            last = m1.iloc[-1]
            for p in list(positions):
                close_pos(p, last["close"], "EOD"); positions.remove(p)

        return self._report(trades, balance, max_dd, audit)

    def _adaptive_sl(self, p, row, i, m1):
        prof = ((row["close"] - p["entry"]) / self.point if p["dir"] == "BUY"
                else (p["entry"] - row["close"]) / self.point)
        prev_rsi = None
        try:
            if i > 0:
                prev_rsi = float(m1["rsi_7"].iloc[i - 1])
        except (KeyError, TypeError, ValueError):
            prev_rsi = None
        lock = adaptive_trailing.lock_points(
            p["dir"], prof, p.get("atr_points", 0.0), row.get("rsi_7"), prev_rsi,
            row.get("tick_volume"), row.get("vol_ma_10"), row.get("adx_14"))
        if lock is None:
            return None
        return (p["entry"] + lock * self.point if p["dir"] == "BUY"
                else p["entry"] - lock * self.point)

    @staticmethod
    def _meta(sig):
        return dict(tier=sig.tier or "NA", score=sig.score, atr_points=sig.atr_points,
                    be_trigger=sig.be_trigger or config.BREAKEVEN_TRIGGER_POINTS,
                    be_lock=sig.be_lock or config.BREAKEVEN_LOCK_POINTS,
                    trail_start=sig.trail_start or config.TRAILING_START_POINTS,
                    max_hold_minutes=sig.max_hold_minutes or 0)

    @staticmethod
    def _scalp_expired(pos, ts):
        hold = pos.get("max_hold_minutes") or 0
        if not hold:
            return False
        try:
            return (ts - pos["open_time"]).total_seconds() / 60.0 >= hold
        except (KeyError, TypeError):
            return False

    def _report(self, trades, final_balance, max_dd, audit=None):
        n = len(trades)
        wins = sum(1 for t in trades if t["profit_usd"] > 0)
        losses = sum(1 for t in trades if t["profit_usd"] < 0)
        gp = sum(t["profit_usd"] for t in trades if t["profit_usd"] > 0)
        gl = -sum(t["profit_usd"] for t in trades if t["profit_usd"] < 0)
        pf = gp / gl if gl > 0 else (float("inf") if gp > 0 else 0.0)
        by, byd = {}, {}
        for t in trades:
            d = byd.setdefault(t["direction"], {"n": 0, "wins": 0, "net": 0.0})
            d["n"] += 1; d["net"] += t["profit_usd"]
            if t["profit_usd"] > 0: d["wins"] += 1
            s = by.setdefault(t["strategy"], {"n": 0, "wins": 0, "net": 0.0})
            s["n"] += 1; s["net"] += t["profit_usd"]
            if t["profit_usd"] > 0: s["wins"] += 1
        res = dict(initial_balance=self.initial_balance, final_balance=round(final_balance, 2),
                   total_trades=n, wins=wins, losses=losses,
                   win_rate=(100 * wins / n if n else 0.0), profit_factor=pf,
                   net_profit=round(final_balance - self.initial_balance, 2),
                   max_drawdown_usd=round(max_dd, 2),
                   max_drawdown_pct=(100 * max_dd / self.initial_balance if self.initial_balance else 0.0),
                   by_strategy=by, by_direction=byd, signal_audit=audit or {},
                   tiers=(audit or {}).get("tiers", {}))
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
                    "close_price", "profit_usd", "profit_points", "confidence",
                    "close_reason", "tier"]
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
              f"pause_rej={a.get('pause',0)} daycap_rej={a.get('daycap',0)} "
              f"limit_placed={a.get('limit_placed',0)} "
              f"limit_filled={a.get('limit_filled',0)} "
              f"limit_expired={a.get('limit_expired',0)} opened={a.get('opened',0)}")
        print("-" * 64)
        print(f" {'Strategy':<22}{'Trades':>7}{'Win%':>8}{'Net$':>10}")
        for name, d in r["by_strategy"].items():
            wr = (100 * d["wins"] / d["n"]) if d["n"] else 0.0
            print(f" {name:<22}{d['n']:>7}{wr:>8.1f}{d['net']:>10.2f}")
        print("-" * 64)
        for name, d in (r.get("by_direction") or {}).items():
            wr = (100 * d["wins"] / d["n"]) if d["n"] else 0.0
            print(f" {name:<22}{d['n']:>7}{wr:>8.1f}{d['net']:>10.2f}")
        tiers = r.get("tiers") or {}
        if tiers:
            print(f" {'Tier':<22}{'Trades':>7}{'Win%':>8}{'Net$':>10}")
            for name, d in tiers.items():
                wr = (100 * d["wins"] / d["trades"]) if d["trades"] else 0.0
                print(f" {name:<22}{d['trades']:>7}{wr:>8.1f}{d['net']:>10.2f}")
        print("=" * 64)


def load_csv(path):
    df = pd.read_csv(path)
    df["time"] = pd.to_datetime(df["time"])
    return df
