# Reliability and seasonality (292 station-days, 1752 legs, 06Z)

## A. Reliability by assigned probability

Every leg of every strip, binned by the probability each side gave it, against how often that leg actually settled YES. Perfect calibration is `settled` equal to `mean p` inside every bin.

| p bin | our legs | our mean p | our settled | market legs | market mean p | market settled |
|---|---|---|---|---|---|---|
| 0.00-0.02 | 223 | 0.008 | 0.009 | 497 | 0.009 | 0.002 |
| 0.02-0.05 | 206 | 0.033 | 0.044 | 276 | 0.031 | 0.025 |
| 0.05-0.10 | 280 | 0.077 | 0.043 | 176 | 0.071 | 0.057 |
| 0.10-0.20 | 376 | 0.150 | 0.128 | 193 | 0.150 | 0.140 |
| 0.20-0.35 | 534 | 0.266 | 0.288 | 268 | 0.275 | 0.276 |
| 0.35-0.50 | 85 | 0.414 | 0.471 | 223 | 0.420 | 0.439 |
| 0.50-0.70 | 47 | 0.589 | 0.574 | 110 | 0.568 | 0.600 |
| 0.70-1.00 | 1 | 0.821 | 0.000 | 9 | 0.851 | 1.000 |

Aggregate leg Brier (binary, lower is better): ours 0.1172, market 0.0994

## B. Refit on summer only (May-Aug, train < 2026) — is the gap seasonal?

| station | n_train | pooled mu / a / b / df | summer mu / a / b / df |
|---|---|---|---|
| KAUS | 369 | +0.37 / 0.47 / 0.70 / 5 | +0.20 / 0.59 / 0.72 / 15 |
| KDEN | 369 | +0.37 / 0.60 / 0.93 / 8 | +0.01 / 0.63 / 0.84 / 15 |
| KMIA | 366 | +0.08 / 0.49 / 0.55 / 8 | +0.02 / 0.53 / 0.40 / 5 |
| KNYC | 367 | +0.36 / 0.96 / 0.62 / 8 | -0.53 / 1.08 / 0.61 / norm |

| model | n | ours LL | market LL | d LL | 95% CI | ours Brier | market Brier |
|---|---|---|---|---|---|---|---|
| pooled year-round (shipped) | 292 | 1.4015 | 1.1039 | +0.2976 | [+0.2288, +0.3727] | 0.7032 | 0.5966 |
| summer-only refit | 292 | 1.3598 | 1.1039 | +0.2559 | [+0.1845, +0.3257] | 0.6942 | 0.5966 |

