# MT5 Backtest Lab

Empty by design. Add one EA file at the repository root, then run the workflow.

## Run
```
gh workflow run backtest.yml --ref <branch> \
  -f ea=MyEA -f deposit=1000 -f days=30 -f tag=my_test
```

## Inputs
| input | meaning | default |
|---|---|---|
| ea | EA file name without .mq5 | required |
| deposit | starting balance | 10 |
| days | history length | 30 |
| tag | artifact label | manual |
| spread_pts | force fixed spread (blank = real ticks) | blank |
| extra_inputs | comma-separated `Name=Value` EA inputs | blank |

## Outputs
- `compile.log` — must show 0 errors
- `metrics.json` — parsed summary
- strategy tester HTML report
- EA summary/telemetry CSV from Common/Files
- terminal and tester logs
