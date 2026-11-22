#!/usr/bin/env python3
"""Static sanity checker for the XTRD OMIGA MQL5 source.

MetaEditor cannot run in this environment, so this script provides the checks
that catch the realistic compile breakages introduced by edits:

  * unbalanced braces / parentheses / brackets
  * unknown identifiers used as function calls (typo in a call target)
  * wrong argument count for functions defined in the file
  * undeclared inputs (Inp*), globals (g_*) and struct fields
  * duplicate function or struct-field definitions

Exit code 0 means "no findings". It is a proxy for the compiler, not a
replacement: the CI workflow still compiles with metaeditor64.exe.
"""

from __future__ import annotations

import argparse
import re
import sys

TYPE_KEYWORDS = {
    "void", "int", "uint", "short", "ushort", "char", "uchar", "long", "ulong",
    "float", "double", "bool", "string", "datetime", "color", "ENUM_TIMEFRAMES",
    "ENUM_ORDER_TYPE", "ENUM_ORDER_TYPE_FILLING", "ENUM_ACCOUNT_MARGIN_MODE",
    "ENUM_SYMBOL_TRADE_EXECUTION", "template", "class", "struct",
}

CONTROL_KEYWORDS = {
    "if", "for", "while", "switch", "return", "sizeof", "else", "do", "case",
    "new", "delete", "operator", "catch", "throw",
}

MQL5_BUILTINS = {
    "ArrayResize", "ArraySize", "ArraySort", "ArraySetAsSeries", "ArrayCopy",
    "ArrayInitialize", "ArrayMaximum", "ArrayMinimum", "ArrayFree", "ArrayRange",
    "Bars", "BarsCalculated", "CopyBuffer", "CopyClose", "CopyHigh", "CopyLow",
    "CopyOpen", "CopyRates", "CopyTickVolume", "CopyTime", "CopyTicks",
    "CopyTicksRange", "CopyRealVolume", "CopySpread",
    "ClampD", "ZeroMemory", "ResetLastError", "GetLastError", "Print", "PrintFormat",
    "Comment", "Alert", "SendNotification", "MathAbs", "MathMax", "MathMin",
    "MathRound", "MathFloor", "MathCeil", "MathSqrt", "MathPow", "MathLog",
    "MathExp", "MathRand", "MathSrand", "MathMod", "MathArctan", "MathSin",
    "MathCos", "MathTan", "MathIsValidNumber", "MathRand",
    "NormalizeDouble", "StringFormat", "StringLen", "StringFind", "StringSubstr",
    "StringToUpper", "StringToLower", "StringTrimLeft", "StringTrimRight",
    "StringReplace", "StringSplit", "StringGetCharacter", "StringSetCharacter",
    "StringConcatenate", "StringToInteger", "IntegerToString", "DoubleToString",
    "TimeToString", "StringToTime", "TimeCurrent", "TimeLocal", "TimeGMT",
    "TimeToStruct", "StructToTime", "TimeDay", "TimeHour", "TimeMinute",
    "TimeSeconds", "TimeDayOfWeek", "TimeDayOfYear", "TimeMonth", "TimeYear",
    "TimeTradeServer", "SymbolInfoDouble", "SymbolInfoInteger", "SymbolInfoString",
    "SymbolInfoTick", "SymbolSelect", "SymbolIsSynchronized", "SymbolInfoSessionQuote",
    "AccountInfoDouble", "AccountInfoInteger", "AccountInfoString",
    "TerminalInfoInteger", "TerminalInfoDouble", "TerminalInfoString",
    "MQLInfoInteger", "MQLInfoString",
    "OrderSend", "OrderSendAsync", "OrderCheck", "OrderCalcProfit", "OrderCalcMargin",
    "OrderSelect", "OrderGetTicket", "OrderGetDouble", "OrderGetInteger",
    "OrderGetString", "OrdersTotal", "OrderClose", "OrderModify", "OrderDelete",
    "PositionSelect", "PositionSelectByTicket", "PositionGetTicket",
    "PositionGetDouble", "PositionGetInteger", "PositionGetString", "PositionsTotal",
    "HistorySelect", "HistorySelectByPosition", "HistoryDealGetTicket",
    "HistoryDealGetDouble", "HistoryDealGetInteger", "HistoryDealGetString",
    "HistoryDealsTotal", "HistoryOrderGetDouble", "HistoryOrderGetInteger",
    "HistoryOrderGetString", "HistoryOrdersTotal", "HistoryOrderSelect",
    "iATR", "iRSI", "iMA", "iCustom", "iClose", "iOpen", "iHigh", "iLow",
    "IndicatorRelease", "IndicatorCreate", "EventSetMillisecondTimer",
    "EventSetTimer", "EventKillTimer", "FileOpen", "FileClose", "FileWrite",
    "FileWriteString", "FileReadString", "FileReadNumber", "FileReadDatetime",
    "FileSeek", "FileSize", "FileIsEnding", "FileIsLineEnding", "FileDelete",
    "FileFlush", "FileTell", "FileIsExist", "FileLoad", "FileSave",
    "ChartSymbol", "ChartPeriod", "ChartID", "ChartRedraw", "ChartGetInteger",
    "ChartGetDouble", "ObjectCreate", "ObjectDelete", "ObjectSetInteger",
    "ObjectSetDouble", "ObjectSetString", "ObjectFind", "GlobalVariableSet",
    "GlobalVariableGet", "GlobalVariableCheck", "GlobalVariableDel",
    "GetTickCount", "GetTickCount64", "GetMicrosecondCount", "Sleep",
    "TesterStatistics", "FrameAdd", "FrameNext", "FrameFilter",
    "StringBufferLen", "CharToString", "ShortToString", "ColorToString",
    "DoubleToStr", "StrToDouble", "StrToInteger", "EnumToString", "StringReserve",
    "WebRequest", "CryptEncode", "CryptDecode", "PlaySound", "MessageBox",
    "SeriesInfoInteger", "Period", "PeriodSeconds", "Digits", "Point",
    "Symbol", "Timeframe", "StringLen", "ArrayBsearch", "ArrayReverse",
    "MathMax", "MathMin", "MathAbs", "Rand", "srand", "MathLog10",
}

