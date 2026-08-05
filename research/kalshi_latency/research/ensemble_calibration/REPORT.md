# Ensemble calibration — NBM-based bucket probabilities for Kalshi daily-high markets

Written 2026-08-05. Prototype under `research/kalshi_latency/research/ensemble_calibration/`.
Python prototype only; production port is stdlib Ruby (plan in section 8).

## 1. What this is

Map public NWS forecast data to a probability per Kalshi 2-degree bucket, per
station, so our probabilities can be compared to market prices. Hypothesis
under test: the market prices off the point forecast and misprices the tails.

The live snapshot in section 6 is consistent with that hypothesis, and the
held-out calibration check in section 5 says our distribution — not the
market's concentration — matches how often settled highs actually land in the
modal bucket. That is *not yet* proof of +EV; see limitations.

## 2. Data source comparison

| Source | Access | Update cadence | Historical archive | Effort | Verdict |
|---|---|---|---|---|---|
| **NBM text bulletins (NBS/NBE) via IEM MOS archive** | `mesonet.agron.iastate.edu/api/1/mos.json` (single run) and `/cgi-bin/request/mos.py` (bulk CSV). No key. | NBM runs hourly; IEM ingests hourly, lags a few hours | Verified back to at least 2021 (probed 2021-01-01, 93 rows) | Trivial — parsed JSON/CSV, `txn` = max/min forecast, `xnd` = its ensemble SD | **CHOSEN** for both history and (for now) live |
| NWS CLI reports via IEM CLI archive | `mesonet.agron.iastate.edu/json/cli.py?station=KNYC&year=YYYY`. No key. | After each CLI issuance | Full multi-year | Trivial — `high` field parsed from the exact product Kalshi settles on | **CHOSEN as target.** Zero basis risk |
| api.weather.gov gridpoint (`/gridpoints/OKX/34,38`) | REST, no key (User-Agent required) | ~hourly | **None** — current forecast only | Low, but `maxTemperature` is degC on 13h windows; no spread | Rejected for calibration (no history, no spread). Useful cross-check only |
| GEFS ensemble (raw GRIB2, AWS Open Data `noaa-gefs-pds`) | S3, no key | 4x/day, 31 members | Full archive | **High** — GRIB decoding, grid-to-station interpolation, ~GBs/day | Rejected. NBM already blends GEFS+others and publishes station values + SD |
| GFS MOS (MAV/MEX) via IEM | Same IEM endpoints, `n_x` field | MEX 2x/day | Back to ~2000 | Trivial | Backup only. Older tech than NBM; MAV returned 0 rows at KNYC in probe |
| NBM GRIB on NOMADS/AWS | HTTP/S3, no key | Hourly | Yes (AWS) | High (GRIB) | Unnecessary — text bulletin has what we need |
| GHCN-D (NCEI access API) | REST, no key | Daily, days lagged | Full | Low | Backup target only. CLI archive is the settlement product itself; prefer it |

Key discovery: the NBE bulletin row at 00Z valid time carries `txn` (daytime
max, whole deg F) **and `xnd` (the NBM ensemble standard deviation of that
max)**. The spread feature comes free — no ensemble processing needed.

## 3. Model design

Deliberately small. Everything is a table lookup plus one distribution.

- **Features:** `txn` (NBM forecast of daily max), `xnd` (NBM ensemble SD of
  it), lead time (hours from NBM runtime to the 00Z valid time), station.
