# Backtest report - 30 days, XAUUSD, leverage 1:3000, deposit 10 USD

## Test environment (identical for every run)

| item | value |
| --- | --- |
| Symbol | XAUUSD.m (JustMarkets Standard) |
| Period / model | M1, Model 4 real ticks |
| Window | 2026.10.23 -> 2026.11.22 (30 days) |
| Ticks processed | 11,275,252 |
| Bars generated | 28,872 |
| Spread | 26 points, no commission |
| ATR(14) at end of run | 647 points |
| Leverage | 1:3000 |
| Deposit | 10.00 USD |

## Result 1 - XTRD_OMIGA_v2.24_CostAware

| metric | value |
| --- | --- |
| Trades | 0 |
| Net profit | 0.00 |
| Drawdown | 0.00% |
| Test duration | 53.8 s |

The expert initialised, ran the full month and closed with `deals=0`.
It refuses to trade because its own risk cap allows 1% of 10 USD = 0.10 USD
of risk, while the smallest possible position (0.01 lot with a 120 point stop)
already risks 1.20 USD. It also forces a single concurrent position below
100 USD equity.

## Result 2 - XTRD_OMIGA_Enabled_GoldSymbol (main EA)

| metric | value |
| --- | --- |
| Trades | 0 |
| Net profit | 0.00 |
| Drawdown | 0.00% |
| Stop loss used | 120 points |
| Take profit used | 234 points |
| Max affordable stop | 120 points |
| Margin utilisation | 0.00% |

### Rejection funnel (why no trade was opened)

| gate | rejections | note |
| --- | --- | --- |
| intensity | 17,668,366 | signal strength below the p30 quantile |
| displacement | 8,577,526 | move smaller than the micro-displacement floor |
| session | 3,513,669 | outside the allowed trading sessions |
| probability | 1,575,351 | confidence below the p30 quantile |
| persistence | 1,037,035 | direction not persistent enough |
| regime | 202,018 | regime filter blocked |
| edge | 24,393 | expected move did not clear the spread by 1.15x |
| cooldown | 23,975 | same strategy fired again inside 250 ms |
| spread | 3,731 | spread above the gate |
| **lot_zero** | **144** | **144 signals passed every gate and died here** |

The 144 `lot_zero` rejections are the whole story. Risk budget is
1% of 10.00 = 0.10 USD. The minimum lot 0.01 on gold moves 0.01 USD per point,
so a 120 point stop risks 1.20 USD - twelve times the budget. The lot rounds to
zero and the order is never sent.

## Cost arithmetic on a 10 USD account

| item | value | share of equity |
| --- | --- | --- |
| Spread per round trip (26 pts) | 0.26 USD | 2.6% |
| Stop loss at minimum lot (120 pts) | 1.20 USD | 12.0% |
| Take profit at minimum lot (234 pts) | 2.34 USD | 23.4% |
| Four consecutive stop-outs | 4.80 USD | 48.0% |

The spread alone costs 2.6% of the account on every single trade, and the
smallest position the broker allows risks 12%. There is no setting that makes
this smaller: 0.01 lot is the floor.

## Reference point - the same EA and month at 100 USD

| metric | value |
| --- | --- |
| Trades | 101 |
| Net profit | +2.41 USD |
| Profit factor | 1.03 |
| Wins / losses | 46 / 55 |
| Average win | 1.94 USD |
| Average loss | -1.58 USD |
| Max equity drawdown | 13.34 USD (13.34%) |

The position size in that run was also 0.01 lot, so the dollar figures carry
over to a 10 USD account unchanged. That is the decisive number: the same trade
sequence that earns +2.41 USD also draws down 13.34 USD, which is 133% of a
10 USD balance. The account is stopped out before the profit arrives.

## Conclusions that follow from the measurements

1. At 10 USD the engine cannot trade at all under its own risk rules, and if
   the rules are relaxed to allow it, one minimum lot is 12% of equity.
2. The spread is 21.7% of the stop distance (26 of 120 points). Every trade
   starts 0.22R behind, so a strategy needs a win rate above 47% at 1.95R just
   to break even.
3. At 100 USD the same logic produced 101 trades with a 1.03 profit factor -
   break-even, not profit. The drawdown of 13.34 USD is the binding constraint,
   not the profit.
4. The minimum balance at which this geometry is survivable is around
   150-200 USD: the 13.34 USD drawdown stays under 10% and the 1.20 USD
   position stays under 1% of equity.
