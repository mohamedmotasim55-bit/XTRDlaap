"""Reconstruct trades from the MT5 Strategy Tester journal.

MT5 in /config mode does not emit report.htm in this build, but the tester
journal records every deal with its execution time and price. For XAUUSD
(contract size 100, 0.01 lot = 1 oz) the P&L of a round trip is
(close - open) * direction * volume * 100 USD, so the journal is enough to
rebuild the trade ledger exactly.
"""
from __future__ import annotations

import json
import re
import sys
from collections import deque
from datetime import datetime

DEAL = re.compile(
    r"(\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2})\s+deal #(\d+) (buy|sell) ([\d.]+) (\S+) at ([\d.]+) done"
)
REQUEST = re.compile(
    r"(\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2})\s+market (buy|sell) ([\d.]+) (\S+) sl: ([\d.]+) tp: ([\d.]+) \(([\d.]+) / ([\d.]+)\)"
)
FINAL_BALANCE = re.compile(r"final balance ([\d.]+) USD")
SUMMARY = re.compile(
    r"OMEGA2 SUMMARY \| engine=(\S+) attempts=(\d+) accepted=(\d+) signal_only=(\d+) lot_reject=(\d+) portfolio_reject=(\d+)"
)
STOPPED = re.compile(r"deals=(\d+) DD=([\d.]+)% avg_slip=([\d.]+) avg_latency=([\d.]+)ms profit=([-\d.]+)")

CONTRACT = 100.0
POINT = 0.01


def read_text(path: str) -> str:
    raw = open(path, "rb").read()
    for enc in ("utf-16-le", "utf-16", "utf-8", "cp1252"):
        try:
            return raw.decode(enc, errors="strict")
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def build_trades(text: str) -> tuple[list[dict], list[str]]:
    events = []
    for m in DEAL.finditer(text):
        ts, did, side, vol, sym, price = m.groups()
        events.append(
            {
                "time": datetime.strptime(ts, "%Y.%m.%d %H:%M:%S"),
                "deal": int(did),
                "side": side,
                "volume": float(vol),
                "symbol": sym,
                "price": float(price),
            }
        )
    events.sort(key=lambda e: (e["time"], e["deal"]))

    open_long: deque = deque()
    open_short: deque = deque()
    trades = []
    for e in events:
        if e["side"] == "buy":
            if open_short:
                o = open_short.popleft()
                trades.append(_close(o, e, "short"))
            else:
                open_long.append(e)
        else:
            if open_long:
                o = open_long.popleft()
                trades.append(_close(o, e, "long"))
            else:
                open_short.append(e)
    return trades, [f"unclosed: {len(open_long)} long, {len(open_short)} short"]


def _close(o: dict, c: dict, direction: str) -> dict:
    sign = 1.0 if direction == "long" else -1.0
    pnl = (c["price"] - o["price"]) * sign * o["volume"] * CONTRACT
    return {
        "direction": direction,
        "open_time": o["time"].strftime("%Y-%m-%d %H:%M:%S"),
        "close_time": c["time"].strftime("%Y-%m-%d %H:%M:%S"),
        "open_price": o["price"],
        "close_price": c["price"],
        "volume": o["volume"],
        "profit": round(pnl, 2),
        "duration_min": round((c["time"] - o["time"]).total_seconds() / 60.0, 1),
    }


def metrics(trades: list[dict], text: str) -> dict:
    out: dict = {}
    profits = [t["profit"] for t in trades]
    wins = [p for p in profits if p > 0]
    losses = [p for p in profits if p <= 0]
    gross_profit = round(sum(wins), 2)
    gross_loss = round(sum(losses), 2)
    net = round(sum(profits), 2)

    out["total_trades"] = len(trades)
    out["total_deals"] = len(trades) * 2
    out["net_profit"] = net
    out["gross_profit"] = gross_profit
    out["gross_loss"] = gross_loss
    out["profit_factor"] = round(gross_profit / abs(gross_loss), 4) if gross_loss < 0 else None
    out["win_rate_pct"] = round(100.0 * len(wins) / len(trades), 2) if trades else None
    out["avg_win"] = round(sum(wins) / len(wins), 2) if wins else 0.0
    out["avg_loss"] = round(sum(losses) / len(losses), 2) if losses else 0.0
    out["expected_payoff"] = round(net / len(trades), 2) if trades else None
    out["avg_duration_min"] = round(sum(t["duration_min"] for t in trades) / len(trades), 1) if trades else None

    bal = 10.0
    peak = bal
    max_dd = 0.0
    curve = [{"trade": 0, "balance": round(bal, 2)}]
    for i, t in enumerate(trades, 1):
        bal = round(bal + t["profit"], 2)
        peak = max(peak, bal)
        if peak > 0:
            max_dd = max(max_dd, (peak - bal) / peak * 100.0)
        curve.append({"trade": i, "balance": bal})
    out["max_balance_dd_pct"] = round(max_dd, 2)
    out["balance_curve"] = curve

    streak_w = streak_l = best_w = best_l = 0
    for p in profits:
        if p > 0:
            streak_w += 1
            streak_l = 0
        else:
            streak_l += 1
            streak_w = 0
        best_w = max(best_w, streak_w)
        best_l = max(best_l, streak_l)
    out["max_consec_wins"] = best_w
    out["max_consec_losses"] = best_l

    out["spread_cost_total"] = round(26.0 * POINT * CONTRACT * 0.01 * len(trades), 2)
    out["commission_total"] = 0.0
    out["swap_total"] = 0.0

    req = {}
    for m in REQUEST.finditer(text):
        ts, side, vol, sym, sl, tp, bid, ask = m.groups()
        req[ts] = (side, float(bid), float(ask))
    slips = []
    for t in trades:
        key = t["open_time"]
        if key in req:
            side, bid, ask = req[key]
            want = bid if side == "sell" else ask
            slips.append(abs(t["open_price"] - want) / POINT)
    out["slippage_samples"] = len(slips)
    out["avg_slippage_pts"] = round(sum(slips) / len(slips), 2) if slips else 0.0
    out["max_slippage_pts"] = round(max(slips), 2) if slips else 0.0

    out["engines"] = {}
    for m in SUMMARY.finditer(text):
        eng, att, acc, so, lotr, portr = m.groups()
        out["engines"][eng] = {
            "attempts": int(att),
            "accepted": int(acc),
            "lot_reject": int(lotr),
            "portfolio_reject": int(portr),
        }
    fb = FINAL_BALANCE.search(text)
    out["tester_final_balance"] = float(fb.group(1)) if fb else None
    st = STOPPED.search(text)
    if st:
        out["ea_reported"] = {
            "deals": int(st.group(1)),
            "dd_pct": float(st.group(2)),
            "avg_slip": float(st.group(3)),
            "avg_latency_ms": float(st.group(4)),
            "profit": float(st.group(5)),
        }
    return out


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: parse_tester_log.py <journal.log> <out.json> [tag]")
        return 2
    text = read_text(argv[1])
    trades, notes = build_trades(text)
    m = metrics(trades, text)
    m["tag"] = argv[3] if len(argv) > 3 else ""
    m["source"] = argv[1]
    m["notes"] = notes
    m["trades"] = trades
    json.dump(m, open(argv[2], "w"), indent=1)
    print(f"{m['tag']}: trades={m['total_trades']} net={m['net_profit']} "
          f"PF={m['profit_factor']} DD={m['max_balance_dd_pct']}% "
          f"final={m['tester_final_balance']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
