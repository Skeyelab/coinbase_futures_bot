# Our distribution vs the market's — 06Z sample, lead bin 13-24h (production cell)

paired observations (station-days): 292
dates: 73  stations: ['KAUS', 'KDEN', 'KMIA', 'KNYC']

mean strip overround before renormalising: 1.0318 (median 1.0350)
mean per-leg bid/ask spread: 1.45c

## Multiclass scores over the 6-leg strip (lower is better)

| slice | n | ours log-loss | market log-loss | ours Brier | market Brier |
|---|---|---|---|---|---|
| ALL | 292 | 1.4015 | 1.1039 | 0.7032 | 0.5966 |
| KAUS | 73 | 1.4105 | 1.1082 | 0.7187 | 0.5917 |
| KDEN | 73 | 1.4572 | 1.2044 | 0.7208 | 0.6420 |
| KMIA | 73 | 1.2336 | 0.9576 | 0.6357 | 0.5472 |
| KNYC | 73 | 1.5048 | 1.1456 | 0.7376 | 0.6056 |
| chance (1/6) | - | 1.7918 | 1.7918 | 0.8333 | 0.8333 |

## Paired difference, ours minus market (negative = we win)

| slice | n | d log-loss | 95% CI (date block bootstrap) | d Brier | 95% CI | days we score better |
|---|---|---|---|---|---|---|
| ALL | 292 | +0.2976 | [+0.2288, +0.3727] | +0.1066 | [+0.0749, +0.1364] | 24% |
| KAUS | 73 | +0.3023 | [+0.1618, +0.4298] | +0.1270 | [+0.0638, +0.1866] | 23% |
| KDEN | 73 | +0.2528 | [+0.1473, +0.3529] | +0.0788 | [+0.0286, +0.1289] | 25% |
| KMIA | 73 | +0.2760 | [+0.1296, +0.4415] | +0.0886 | [+0.0284, +0.1480] | 33% |
| KNYC | 73 | +0.3592 | [+0.1986, +0.5134] | +0.1320 | [+0.0635, +0.2002] | 16% |

## Robustness: which side of the book, and which lead cell

| market price used | lead cell | n | ours LL | market LL | d LL | 95% CI |
|---|---|---|---|---|---|---|
| mid (primary) | 13-24h | 292 | 1.4015 | 1.1039 | +0.2976 | [+0.2263, +0.3699] |
| bid side | 13-24h | 292 | 1.4015 | 1.0933 | +0.3082 | [+0.2347, +0.3812] |
| ask side | 13-24h | 292 | 1.4015 | 1.1150 | +0.2865 | [+0.2163, +0.3552] |
| mid | 24-42h | 292 | 1.3973 | 1.1039 | +0.2934 | [+0.2215, +0.3629] |

## Same comparison through the day (market gains intraday info, we do not)

| sample hour UTC | n | ours LL | market LL | d LL | 95% CI | ours Brier | market Brier |
|---|---|---|---|---|---|---|---|
| 02Z | 292 | 1.4015 | 1.1485 | +0.2530 | [+0.1817, +0.3213] | 0.7032 | 0.6173 |
| 06Z | 292 | 1.4015 | 1.1039 | +0.2976 | [+0.2251, +0.3698] | 0.7032 | 0.5966 |
| 10Z | 292 | 1.4015 | 1.0561 | +0.3454 | [+0.2689, +0.4229] | 0.7032 | 0.5812 |
| 14Z | 292 | 1.4015 | 1.0031 | +0.3984 | [+0.3207, +0.4730] | 0.7032 | 0.5615 |
| 18Z | 292 | 1.4015 | 0.6670 | +0.7345 | [+0.6501, +0.8216] | 0.7032 | 0.3885 |

## Calibration of the modal bucket, both sides (settlement check)

| slice | n | our mean modal p | our modal hit rate | market mean modal p | market modal hit rate |
|---|---|---|---|---|---|
| ALL | 292 | 0.376 | 0.390 | 0.492 | 0.497 |
| KAUS | 73 | 0.335 | 0.342 | 0.478 | 0.507 |
| KDEN | 73 | 0.304 | 0.370 | 0.439 | 0.452 |
| KMIA | 73 | 0.504 | 0.521 | 0.539 | 0.534 |
| KNYC | 73 | 0.363 | 0.329 | 0.513 | 0.493 |

