# Diagnostics — why the market wins (292 station-days, 06Z)

## 1. Location vs dispersion

Both distributions summarised by the mean and sd they imply over the 6 legs (legs represented by their centre degree; the two tails by centre+/-2, so the sd is a floor, not exact).

| slice | n | our mean err | market mean err | our |err| | market |err| | our implied sd | market implied sd |
|---|---|---|---|---|---|---|---|
| ALL | 292 | +0.32 | +0.08 | 1.74 | 1.29 | 2.43 | 1.83 |
| KAUS | 73 | +0.10 | +0.09 | 1.70 | 1.28 | 2.61 | 1.87 |
| KDEN | 73 | +0.29 | +0.07 | 1.83 | 1.41 | 2.96 | 2.09 |
| KMIA | 73 | -0.40 | -0.36 | 1.31 | 1.10 | 1.67 | 1.57 |
| KNYC | 73 | +1.31 | +0.54 | 2.12 | 1.39 | 2.48 | 1.78 |

modal bucket agreement: 54% of days
our modal correct 39%, market modal correct 50%

## 2. The tail hypothesis

The report's thesis: the market piles onto the point-forecast bucket and starves both tails, so the tails are cheap. The two outer legs (`less` and `greater`) settled YES this often:

| slice | n | our mean P(tail) | market mean P(tail) | actual tail frequency |
|---|---|---|---|---|
| ALL | 292 | 0.196 | 0.141 | 0.168 |
| KAUS | 73 | 0.196 | 0.116 | 0.110 |
| KDEN | 73 | 0.274 | 0.174 | 0.192 |
| KMIA | 73 | 0.046 | 0.042 | 0.068 |
| KNYC | 73 | 0.268 | 0.232 | 0.301 |

## 3. Does the edge live on high-spread (high xnd) days?

| xnd tercile | n | ours LL | market LL | d LL | 95% CI |
|---|---|---|---|---|---|
| low xnd (xnd 1-2) | 201 | 1.3380 | 1.0363 | +0.3017 | [+0.2179, +0.3916] |
| high xnd (xnd 3-6) | 91 | 1.5418 | 1.2533 | +0.2885 | [+0.1464, +0.4233] |

## 4. Paper PnL of the trades our probabilities imply

Top-of-book only, 100 contracts per signal, Kalshi's per-order fee, settled against the real result. Assumes a fill at the touch, which funding-gate item #3 says is exactly the assumption that has never been measured -- so read this as an upper bound.

| slice | trades | signalled EV ($) | realised PnL ($) | win rate | PnL per trade ($) |
|---|---|---|---|---|---|
| ALL | 1578 | +14793.87 | -1908.20 | 30% | -1.21 |
| KAUS | 409 | +3881.90 | -432.74 | 27% | -1.06 |
| KDEN | 411 | +3642.87 | -538.83 | 31% | -1.31 |
| KMIA | 356 | +3030.72 | -220.07 | 38% | -0.62 |
| KNYC | 402 | +4238.38 | -716.56 | 25% | -1.78 |

  buy: 943 trades, realised -1399.82, mean price 8.0c
  sell: 635 trades, realised -508.38, mean price 34.2c

