# XTRDlaap

`XTRD_OMIGA_Enabled_GoldSymbol.mq5` — OMIGA gold microstructure engine, tuned for
**JustMarkets Standard XAUUSD** account (spread 25-35 points, no commission,
100 USD deposit, 1:1000 leverage).

The broker lists gold as **`XAUUSD.m`** (path `Metals M\XAUUSD.m`, live spread
26 points at the time of writing). The workflow auto-detects the name from the
terminal symbol tree, so a rename on the broker side does not break the pipeline;
`symbol` on `workflow_dispatch` overrides it.

- Diagnosis of the structural defects: [`docs/DIAGNOSIS.md`](docs/DIAGNOSIS.md)
- Per-iteration metrics: [`CHANGELOG.md`](CHANGELOG.md)

## Backtest pipeline

`.github/workflows/backtest.yml` runs on `windows-latest` (`push` + `workflow_dispatch`):

1. validates that `MT5_LOGIN`, `MT5_PASSWORD` and `MT5_SERVER` exist;
2. downloads and silently installs JustMarkets MT5, detects the data folder
   (`/portable` mode, so the data folder is the install folder);
3. copies the expert into `MQL5/Experts`, runs the static checks, then compiles with
   `metaeditor64.exe` — **any compile error fails the run**;
4. writes `tester.ini` (`XAUUSD`, `M1`, `Model=4` real ticks, `ExecutionMode=15`,
   `Deposit=100`, `Leverage=1000`, `ShutdownTerminal=1`);
5. runs `terminal64.exe /config:tester.ini` and uploads the HTML report,
   `*_X13_Omega_Telemetry.csv`, `*_X13_Omega_Ledger.csv`, the compile log and the
   tester logs as workflow artifacts, plus a parsed `metrics.json`.

### Required repository setup

| Requirement | Why |
| --- | --- |
| Secret `MT5_LOGIN` | tester login (demo account is fine) |
| Secret `MT5_PASSWORD` | tester password |
| Secret `MT5_SERVER` | broker server name, e.g. `JustMarkets-Demo` |
| Actions write permission for the token that pushes | to start runs |

The account must be a **hedging** account: the EA returns `INIT_FAILED` on a netting
account.

## Running one iteration

```bash
tools/run_iteration.sh iter1 45 4 15   # tag, days, model, execution delay ms
```

The script lints, pushes, dispatches, watches with `gh run watch`, downloads the
artifacts, analyses them and appends the metrics row to `CHANGELOG.md`. If the score
is below the best previous score the row is marked `REVERT`.

## Local tools

| Tool | Purpose |
| --- | --- |
| `tools/analyze_backtest.py` | parse the MT5 HTML report, telemetry and ledger; per-strategy and per-exit-reason P/L; write JSON + markdown |
| `tools/mql5_lint.py` | static checks (brace balance, undefined calls, argument counts, undeclared inputs/globals, struct fields) |
| `tools/geometry_model.py` | barrier/expectancy arithmetic for a given spread: break-even hit rate and the edge a signal must supply |
| `tools/run_iteration.sh` | one full push → run → download → analyse cycle |

`tools/mql5_lint.py` is a proxy, not a compiler. The CI job is the authoritative
compile check.
