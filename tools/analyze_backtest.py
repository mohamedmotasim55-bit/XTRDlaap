#!/usr/bin/env python3
"""Analyze an MT5 Strategy Tester HTML report plus XTRD telemetry/ledger CSVs.

The script is dependency free (stdlib only) so it runs on any CI runner.

Usage:
    python3 tools/analyze_backtest.py --report artifacts/backtest_report.htm \
        --telemetry artifacts/*Telemetry*.csv --ledger artifacts/*Ledger*.csv \
        --iteration 3 --out reports/iter3.json [--append-changelog CHANGELOG.md]
"""

from __future__ import annotations

import argparse
import csv
import glob
import json
import os
import re
import sys
from html.parser import HTMLParser

# ---------------------------------------------------------------- HTML tables


class TableParser(HTMLParser):
    """Collects every table as a list of rows of cell texts."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.tables: list[list[list[str]]] = []
        self._stack: list[list[list[str]]] = []
        self._row: list[str] | None = None
        self._cell: list[str] | None = None

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag == "table":
            self._stack.append([])
        elif tag == "tr" and self._stack:
            self._row = []
        elif tag in ("td", "th") and self._row is not None:
            self._cell = []
        elif tag == "br" and self._cell is not None:
            self._cell.append(" ")

    def handle_endtag(self, tag: str) -> None:
        if tag in ("td", "th") and self._cell is not None and self._row is not None:
            self._row.append(" ".join("".join(self._cell).split()))
            self._cell = None
        elif tag == "tr" and self._row is not None and self._stack:
            if any(c for c in self._row):
                self._stack[-1].append(self._row)
            self._row = None
        elif tag == "table" and self._stack:
            self.tables.append(self._stack.pop())

    def handle_data(self, data: str) -> None:
        if self._cell is not None:
            self._cell.append(data)


def parse_tables(html: str) -> list[list[list[str]]]:
    p = TableParser()
    p.feed(html)
    return p.tables


# --------------------------------------------------------------- value helpers

NUM_RE = re.compile(r"[-+]?\d[\d\s,]*\.?\d*")


def to_float(text: str) -> float | None:
    if text is None:
        return None
    t = text.strip().replace("\u00a0", " ")
    if not t or t in {"-", "n/a"}:
        return None
    t = t.replace(" ", "").replace(",", "")
    m = NUM_RE.search(t)
    if not m:
        return None
    try:
        return float(m.group(0))
    except ValueError:
        return None


SUMMARY_LABELS = {
    "initial deposit": "initial_deposit",
    "total net profit": "net_profit",
    "gross profit": "gross_profit",
    "gross loss": "gross_loss",
    "profit factor": "profit_factor",
    "expected payoff": "expected_payoff",
    "recovery factor": "recovery_factor",
    "sharpe ratio": "sharpe_ratio",
    "total trades": "total_trades",
    "short trades (won %)": "short_trades",
    "long trades (won %)": "long_trades",
    "profit trades (% of total)": "profit_trades",
    "loss trades (% of total)": "loss_trades",
    "largest profit trade": "largest_profit_trade",
    "largest loss trade": "largest_loss_trade",
    "average profit trade": "avg_profit_trade",
    "average loss trade": "avg_loss_trade",
    "maximum consecutive wins ($)": "max_consec_wins_money",
    "maximum consecutive losses ($)": "max_consec_losses_money",
    "balance drawdown maximal": "balance_dd_max",
    "balance drawdown relative": "balance_dd_rel",
    "equity drawdown maximal": "equity_dd_max",
    "equity drawdown relative": "equity_dd_rel",
    "total commission": "total_commission",
    "total swap": "total_swap",
    "margin level": "margin_level",
}


def parse_summary(tables) -> dict:
    """Map MT5 summary labels to numeric values.

    MT5 renders the summary as label/value cell pairs, sometimes with two
    label/value pairs per row, so we scan every cell and look one cell ahead.
    """
    flat: list[str] = []
    for table in tables:
        for row in table:
            flat.extend(row)

    out: dict = {}
    for i, cell in enumerate(flat):
        key = cell.strip().rstrip(":").lower()
        if key in SUMMARY_LABELS and i + 1 < len(flat):
            field = SUMMARY_LABELS[key]
            raw = flat[i + 1]
            if field in out:
                continue
            if field in {"short_trades", "long_trades", "profit_trades", "loss_trades"}:
                # e.g. "1234 (72.10%)"
                m = re.match(r"\s*(\d+)\s*\(([-\d.]+)%\)", raw)
                if m:
                    out[field] = int(m.group(1))
                    out[field + "_win_pct"] = float(m.group(2))
                else:
                    v = to_float(raw)
                    if v is not None:
                        out[field] = int(v)
            elif field == "total_trades":
                v = to_float(raw)
                if v is not None:
                    out[field] = int(v)
            else:
                v = to_float(raw)
                if v is not None:
                    out[field] = v
    return out


STRATEGY_PATTERNS = [
    (re.compile(r"MICRO[_ ]?REV", re.I), "STRAT_MICRO_REVERSION"),
    (re.compile(r"MOMENTUM", re.I), "STRAT_MOMENTUM"),
    (re.compile(r"EXHAUST", re.I), "STRAT_EXHAUSTION"),
]


def strategy_from_text(text: str) -> str | None:
    if not text:
        return None
    for pattern, name in STRATEGY_PATTERNS:
        if pattern.search(text):
            return name
    return None


def find_deal_table(tables):
    """Locate the deals table: the one with a Profit column and a Comment column."""
    best = None
    for table in tables:
        if not table:
            continue
        header = [c.lower() for c in table[0]]
        if "profit" in header and ("comment" in header or "order" in header):
            if best is None or len(table) > len(best):
                best = table
    return best


def parse_deals(tables) -> list[dict]:
    table = find_deal_table(tables)
    if not table:
        return []
    header = [c.lower() for c in table[0]]

    def col(*names):
        for n in names:
            if n in header:
                return header.index(n)
        return None

    idx = {
        "time": col("time"),
        "deal": col("deal"),
        "symbol": col("symbol"),
        "type": col("type"),
        "direction": col("direction"),
        "volume": col("volume"),
        "price": col("price"),
        "profit": col("profit"),
        "comment": col("comment"),
    }
    deals = []
    for row in table[1:]:
        if len(row) < len(header):
            row = row + [""] * (len(header) - len(row))
        profit = to_float(row[idx["profit"]]) if idx["profit"] is not None else None
        if profit is None:
            continue
        comment = row[idx["comment"]] if idx["comment"] is not None else ""
        deals.append(
            {
                "time": row[idx["time"]] if idx["time"] is not None else "",
                "deal": row[idx["deal"]] if idx["deal"] is not None else "",
                "type": row[idx["type"]] if idx["type"] is not None else "",
                "direction": row[idx["direction"]] if idx["direction"] is not None else "",
                "volume": to_float(row[idx["volume"]]) if idx["volume"] is not None else None,
                "price": to_float(row[idx["price"]]) if idx["price"] is not None else None,
                "profit": profit,
                "comment": comment,
                "strategy": strategy_from_text(comment),
            }
        )
    return deals


def classify_exit(comment: str) -> str:
    c = (comment or "").strip().lower()
    if c.startswith("sl"):
        return "stop_loss"
    if c.startswith("tp"):
        return "take_profit"
    if "partial" in c:
        return "partial"
    if "stall" in c:
        return "stall"
    if "time" in c:
        return "time"
    if "close" in c or "rollover" in c:
        return "manual"
    return "other"


def summarize_deals(deals: list[dict]) -> dict:
    """Per-strategy and per-exit-reason attribution from the report deal list."""
    per_strategy: dict[str, dict] = {}
    per_exit: dict[str, dict] = {}
    for d in deals:
        strat = d["strategy"] or "UNATTRIBUTED"
        s = per_strategy.setdefault(strat, {"trades": 0, "net": 0.0, "wins": 0, "losses": 0})
        s["trades"] += 1
        s["net"] += d["profit"]
        if d["profit"] > 0:
            s["wins"] += 1
        elif d["profit"] < 0:
            s["losses"] += 1
        reason = classify_exit(d["comment"])
        e = per_exit.setdefault(reason, {"trades": 0, "net": 0.0})
        e["trades"] += 1
        e["net"] += d["profit"]

    for s in per_strategy.values():
        decided = s["wins"] + s["losses"]
        s["win_rate_pct"] = round(100.0 * s["wins"] / decided, 2) if decided else None
        s["net"] = round(s["net"], 2)
    for e in per_exit.values():
        e["net"] = round(e["net"], 2)
    return {"per_strategy": per_strategy, "per_exit_reason": per_exit}


# ------------------------------------------------------------------- CSV input


def load_csv(path: str) -> list[dict]:
    if not path or not os.path.exists(path):
        return []
    with open(path, newline="", encoding="utf-8", errors="replace") as fh:
        sample = fh.read(4096)
        fh.seek(0)
        try:
            dialect = csv.Sniffer().sniff(sample, delimiters=";,\t")
        except csv.Error:
            dialect = csv.excel
            dialect.delimiter = ";" if ";" in sample else ","
        return list(csv.DictReader(fh, dialect=dialect))


def summarize_telemetry(rows: list[dict]) -> dict:
    if not rows:
        return {}
    slips = [to_float(r.get("slippage_pts")) for r in rows]
    lat = [to_float(r.get("latency_ms")) for r in rows]
    slips = [s for s in slips if s is not None]
    lat = [v for v in lat if v is not None]
    events: dict[str, int] = {}
    for r in rows:
        ev = (r.get("event") or "?").strip()
        events[ev] = events.get(ev, 0) + 1
    out = {
        "rows": len(rows),
        "events": events,
        "avg_slippage_pts": round(sum(slips) / len(slips), 3) if slips else None,
        "max_slippage_pts": round(max(slips), 3) if slips else None,
        "avg_latency_ms": round(sum(lat) / len(lat), 1) if lat else None,
        "rejects": events.get("REQUEST_REJECT", 0),
    }
    spreads = [to_float(r.get("spread")) for r in rows]
    spreads = [s for s in spreads if s is not None and s > 0]
    if spreads:
        out["avg_spread_pts"] = round(sum(spreads) / len(spreads), 2)
        out["p95_spread_pts"] = round(sorted(spreads)[int(0.95 * (len(spreads) - 1))], 2)
    return out


def summarize_ledger(rows: list[dict]) -> dict:
    """Ledger rows are written by the EA: one row per closed trade."""
    if not rows:
        return {}
    per_strategy: dict[str, dict] = {}
    exits: dict[str, dict] = {}
    ages: list[float] = []
    spread_at_entry: list[float] = []
    for r in rows:
        strat = (r.get("strategy") or "UNKNOWN").strip()
        profit = to_float(r.get("profit")) or 0.0
        s = per_strategy.setdefault(
            strat, {"trades": 0, "net": 0.0, "wins": 0, "losses": 0, "gross_win": 0.0, "gross_loss": 0.0}
        )
        s["trades"] += 1
        s["net"] += profit
        if profit > 0:
            s["wins"] += 1
            s["gross_win"] += profit
        elif profit < 0:
            s["losses"] += 1
            s["gross_loss"] += abs(profit)
        reason = classify_exit((r.get("exit_reason") or "").strip())
        e = exits.setdefault(reason, {"trades": 0, "net": 0.0})
        e["trades"] += 1
        e["net"] += profit
        age = to_float(r.get("age_sec"))
        if age is not None:
            ages.append(age)
        sp = to_float(r.get("spread_at_entry_pts"))
        if sp is not None:
            spread_at_entry.append(sp)

    for s in per_strategy.values():
        s["net"] = round(s["net"], 2)
        decided = s["wins"] + s["losses"]
        s["win_rate_pct"] = round(100.0 * s["wins"] / decided, 2) if decided else None
        s["profit_factor"] = round(s["gross_win"] / s["gross_loss"], 3) if s["gross_loss"] > 0 else None
        s["gross_win"] = round(s["gross_win"], 2)
        s["gross_loss"] = round(s["gross_loss"], 2)
    for e in exits.values():
        e["net"] = round(e["net"], 2)
    out = {"per_strategy": per_strategy, "per_exit_reason": exits}
    if ages:
        out["avg_age_sec"] = round(sum(ages) / len(ages), 1)
    if spread_at_entry:
        out["avg_spread_at_entry_pts"] = round(sum(spread_at_entry) / len(spread_at_entry), 2)
    return out


# ---------------------------------------------------------------- diagnostics


def diagnose(metrics: dict) -> list[str]:
    """Translate metrics into concrete structural findings."""
    findings: list[str] = []
    net = metrics.get("net_profit")
    pf = metrics.get("profit_factor")
    trades = metrics.get("total_trades")
    dd = metrics.get("equity_dd_rel") or metrics.get("balance_dd_rel")

    if net is not None and net <= 0:
        findings.append(f"Net profit is negative ({net:.2f} USD).")
    if pf is not None and pf < 1.0:
        findings.append(f"Profit factor {pf:.2f} < 1.0: gross win does not cover gross loss.")
    if trades is not None and trades < 30:
        findings.append(f"Only {trades} trades: sample too small to trust the result.")
    if dd is not None and dd > 15.0:
        findings.append(f"Relative drawdown {dd:.2f}% is above the 15% risk budget.")
    if metrics.get("avg_spread_at_entry_pts") and metrics.get("avg_tp_pts"):
        if metrics["avg_tp_pts"] < 4 * metrics["avg_spread_at_entry_pts"]:
            findings.append(
                "Average TP is less than 4x the entry spread: the strategy pays the spread "
                "far too often relative to its target."
            )

    ledger = metrics.get("ledger", {}).get("per_strategy", {})
    for name, s in ledger.items():
        if s["trades"] >= 10 and s["net"] < 0:
            findings.append(f"Strategy {name} loses {s['net']:.2f} USD over {s['trades']} trades.")

    exits = metrics.get("ledger", {}).get("per_exit_reason", {})
    sl = exits.get("stop_loss", {})
    if sl.get("trades") and trades:
        share = 100.0 * sl["trades"] / max(1, trades)
        if share > 55.0:
            findings.append(
                f"{share:.1f}% of trades exit on stop loss: stop distance is inside normal noise/spread."
            )
    return findings


# --------------------------------------------------------------------- driver


def glob_first(patterns: list[str]) -> str | None:
    for pattern in patterns:
        hits = sorted(glob.glob(pattern))
        if hits:
            return hits[0]
    return None


def score(m: dict) -> float:
    """Ranking score used to decide whether an iteration is kept or reverted."""
    net = m.get("net_profit")
    if net is None:
        return float("-inf")
    pf = m.get("profit_factor") or 0.0
    dd = m.get("equity_dd_rel") or 0.0
    trades = m.get("total_trades") or 0
    if trades < 20:
        return float("-inf")
    # Reward net profit and profit factor, penalise relative drawdown.
    return net * min(pf, 3.0) - 0.5 * dd


CHANGELOG_START = "<!-- METRICS:START -->"
CHANGELOG_END = "<!-- METRICS:END -->"


def append_changelog(path: str, m: dict, best: float | None) -> str:
    """Insert one metrics row into the CHANGELOG table between the markers."""
    if not os.path.exists(path):
        return "changelog missing"
    text = open(path, encoding="utf-8").read()
    if CHANGELOG_START not in text or CHANGELOG_END not in text:
        return "changelog markers missing"

    s = score(m)
    verdict = "kept"
    if best is not None and s < best:
        verdict = "REVERT"
    row = (
        f"| {m.get('iteration')} | {fmt(m.get('net_profit'))} | {fmt(m.get('profit_factor'))} | "
        f"{fmt(m.get('total_trades'))} | {fmt(m.get('equity_dd_rel'))} | "
        f"{fmt(m.get('recovery_factor'))} | {s:.2f} | {verdict} |"
    )
    head, rest = text.split(CHANGELOG_START, 1)
    body, tail = rest.split(CHANGELOG_END, 1)
    body = body.rstrip("\n") + "\n" + row + "\n"
    open(path, "w", encoding="utf-8").write(head + CHANGELOG_START + body + CHANGELOG_END + tail)
    return verdict


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", default=None, help="MT5 HTML report")
    ap.add_argument("--telemetry", nargs="*", default=[], help="telemetry CSV globs")
    ap.add_argument("--ledger", nargs="*", default=[], help="trade ledger CSV globs")
    ap.add_argument("--iteration", default="0")
    ap.add_argument("--out", default=None)
    ap.add_argument("--append-changelog", default=None)
    ap.add_argument("--best-score", type=float, default=None)
    ap.add_argument("--json", action="store_true", help="print JSON to stdout")
    args = ap.parse_args(argv)

    metrics: dict = {"iteration": args.iteration}

    report = args.report or glob_first(["artifacts/backtest_report.htm", "artifacts/*.htm", "artifacts/*.html"])
    if report and os.path.exists(report):
        html = open(report, encoding="utf-8", errors="replace").read()
        tables = parse_tables(html)
        metrics["summary"] = parse_summary(tables)
        deals = parse_deals(tables)
        metrics["deals"] = len(deals)
        metrics["report_attribution"] = summarize_deals(deals)
        metrics.update(metrics["summary"])
        if deals:
            metrics["avg_profit_per_deal"] = round(
                sum(d["profit"] for d in deals) / len(deals), 3
            )
    else:
        metrics["summary"] = {}
        metrics["error"] = "report not found"

    telemetry_path = glob_first(args.telemetry or ["artifacts/*Telemetry*.csv", "artifacts/*telemetry*.csv"])
    metrics["telemetry"] = summarize_telemetry(load_csv(telemetry_path)) if telemetry_path else {}

    ledger_path = glob_first(args.ledger or ["artifacts/*Ledger*.csv", "artifacts/*ledger*.csv"])
    metrics["ledger"] = summarize_ledger(load_csv(ledger_path)) if ledger_path else {}
    metrics["sources"] = {"report": report, "telemetry": telemetry_path, "ledger": ledger_path}

    metrics["findings"] = diagnose(metrics)

    if args.out:
        os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump(metrics, fh, indent=2, ensure_ascii=False)
            fh.write("\n")

    metrics["score"] = score(metrics)
    if args.append_changelog:
        verdict = append_changelog(args.append_changelog, metrics, args.best_score)
        print(f"changelog verdict: {verdict} (score {metrics['score']:.2f})")

    if args.json:
        print(json.dumps(metrics, indent=2, ensure_ascii=False))
    else:
        print(render_markdown(metrics))
    return 0


def fmt(value, digits: int = 2) -> str:
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def render_markdown(m: dict) -> str:
    lines = [f"## Backtest metrics (iteration {m.get('iteration')})", ""]
    summary_fields = [
        ("net_profit", "Net profit (USD)"),
        ("profit_factor", "Profit factor"),
        ("expected_payoff", "Expected payoff"),
        ("total_trades", "Total trades"),
        ("equity_dd_rel", "Equity DD %"),
        ("balance_dd_rel", "Balance DD %"),
        ("recovery_factor", "Recovery factor"),
        ("sharpe_ratio", "Sharpe"),
        ("profit_trades", "Winning trades"),
        ("loss_trades", "Losing trades"),
    ]
    lines.append("| Metric | Value |")
    lines.append("| --- | --- |")
    for key, label in summary_fields:
        lines.append(f"| {label} | {fmt(m.get(key))} |")
    lines.append("")

    ledger = m.get("ledger", {})
    if ledger.get("per_strategy"):
        lines.append("### Per-strategy P/L (trade ledger)")
        lines.append("")
        lines.append("| Strategy | Trades | Win % | Net USD | PF |")
        lines.append("| --- | --- | --- | --- | --- |")
        for name, s in sorted(ledger["per_strategy"].items()):
            lines.append(
                f"| {name} | {s['trades']} | {fmt(s.get('win_rate_pct'))} | "
                f"{fmt(s['net'])} | {fmt(s.get('profit_factor'), 3)} |"
            )
        lines.append("")
    if ledger.get("per_exit_reason"):
        lines.append("### Exit reason breakdown")
        lines.append("")
        lines.append("| Exit | Trades | Net USD |")
        lines.append("| --- | --- | --- |")
        for name, e in sorted(ledger["per_exit_reason"].items()):
            lines.append(f"| {name} | {e['trades']} | {fmt(e['net'])} |")
        lines.append("")

    tele = m.get("telemetry", {})
    if tele:
        lines.append("### Execution quality")
        lines.append("")
        lines.append(
            f"- avg spread {fmt(tele.get('avg_spread_pts'))} pts, "
            f"p95 {fmt(tele.get('p95_spread_pts'))} pts"
        )
        lines.append(
            f"- avg slippage {fmt(tele.get('avg_slippage_pts'), 3)} pts, "
            f"max {fmt(tele.get('max_slippage_pts'), 3)} pts, "
            f"avg latency {fmt(tele.get('avg_latency_ms'), 1)} ms"
        )
        lines.append(f"- rejected requests: {tele.get('rejects')}")
        lines.append("")

    if m.get("findings"):
        lines.append("### Structural findings")
        lines.append("")
        for f in m["findings"]:
            lines.append(f"- {f}")
        lines.append("")
    return "\n".join(lines)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
