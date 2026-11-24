# Before / After — v3.01 vs v3.02

Same EA logic, same inputs, same data, same tester settings. Only the bookkeeping layer differs.

## 1. Technical behaviour

| Property | v3.01 | v3.02 |
|---|---|---|
| Trade transactions processed | 0 (filter rejected every event) | 422 / 267 / 218 / 42 events logged |
| EA `deals` counter vs journal | 0 vs 6 — **wrong** | 60/38/31/6 vs 60/38/31/6 — **exact** |
| Request slots released | never | on history proof (`unresolved_released=0`) |
| Trading after the first entries | stopped after 5-6 trades, 28 days idle | continued through the period |
| Gate rejections | 1,933 / 1,036 / 1,538 / 4,105 (cause unknown) | 1,124 / 1,724 / 1,081 / 5,262 (all `MARGIN_INSUFFICIENT`, logged) |
| Reported drawdown | negative total return, mislabelled | true max balance and equity drawdown |

## 2. Results

| Test | Trades v3.01 → v3.02 | Net v3.01 → v3.02 | PF v3.01 → v3.02 | Max balance DD v3.02 |
|---|---|---|---|---|
| MICRO | 6 → **60** | -1.72 → **-9.73** | 0.61 → 0.75 | 97.90% |
| SHORT | 6 → **38** | +2.94 → **-9.02** | 1.92 → 0.73 | 94.33% |
| EXPANSION | 5 → **31** | -3.10 → **-10.19** | 0.60 → 0.73 | 101.67% |
| ALL | 6 → **6** | -2.26 → **-8.98** | 0.50 → 0.00 | 89.80% |

## 3. Interpretation

- v3.01 was not a measurement: it traded ~6 times then locked itself out. Its `+2.94` on SHORT came
  from six trades on one day.
- v3.02 shows the same engines over the full month. Every configuration loses the account.
- Profit factor rose slightly (0.50-0.61 → 0.73-0.75) while net result collapsed, because the system
  now takes 5-10× more trades at ~18% risk each on a 10 USD balance.
- TEST 4 (ALL) still shows only 6 trades, but for a different reason: six consecutive losses took
  equity from 10.00 to 1.02, after which every entry was rejected with `MARGIN_INSUFFICIENT`.

## 4. Conclusion

The repair succeeded technically — all eight acceptance criteria pass.
It did not make the strategy profitable, and it was not meant to.
Any further work on profitability is a strategy phase and requires separate approval.
