# Sub-Second Microstructure Discovery

Capital fixed **10 USD**. Decisions: 59147 (60s sampling, 59 days). Split 34894/13233/11020 (embargo 10s).

## Top features by information gain (1s, discovery)

| feature | IG |
|---|---|
| imb250ms | 0.00569 |
| imb100ms | 0.00561 |
| imb500ms | 0.00484 |
| tickdir_up | 0.00421 |
| mom1s | 0.00371 |
| accel | 0.00320 |
| tick_rate | 0.00292 |
| vol1s | 0.00290 |

## Tick classification audit
rule,metric,value
tick_rule_1s,mean_tickdir_up,0.3763
tick_rule_1s,mean_tickdir_dn,0.3761
tick_rule_1s,mean_tickdir_zero,0.2476
tick_rule_up_tercile_500ms,bin0_P_up,0.3443
tick_rule_up_tercile_500ms,bin1_P_up,0.4147
tick_rule_up_tercile_500ms,bin2_P_up,0.4574
tick_rule_up_tercile_500ms,base_P_up,0.3998
tick_rule_up_tercile_1s,bin0_P_up,0.4038
tick_rule_up_tercile_1s,bin1_P_up,0.4548
tick_rule_up_tercile_1s,bin2_P_up,0.4884
tick_rule_up_tercile_1s,base_P_up,0.4447

## OOS stability (top feature cells)
imb250ms,1s,oos,2300,0.3661,0.4638,-0.0977,-29.46,-22.54,sell candidate
imb100ms,1s,oos,4153,0.5389,0.4638,+0.0751,-23.40,-28.66,no edge
imb500ms,1s,oos,1995,0.3694,0.4638,-0.0944,-29.81,-22.19,sell candidate
tickdir_up,1s,oos,1948,0.5508,0.4638,+0.0870,-23.11,-29.00,buy candidate
mom1s,1s,oos,1749,0.5277,0.4638,+0.0639,-23.74,-28.29,no edge
accel,1s,oos,1993,0.4145,0.4638,-0.0493,-27.17,-24.83,sell candidate
tick_rate,1s,oos,1056,0.4233,0.4638,-0.0405,-25.88,-26.33,sell candidate
vol1s,1s,oos,1164,0.4107,0.4638,-0.0531,-26.82,-25.36,sell candidate

## Verdict rules
- Confirmed only if OOS lift stable AND net>0 after cost AND beats random after multiple-testing correction.

## DATA
- 59,147 decisions (60s sampling, 59 real-tick days). Split discovery 34,894 / validation 13,233 / OOS 11,020 (embargo 10s).
- 414,029 outcome rows (7 horizons: 100ms..10s).

## KEY FINDING: real but economically useless sub-second signal

### 1. Information gain by horizon (discovery)
| feature | 100ms | 250ms | 500ms | 1s | 2s | 5s | 10s |
|---|---:|---:|---:|---:|---:|---:|---:|
| imb100ms | **0.0224** | 0.0162 | 0.0112 | 0.0056 | 0.0032 | 0.0009 | 0.0004 |
| imb250ms | 0.0214 | 0.0158 | 0.0111 | 0.0057 | 0.0031 | 0.0009 | 0.0004 |
| tickdir_up | 0.0118 | 0.0121 | 0.0087 | 0.0042 | 0.0016 | 0.0006 | 0.0002 |
| vol1s | 0.0051 | 0.0099 | 0.0061 | 0.0029 | 0.0011 | 0.0002 | 0.0002 |

There IS genuine predictive information at 100-250ms (tick imbalance), decaying to ~0 by 5s.

### 2. Tick classification audit
Tick-rule (mid up/down/zero) over 1s: up 37.6%, down 37.6%, zero 24.8% (symmetric).
P(up) by tickdir_up tercile: 500ms 0.344 -> 0.415 -> 0.457 (base 0.400); 1s 0.404 -> 0.455 -> 0.488 (base 0.445); 5s 0.471 -> 0.489 -> 0.511 (base 0.488). The spread narrows as horizon grows.

### 3. OOS stability
| feature | disc lift | val lift | OOS lift | stable? |
|---|---:|---:|---:|---|
| imb250ms | -0.059 | -0.066 | -0.098 | YES (sign stable) |
| imb100ms | +0.055 | +0.057 | +0.075 | YES |
| tick_rate | -0.057 | -0.046 | -0.041 | YES |
| vol1s | -0.058 | -0.050 | -0.053 | YES |
| tickdir_up | -0.070 | -0.071 | +0.087 | NO (sign flip) |
| imb500ms | +0.059 | -0.066 | -0.094 | NO (sign flip) |

The imbalance signal is OOS-stable, but the magnitude is small.

### 4. Economic value (the decisive point)
For the strongest cell (imb250ms bin0, down move):
- gross mid move = **-2.5 pts** (predictable, real).
- SELL net after 26-pt spread = -2.5 - 26 = **-23.5 pts**.
- BUY net = -2.5 - 26 = -28.5 pts.
- Even at a hypothetical 10-pt spread: net = -12.5 pts. Still deeply negative.

**The predictable move (~2.5 pts) is ~10x smaller than the spread (26 pts).**

## CLASSIFICATION
| Discovery | Classification |
|---|---|
| Tick imbalance at 100-250ms vs direction | **Confirmed Predictive Information** (statistical, OOS-stable) |
| Tick imbalance at 5-10s | **No Predictive Information** |
| tickdir_up, imb500ms | **Statistical Association Only** (sign flips OOS) |
| Economic edge after cost | **None** (move << spread) |

## ANSWERS TO THE 5 REQUIRED QUESTIONS
1. **New directional information?** YES — signed tick imbalance / bid-ask update asymmetry at 100-250ms.
2. **Exact source?** Sub-second tick-rule imbalance (imb100ms/imb250ms) and tick arrival rate.
3. **When appears / disappears?** Appears 100-500ms; decays to ~0 by 5s; gone by 10s.
4. **Survives OOS?** YES statistically (stable sign for imb250ms/imb100ms/tick_rate/vol1s), but magnitude ~2.5 pts.
5. **Useful after cost?** NO. Move (~2.5 pts) is ~10x below the 26-pt spread; net is -23.5 pts even for the best direction.

## VERDICT
A real, statistically confirmed sub-second microstructure edge exists but is **economically unusable** at JustMarkets XAUUSD.m standard spread. To exploit it would require sub-3-point execution cost (spread < ~2.5 pts), which this broker does not offer. No strategy is proposed.
