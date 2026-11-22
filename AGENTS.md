# Agent notes — XTRDlaap

## What this repo is
One MQL5 expert advisor (`XTRD_OMIGA_Enabled_GoldSymbol.mq5`) plus the CI/tooling to
stress-test it on JustMarkets Standard XAUUSD (spread 25-35 pts, no commission,
100 USD deposit, 1:1000 leverage).

## Hard constraints discovered
- **MetaEditor cannot run under wine here.** `MetaEditor64.exe` is protected and
  aborts with "A debugger has been found running in your system". `terminal64.exe`
  installs fine under wine, but there is no offline compiler. So local compilation
  is impossible; `tools/mql5_lint.py` is the local proxy, CI is authoritative.
- **The GitHub credential in this environment has no `contents` write permission**
  (`403 Resource not accessible by integration` on push and on the contents API),
  so workflow files cannot be pushed and runs cannot be dispatched.
- **No MT5 credentials** (`MT5_LOGIN`, `MT5_PASSWORD`, `MT5_SERVER`); without a login
  the tester cannot download XAUUSD tick history, so no backtest can run anywhere.
- A backtest also needs a **hedging** account: `OnInit` returns `INIT_FAILED` on
  netting (`InpRequireHedgingAccount = true`).

## Conventions
- Unit system: 2-digit gold, `point = 0.01`, 1 point on 0.01 lot = 0.01 USD.
  A 30-point spread costs 0.30 USD per 0.01 lot per round trip.
- All trade geometry must be expressed in **multiples of the live spread**, never in
  absolute points tuned for a low-spread ECN account. See `docs/DIAGNOSIS.md`.
- Any change that touches `BuildSignal`/`ManagePositions` must keep the break-even
  and trailing locks above `1 * spread`, otherwise the trade cannot close green.
- Run `python3 tools/mql5_lint.py XTRD_OMIGA_Enabled_GoldSymbol.mq5` before every
  commit; it catches undefined calls, wrong argument counts and undeclared
  `Inp*`/`g_*` identifiers.

## Loop
`tools/run_iteration.sh <tag> [days] [model] [exec_ms]` → lint, push, dispatch,
`gh run watch`, download artifacts, `tools/analyze_backtest.py`, append the row to
`CHANGELOG.md`. Revert when the new score is below the best previous score.
