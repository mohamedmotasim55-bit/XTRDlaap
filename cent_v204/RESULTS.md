# CENT ENGINE V2.0.4 — month results (XAUUSD, real ticks, 1:3000)

Runs: 45666450254 (as shipped), 45666824573 (compression cap 120).
Period 2026.10.24 -> 2026.11.23, 27,494 M1 bars, **10,755,156 ticks**, spread 26 points.
Compile: `0 errors, 0 warnings` (both runs).

## Why the file did not compile

`XTRD_OMIGA_CENT_ENGINE_V2_0_4_H2_CENT_TEST.mq5` as delivered failed with **29 errors**.
The `LogMsg(...)` call in `OnInit` ended one `)` short, so the parser swallowed
`OnTick`. One character fixed the whole file. No logic was touched.

## Account size question

The tester account is **USD** and the symbol contract is 100 oz per lot, min lot 0.01.
"1000 cents" is therefore run as `Deposit = 1000`:

* on a cent contract (1 oz/lot) with 1000 cents, the risk sizing produces the same
  lot size and the same percentage result as 1000 USD on a 100 oz lot;
* the **percentages below transfer directly to a 1000-cent account**.

They would NOT transfer if the cent account keeps a 100 oz contract: 0.25% of 1000 cents
is 2.5 cents while 0.01 lot at a 60-point stop risks 60 cents, so every signal would be
rejected with "minimum lot exceeds risk budget". Check `minLot` in the EA `INIT` log line.

## Month results

| | as shipped (box <= 60) | box <= 120 |
|---|---:|---:|
| Trades | 240 | 551 |
| Net profit | **-119.89 (-11.99%)** | **-292.66 (-29.27%)** |
| Gross profit / loss | 135.35 / -255.24 | 256.59 / -549.25 |
| Profit factor | **0.53** | 0.47 |
| Expected payoff | -0.50 / trade | -0.53 / trade |
| Win rate | 46.25% (111/240) | 45.01% (248/551) |
| Average win | 1.22 | 1.03 |
| Average loss | -1.98 | -1.81 |
| Largest win / loss | 4.35 / -2.60 | 4.35 / -3.12 |
| Payoff ratio (avg win / avg loss) | 0.62 | 0.57 |
| Break-even win rate required | **61.9%** | **63.7%** |
| Max balance drawdown | 128.93 (12.85%) | 300.23 (29.92%) |
| Max equity drawdown | 129.95 (12.95%) | 300.78 (29.97%) |
| Longest loss streak | 6 (-12.18) | 10 (-21.54) |
| Longest win streak | 5 (6.09) | 8 (6.77) |
| Sharpe | -5.00 | -5.00 |
| LR correlation | -0.99 | -1.00 |
| Long / short win rate | 46.77% / 45.69% | 47.81% / 42.24% |

## Diagnostics from the as-shipped run

| Event | Count |
|---|---:|
| `REJECT wave lock active` | 1,150,477 |
| `REJECT box range too wide` | 431,733 |
| `REJECT no confirmed breakout` | 11,269 |
| `REJECT our position already open` | 6,234 |
| `REJECT edge stop outside allowed range` | 473 |
| `SIGNAL` | 296 |
| `ORDER_ACCEPTED` | 240 |
| `ORDER_FAILED market closed` | 56 |
| `EXIT_HARVEST` | 49 |
| `TRAIL_UPDATE` | 798 |

## Measured 57-second box range (whole month, 33,056 samples)

| percentile | p1 | p2 | p5 | p10 | p25 | p50 |
|---|---:|---:|---:|---:|---:|---:|
| range (pts) | 74 | 85 | 102 | 122 | 170 | 245 |

The shipped cap of 60 points sits **below the 1st percentile**: on a typical day only
about 6 one-second windows satisfy it (verified second by second on 2026-11-20:
6 of 82,619). The month still produced 240 trades only because the cap is met
occasionally across 22 trading days.

## The arithmetic that produces the loss

* Average winner = 34.9 points, i.e. exactly the `InpHarvestProfitPoints = 35` cap.
* Average loser = -56.6 points, i.e. close to the 60-70 point structural stop.
* Realised payoff 0.62 against a 46.25% win rate.
* Break-even needs 61.9%. The gap is 15.7 points of win rate.
* Expected value = 0.4625 x 1.22 - 0.5375 x 1.98 = **-0.50 per trade**.

Widening the compression cap from 60 to 120 multiplies the trade count by 2.3 and the
loss by 2.4: the negative edge is per trade, not a matter of opportunity count.