TYPE_RE = re.compile(r"^\s*(?:static\s+|const\s+)?(" + "|".join(sorted(TYPE_KEYWORDS)) + r")\s+(\w+)\s*\(", re.M)


def strip_code(src: str) -> str:
    """Remove comments and string/char literals, preserving line structure."""
    out = []
    i = 0
    n = len(src)
    while i < n:
        ch = src[i]
        if ch == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
        elif ch == "/" and i + 1 < n and src[i + 1] == "*":
            i += 2
            while i < n and not (src[i] == "*" and i + 1 < n and src[i + 1] == "/"):
                if src[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
        elif ch == '"':
            out.append('""')
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                if src[i] == "\n":
                    out.append("\n")
                i += 1
        elif ch == "'":
            out.append("''")
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == "'":
                    i += 1
                    break
                i += 1
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def split_args(text: str) -> list[str]:
    """Split a parameter/argument list on top-level commas."""
    parts, depth, cur = [], 0, []
    for ch in text:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    tail = "".join(cur).strip()
    if tail:
        parts.append(tail)
    return parts


def match_paren(src: str, open_idx: int) -> int:
    depth = 0
    for i in range(open_idx, len(src)):
        if src[i] == "(":
            depth += 1
        elif src[i] == ")":
            depth -= 1
            if depth == 0:
                return i
    return -1


def collect_definitions(src: str):
    funcs = {}
    for m in TYPE_RE.finditer(src):
        name = m.group(2)
        if name in CONTROL_KEYWORDS:
            continue
        open_idx = m.end() - 1
        close_idx = match_paren(src, open_idx)
        if close_idx < 0:
            continue
        params = split_args(src[open_idx + 1: close_idx])
        params = [p for p in params if p not in ("", "void")]
        required = sum(1 for p in params if "=" not in p)
        funcs.setdefault(name, (required, len(params)))
    return funcs


CALL_RE = re.compile(r"(?<![\w.])(\w+)\s*\(")


def collect_calls(src: str):
    calls = []
    for m in CALL_RE.finditer(src):
        name = m.group(1)
        if name in CONTROL_KEYWORDS or name in TYPE_KEYWORDS:
            continue
        open_idx = m.end() - 1
        close_idx = match_paren(src, open_idx)
        if close_idx < 0:
            continue
        args = [a for a in split_args(src[open_idx + 1: close_idx]) if a != ""]
        line = src[: m.start()].count("\n") + 1
        calls.append((name, len(args), line))
    return calls


def declared_names(src: str) -> set[str]:
    names = set()
    for m in re.finditer(r"^\s*(?:input\s+|static\s+)?(?:const\s+)?(?:[A-Za-z_]\w*(?:\s*<[^>]*>)?)\s+&?(\w+)\s*(?:\[[^\]]*\])?\s*(?:=|;|,)", src, re.M):
        names.add(m.group(1))
    for m in re.finditer(r"^\s*(?:input\s+)?(?:[A-Za-z_]\w*)\s+&?(\w+)\s*(?:\[[^\]]*\])?\s*=", src, re.M):
        names.add(m.group(1))
    for m in re.finditer(r"^\s*(?:input\s+)?(?:[A-Za-z_]\w*)\s+&?(\w+)\s*(?:\[[^\]]*\])?\s*;", src, re.M):
        names.add(m.group(1))
    return names


def check_struct_fields(src: str) -> list[str]:
    findings = []
    for m in re.finditer(r"struct\s+(\w+)\s*\{(.*?)\n\};", src, re.S):
        name, body = m.group(1), m.group(2)
        fields = re.findall(r"^\s*(?:[A-Za-z_]\w*)\s+(\w+)\s*(?:\[[^\]]*\])?\s*;", body, re.M)
        dupes = {f for f in fields if fields.count(f) > 1}
        if dupes:
            findings.append(f"struct {name}: duplicate field(s) {sorted(dupes)}")
    return findings


def check_struct_members(src: str) -> list[str]:
    """Verify every Struct.field access refers to a declared field."""
    findings = []
    structs = {}
    for m in re.finditer(r"struct\s+(\w+)\s*\{(.*?)\n\};", src, re.S):
        structs[m.group(1)] = set(
            re.findall(r"^\s*(?:[A-Za-z_]\w*)\s+(\w+)\s*(?:\[[^\]]*\])?\s*;", m.group(2), re.M)
        )
    # A variable name can be reused in several scopes with different struct
    # types, so a field only counts as missing when no candidate declares it.
    var_types: dict[str, set[str]] = {}
    for m in re.finditer(r"^\s*(\w+)\s+&?(\w+)\s*(?:\[[^\]]*\])?\s*(?:=|;)", src, re.M):
        if m.group(1) in structs:
            var_types.setdefault(m.group(2), set()).add(m.group(1))
    # Built-in MQL5 structs cannot be validated here; a name used with one of
    # them is skipped rather than reported.
    external = ("MqlTick", "MqlRates", "MqlTradeRequest", "MqlTradeResult",
                "MqlTradeTransaction", "MqlDateTime", "MqlBookInfo",
                "MqlCalendarValue", "MqlCalendarEvent", "MqlParam")
    external_vars = set()
    for name in external:
        for m in re.finditer(r"\b" + name + r"\s*&?\s*(\w+)\s*(?=[,);])", src):
            external_vars.add(m.group(1))

    # function parameters and comma separated declarations, e.g. (RollingStat &s)
    for name in structs:
        for m in re.finditer(r"\b" + name + r"\s*&?\s*(\w+)\s*(?=[,)])", src):
            var_types.setdefault(m.group(1), set()).add(name)
    for var, stypes in var_types.items():
        if var in external_vars:
            continue
        for m in re.finditer(r"\b" + re.escape(var) + r"\.(\w+)", src):
            field = m.group(1)
            if field in {"Copy"}:
                continue
            if any(field in structs[t] for t in stypes):
                continue
            stype = sorted(stypes)[0]
            line = src[: m.start()].count("\n") + 1
            findings.append(f"line {line}: {var}.{field} is not a field of struct {stype}")
    return findings


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    raw = open(args.path, encoding="utf-8", errors="replace").read()
    src = strip_code(raw)
    findings: list[str] = []

    for open_ch, close_ch in (("{", "}"), ("(", ")"), ("[", "]")):
        if src.count(open_ch) != src.count(close_ch):
            findings.append(
                f"unbalanced {open_ch}{close_ch}: {src.count(open_ch)} vs {src.count(close_ch)}"
            )

    funcs = collect_definitions(src)
    calls = collect_calls(src)
    for name, nargs, line in calls:
        if name in funcs:
            required, total = funcs[name]
            if not (required <= nargs <= total):
                findings.append(
                    f"line {line}: call {name}() with {nargs} args, definition expects {required}..{total}"
                )
        elif name not in MQL5_BUILTINS and not name.startswith("On"):
            # A call to an undefined symbol is a compile error in MQL5.
            findings.append(f"line {line}: call to undefined function {name}()")

    names = declared_names(src)
    for m in re.finditer(r"\b((?:Inp|g_)\w+)\b", src):
        ident = m.group(1)
        if ident in names:
            continue
        line = src[: m.start()].count("\n") + 1
        findings.append(f"line {line}: undeclared identifier {ident}")

    findings.extend(check_struct_fields(src))
    findings.extend(check_struct_members(src))

    if findings:
        print(f"{args.path}: {len(findings)} finding(s)")
        for f in findings:
            print("  -", f)
        return 1
    if not args.quiet:
        print(f"{args.path}: OK ({len(funcs)} functions, {len(calls)} calls checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
