# Ensemble calibration — NBM-based bucket probabilities for Kalshi daily-high markets

Written 2026-08-05. Prototype under `research/kalshi_latency/research/ensemble_calibration/`.
Python prototype only; production port is stdlib Ruby (plan in section 8).

## 1. What this is

Map public NWS forecast data to a probability per Kalshi 2-degree bucket, per
station, so our probabilities can be compared to market prices. Hypothesis
under test: the market prices off the point forecast and misprices the tails.

> **THE HYPOTHESIS IS FALSIFIED. Scored against 292 station-days of real
> market prices on 2026-08-05 — see section 10. The market is both better
> centred and sharper than this model, at every station, on both proper
> scoring rules. Do not build on section 8.**

The live snapshot in section 6 is consistent with that hypothesis, and the
held-out calibration check in section 5 says our distribution — not the
market's concentration — matches how often settled highs actually land in the
modal bucket. That is *not yet* proof of +EV; see limitations.

Both of those readings turned out to be wrong, for reasons worth keeping: the
section 5 comparison was invalid (it scored our modal bucket against the
market's price on a different bucket), and being calibrated was never
sufficient — a well-calibrated but WIDE distribution loses to a
well-calibrated sharp one under every proper scoring rule. Limitation 1 said
exactly this before the evidence arrived.

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

> **CORRECTION 2026-08-05, after scoring against 292 station-days of real
> market prices. The paragraph below is WRONG and is kept only so the error is
> legible.**
>
> ~~Read this against section 6: at 24-42h lead the *true* frequency of the
> modal bucket is 25-36% for NYC/Denver/Austin. A market pricing the modal
> bucket at 55-60c at that lead would be roughly twice too confident. Miami is
> the exception — a 50c modal bucket there is about right.~~
>
> The comparison is invalid. It measures the hit rate of **our** modal bucket
> and holds it against the market's price on **its own, different** modal
> bucket. Those are not the same contract. When each side is scored on the
> bucket it actually names:
>
> ```
>            predicted    actual
> ours         0.376       0.390     well calibrated, but wide
> market       0.492       0.497     better calibrated AND far sharper
> ```
>
> The modal buckets agree on only 54% of days. Ours is correct 39% of the time,
> the market's 50%. The market was not twice too confident; it was right to be
> confident, and we were mushy. See section 10.

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

1. ~~**We have not scored the model against market prices, only against
   settlement.**~~ **CLOSED 2026-08-05, AGAINST US.** Scored over 292
   station-days / 73 dates: log loss ours 1.4015 vs market 1.1039, Brier
   0.7032 vs 0.5966, we win 71/292 days. Every station clear of zero; robust
   to bid/ask/mid, either lead cell, and five sample hours. The worry this
   limitation raised — "the market could still be better than us at the times
   we would actually trade" — was exactly right. See section 10.
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
9. ~~**The strawman comparison is generous to us.**~~ **CLOSED 2026-08-05.**
   The market's implied distribution was extracted properly from the full
   6-market strip — verified mutually exclusive and exhaustive on all 292
   strips — and renormalised; mean overround 1.032, mean per-leg spread 1.45c.
   The strawman was indeed generous: against the real baseline we lose. The
   two-bid-ladder trap was checked directly, `yes_ask + no_bid == 1.0000` on
   every leg, so `yes_ask` is a genuine derived YES offer and not a NO bid
   misread. See section 10.

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

## 10. Scored against the market — 2026-08-05

Limitation 1 was the gate on everything else, and it closed against us.

**Data.** Our own recorders had zero usable observations: `judgment-2026-08-05.jsonl`
was ~6 hours old and its only local_date does not settle until 2026-08-06. What made
the analysis possible instead is that **Kalshi publishes a rolling window of public
price history**: `GET /markets?series_ticker=..&status=settled` returns ~73
consecutive event-dates, and `GET /series/{s}/markets/{t}/candlesticks` gives hourly
`yes_bid`/`yes_ask` over each market's whole life. Both unauthenticated. That yielded
292 station-days (KAUS/KDEN/KMIA/KNYC, 2026-05-24 to 2026-08-04) — four times what
30 forward days of recording would have produced, available immediately.

The window rolls forward and older tickers return nothing, so history cannot be
recovered retroactively. Anything wanting more has to accumulate it going forward.

**Two checks before trusting any of it.** Settlement basis: Kalshi's
`expiration_value` equals the IEM CLI high on 292/292 events — for a CLI-targeted
model the METAR-vs-CLI basis risk in HANDOFF section 4 simply does not apply. Read
path: candlesticks at the live recorder's exact minute matched the Ruby recorder's
own quotes on 39/48 legs, the rest within 1c of sub-minute drift.

**Result**, sampled at 06:00Z on the event day — the 00Z NBM run is out, the local
day has barely begun, no intraday ratchet information exists for either side, which
is the most generous fair timing for a pre-day pricer:

```
                ours      market
log loss       1.4015    1.1039     delta +0.2976, 95% CI [+0.2288, +0.3727]
Brier          0.7032    0.5966     delta +0.1066, 95% CI [+0.0749, +0.1364]
we win         71/292 days (24%)    sign test p ~ 4e-19
```

Every station clear of zero. Robust to bid-only / ask-only / mid, to either lead
cell, and at 02Z / 06Z / 10Z / 14Z / 18Z. CIs are a block bootstrap over whole dates,
since adjacent days share weather regimes and same-day stations share synoptic error.

**Why.** The market is both better centred and sharper:

```
              mean abs location error    implied sd
ours                  1.74 F                2.43
market                1.29 F                1.83
```

Our distribution is well calibrated but WIDE, and a mushy calibrated distribution
loses to a sharp calibrated one under every proper scoring rule. Tails, the direct
test of the hypothesis: actual 0.168, market 0.141, ours 0.196 — the market
underprices tails by 2.7pp and we OVERprice them by 2.8pp. The market put 497 legs
in the 0-2c bin at a mean 0.9c and exactly 1 of 497 settled YES; the cheap tails
were rich, not cheap.

**The slice that should govern any future attempt.** Sorted by how far we disagree
with the market: low tercile +0.1303, mid +0.2742, **high +0.4899**. The more we
disagree, the worse we are. That is HANDOFF section 4's "persistence is a doubt
signal, read backwards" generalised from the ratchet to the pricer — our
disagreement measures our error, not the market's slowness.

**Paper PnL** over the window (top-of-book, 100 contracts per signal, correct
per-order fee, settled against real results): signalled **+$14,794**, realised
**-$1,908**, 30% win rate. Buy trades at a mean 8.0c — the tail-buying thesis — lost
$1,400 of it. And that is an upper bound: it assumes a fill at the touch, which is
the assumption funding-gate item 3 exists to test, and which the 2026-08-05
fill-quality probes found does not hold.

**Seasonality** (limitation 2) is real but not the story: refitting May-Aug narrows
the gap from +0.2976 to +0.2559, about 14% of it.

**What would have to change before revisiting.** Neither is tuning; both are a
different model. (a) Fresher forecast input read straight from NWS rather than the
IEM archive — at 02Z the freshness gap is ~2h and the market still wins by +0.253,
so this shrinks the deficit, it does not reverse it. (b) A genuinely sharper
conditional distribution: season terms at minimum, realistically conditioning on the
overnight low and the current METAR, which is plainly what the market is already
doing.

`bin/record_judgments` should keep running — cheap, GET-only, an independent
forward-looking record.

Scripts: `fetch_market_history.py`, `score_vs_market.py`, `diagnose_vs_market.py`,
`reliability_and_season.py`. Tables: `MARKET_SCORING*.md`, `market_vs_model_*.csv`.