- **Target:** CLI-settled daily high, whole degrees F, from the IEM CLI archive
  (the same NWS Climatological Report named in Kalshi's `rules_primary`).
- **Error model,** fit per (station, lead-bin) cell:

  ```
  e = cli_high - txn
  e ~ mu + sigma_i * T_nu          # Student-t, nu from {3,5,8,15,normal}
  sigma_i = a + b * xnd_i          # scale linear in ensemble spread
  ```

  Fit by maximum likelihood on the *discrete* log score
  `log[F((e+0.5-mu)/sigma) - F((e-0.5-mu)/sigma)]` — the thing we actually
  need to be right, probability mass on integers. nu chosen by held-out score.
- **Output:** `P(H = t) = F((t+0.5-txn-mu)/sigma) - F((t-0.5-txn-mu)/sigma)`
  summed over each Kalshi bucket using the handoff's bound rules
  (B both-inclusive, T-greater floor-exclusive, T-less cap-exclusive).
- **Lead bins:** 13-24h, 24-42h, 42-66h. NBM runs hourly but consecutive runs
  are near-duplicates, so fitting **dedupes to one run per local date per bin**
  (latest). This is why n below is ~1090 not ~50,000 — the 54k raw pairs per
  station would be fake sample size.

No deep learning, no gradient boosting. Three parameters plus a df per cell,
21 numbers per station. Portable to a JSON table + one CDF function.

## 4. Fitted error distributions (the actual sample sizes)

Stations: KNYC, KMIA, KDEN, KAUS (4 of the 7 verified). History 2023-01-01 to
2026-08-04. Train = local_date < 2026-01-01, test = 2026 (out of time, not
random split). **n_train ~= 1090 independent days per cell, n_test 124-216.**

From `fit_stats.csv` (err = settled high minus forecast, deg F):

| station | lead | n_train | n_test | bias mu | sigma_a | sigma_b*xnd | t df | err sd | P(\|e\|<=1) | corr(xnd,\|e\|) | test logscore model | vs sigma=3 normal |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| KAUS | 13-24h | 1096 | 125 | +0.37 | 0.47 | 0.70 | 5 | 2.72 | 54% | 0.39 | -2.267 | -2.376 |
| KAUS | 24-42h | 1095 | 216 | +0.37 | 0.57 | 0.63 | 5 | 2.71 | 53% | 0.29 | -2.235 | -2.378 |
| KAUS | 42-66h | 1095 | 216 | +0.39 | 0.57 | 0.71 | 5 | 3.08 | 48% | 0.36 | -2.318 | -2.422 |
| KDEN | 13-24h | 1096 | 125 | +0.37 | 0.60 | 0.93 | 8 | 3.16 | 45% | 0.40 | -2.403 | -2.526 |
| KDEN | 24-42h | 1095 | 216 | +0.44 | 0.46 | 1.00 | 8 | 3.30 | 47% | 0.44 | -2.408 | -2.486 |
| KDEN | 42-66h | 1095 | 216 | +0.42 | 0.73 | 0.92 | 8 | 3.52 | 42% | 0.42 | -2.456 | -2.524 |
| KMIA | 13-24h | 1088 | 124 | +0.08 | 0.49 | 0.55 | 8 | 1.44 | 76% | 0.29 | -1.851 | -2.174 |
| KMIA | 24-42h | 1087 | 215 | +0.13 | 0.46 | 0.59 | 8 | 1.51 | 75% | 0.29 | -1.862 | -2.177 |
| KMIA | 42-66h | 1087 | 215 | +0.12 | 0.55 | 0.52 | 5 | 1.62 | 72% | 0.23 | -1.947 | -2.208 |
| KNYC | 13-24h | 1094 | 125 | +0.36 | 0.96 | 0.62 | 8 | 2.42 | 50% | 0.30 | -2.607 | -2.771 |
| KNYC | 24-42h | 1093 | 216 | +0.33 | 1.09 | 0.58 | 8 | 2.52 | 50% | 0.27 | -2.549 | -2.616 |
| KNYC | 42-66h | 1093 | 216 | +0.36 | 1.13 | 0.64 | 8 | 2.75 | 47% | 0.23 | -2.606 | -2.694 |

What the fits say:

- **The spread feature is real.** corr(xnd, |e|) is 0.23-0.44 everywhere, and
  the fitted b is 0.5-1.0 — days the ensemble disagrees are genuinely harder.
  This is the feature the hypothesis says the market ignores.
- **Heavy tails are real.** Every cell chose t (df 5-8) over normal.
- **Small warm bias everywhere** (+0.1 to +0.44 F): settled highs run slightly
  above NBM. Consistent with known NBM cool bias at max-temp.
- **Stations differ a lot.** Miami err sd ~1.5 (marine, easy); Denver ~3.3
  (hard). One global sigma would be badly wrong in both directions.
- Held-out log score beats a sigma=3 point-forecast strawman in all 12 cells.

## 5. Held-out calibration check (2026, never touched by the fit)

For each test day: take the model's *modal* 2-degree bucket (even-floor grid,
matching Kalshi's) and compare predicted probability to how often the settled
high actually landed there (`calibration_check.csv`):

| station | lead | n_test | predicted modal prob | empirical hit rate |
|---|---|---|---|---|
| KAUS | 24-42h | 216 | 0.34 | 0.36 |
| KDEN | 24-42h | 216 | 0.29 | 0.36 |
| KMIA | 24-42h | 215 | 0.52 | 0.55 |
| KNYC | 24-42h | 216 | 0.31 | 0.25 |

Full table in the CSV; PIT tail frequencies are mostly near the nominal 10%
(worst: KNYC 13-24h right tail 17.6% — the model's warm tail is still slightly
too thin there even after the t).

Read this against section 6: at 24-42h lead the *true* frequency of the modal
bucket is 25-36% for NYC/Denver/Austin. A market pricing the modal bucket at
55-60c at that lead would be roughly twice too confident. Miami is the
exception — a 50c modal bucket there is about right.

## 6. Example output vs the live market (real, 2026-08-05)

`predict_tomorrow.py KNYC KXHIGHNY`, NBE run 2026-08-05T00Z, lead 24h,
txn=82F, xnd=3 -> mu=82.3, sigma=2.83, t(8). Quotes are live Kalshi
(public endpoint, GET-only), pre-dawn ET so no intraday ratchet info yet:

```
ticker                       ours   yes_bid yes_ask  bucket
KXHIGHNY-26AUG05-T80        17.3c      2c      3c    79 or below
KXHIGHNY-26AUG05-B80.5      21.5c     13c     14c    80-81
KXHIGHNY-26AUG05-B82.5      26.7c     57c     59c    82-83
KXHIGHNY-26AUG05-B84.5      19.7c     26c     27c    84-85
KXHIGHNY-26AUG05-B86.5       9.5c      3c      4c    86-87
KXHIGHNY-26AUG05-T87         5.2c      0c      1c    88 or above
```

Same shape at Miami (KXHIGHMIA, txn=90, xnd=3): market 49-50c on 90-91 vs our
32.7c; market 1-2c on 94-or-above vs our 8.6c.

The pattern is exactly the hypothesis: market piles onto the point-forecast
bucket and starves both tails. Per section 5 the historical base rates side
with our numbers at NYC-like stations. And per the handoff's fee formula
(quadratic in price), the tails — where the disagreement is largest — are
where fees are near zero.

**Do not read this table as "buy T80 at 3c."** One snapshot, and the market
keeps trading through the day with information (the intraday ratchet, newer
NBM runs) this 00Z-run model does not have.

## 7. Honest limitations

1. **We have not scored the model against market prices, only against
   settlement.** Beating a sigma=3 strawman and being calibrated is necessary,
   not sufficient. The market could still be better than us at the *times we
   would actually trade*. Needed: record our probabilities and the book
   daily (the existing collector infrastructure does the book half already),
   then score log-loss/Brier vs market-implied probabilities over 30+ days.
2. **Sample sizes:** ~1090 train days and 124-216 test days per cell. Enough
   for mu/sigma/df; not enough to segment by season — and sigma is almost
   certainly seasonal. Pooled year-round fit means summer buckets are probably
   slightly *over*-dispersed and winter slightly under. With one more year of
   data, add a season term or fit summer-only.
3. **NBM version drift.** 2023-2026 spans NBM 4.0/4.1/4.2 upgrades. The error
   distribution we fit is a blend across versions; the current model's true
   sigma may be smaller than fitted (would shrink our tail edge).
4. **IEM ingest lag.** The "latest" NBE run available was ~5h old at run time.
   Fine for a 24h-lead trade, not for late-morning re-quoting. Live production
   should read the NBE text product straight from NWS
   (`https://tgftp.nws.noaa.gov/data/products/` or api.weather.gov `/products`,
   product code NBE) — same bulletin, minutes-fresh, still no key.
5. **The intraday problem is unmodeled.** Once the day starts, the running
   METAR max truncates the distribution (a max cannot fall). This model is a
   *pre-day* pricer. The right intraday model is
   P(final = t | running max m, hour h) — conditioning this distribution on
   the ratchet, composing with the existing `temp_market.rb` machinery. Not built.
6. **KNYC 13-24h right tail is still 1.8x too frequent** (PIT > 0.9 on 17.6%
   of test days vs nominal 10). Warm busts at Central Park exceed even a t(8).
   Don't sell the warm tail at NYC on this model's say-so.
7. **4 of 7 verified stations fitted.** KMDW, KLAX, KPHL not yet run (same
   pipeline, add to `STATIONS` in `fetch_data.py`). Unverified stations
   inherit the handoff's station-identity risk on top of everything here.
8. **Even-floor bucket grid assumed** in the calibration check. Spot-checked
   on live NYC/MIA markets (both even), not proven for all stations/seasons.
   The predictor itself reads the actual tickers, so only section 5 is exposed.
9. **The strawman comparison is generous to us.** The real market's implied
   distribution (from the full bucket strip) should be extracted and scored
   as the proper baseline.

## 8. Porting plan to Ruby (stdlib-only)

The model at runtime is: params lookup + one CDF + arithmetic. No fitting in
production — Python fits offline, Ruby consumes `params.json`.

1. **Ship `params.json` as the artifact** (already written by `fit_model.py`):
   `{station|lead_bin: {mu, a, b, nu}}`. Refitting stays a Python-side
   research task; the JSON is regenerated and reviewed like config.
2. **Student-t CDF in stdlib Ruby.** Two options: (a) regularized incomplete
   beta via Lentz continued fraction (~30 lines, unit-test against scipy
   values baked into specs); (b) precompute a standardized CDF grid per df
   (z = -8.0..8.0 step 0.01, ~1600 floats per df, 3 dfs used) into the JSON;
   Ruby linear-interpolates. **Recommend (b)** — zero numerics risk, trivially
   mutation-testable, matches the repo's small-honest-code culture.
3. **`lib/nbm_source.rb`:** GET the NBE text product (NWS, not IEM, per
   limitation 4), parse the X/N and XND rows for the station line (fixed-width,
   ~40 lines). Fall back to IEM JSON.
4. **`lib/bucket_pricer.rb`:** `probabilities(txn:, xnd:, lead_hours:,
   station:, tickers:)` -> {ticker => prob}, reusing the existing tested
   strike-bound rules from `temp_market.rb` — reuse, don't re-derive.
5. **Wire in as a *judgment* layer parallel to the ratchet layer:** ratchet
   says "already decided"; this says "mispriced before decided". GET-only.
   Prediction-only until it has its own scored record, same discipline as the
   21 unverified stations.
6. **TDD per standing instructions:** vertical slices; varied (non-constant)
   fixtures for CDF interpolation, NBE text parse, and each bucket-bound case;
   mutation-test the bound-inclusivity flips specifically — that is where
   `temp_market.rb` history says the bugs live.

## 9. Files

```
fetch_data.py            pull NBE (IEM bulk CSV) + CLI highs, build pairs_*.csv
fit_model.py             fit per-cell error models, write params.json, fit_stats.csv
predict_tomorrow.py      latest NBE run -> bucket probs vs live Kalshi quotes
params.json              the fitted model (the thing Ruby would consume)
fit_stats.csv            section 4 table
calibration_check.csv    section 5 table
data/pairs_*.csv         (station, date, runtime, lead, txn, xnd, cli_high)
```

Python venv lives in the session scratchpad, not the repo. Deps: numpy,
scipy, pandas — fitting only; nothing here needs them at trade time.
