#!/usr/bin/env python3
"""Score our NBM bucket distribution against the MARKET'S implied distribution.

Report limitation #1: the model had only ever been scored against settlement.
Being calibrated is necessary, not sufficient -- the market could still be
better at the hours we would actually trade. This is that comparison.

--------------------------------------------------------------------------
The market's implied distribution (report limitation #9)
--------------------------------------------------------------------------
Not a single quote and not a strawman. For each (series, event date) Kalshi
lists a strip of exactly 6 markets that tile the integers with no gap and no
overlap -- one `less` tail, four 2-degree `between` buckets, one `greater`
tail -- and exactly one settles YES. That strip IS a categorical distribution
once you renormalise it.

Per leg the YES quote is (yes_bid, yes_ask). The bid-ladder trap: Kalshi's raw
book publishes two BID ladders, yes and no; a NO bid at 62c is a YES offer at
38c. The `yes_ask` field on /markets and on candlesticks is already that
derived offer -- verified on live quotes, yes_ask + no_bid == 1.0000 exactly.
So (yes_bid, yes_ask) is a genuine two-sided YES quote, and

    q_i = (yes_bid_i + yes_ask_i) / 2          # leg mid, in probability
    p_market_i = q_i / sum_j q_j               # renormalised across the strip

The pre-normalisation sum is reported as `overround` -- it is the vig plus
spread and is the reason renormalising matters.

Two robustness variants are also scored:
  - bid side only  (q_i = yes_bid_i)   : what you could SELL the strip at
  - ask side only  (q_i = yes_ask_i)   : what you could BUY the strip at
Both renormalised the same way. If our edge only survives at the mid it is not
an edge you can trade.

--------------------------------------------------------------------------
Our distribution
--------------------------------------------------------------------------
Same params.json the Ruby side consumes. For event date D we use the 00Z NBM
run on D (valid 00Z D+1, lead 24h) -- the exact run and lead the live
`bin/record_judgments` freezes. Bucket bounds use the repo's rules:
between both-inclusive, greater floor-exclusive, less cap-exclusive. Because
the strip tiles the integers our probabilities sum to 1 by construction; the
sum is asserted, not renormalised.

--------------------------------------------------------------------------
Timing
--------------------------------------------------------------------------
Primary sample hour is 06:00Z on the event day: 02:00 ET / 01:00 CDT /
00:00 MDT. The 00Z NBM run is published, the local day has barely started, and
neither side has any intraday ratchet information. That is the regime this
model was built for. Later hours are also scored to show what happens once the
market has information the model does not.

Metrics are multiclass over the 6-leg strip:
    log loss  = -log p(settled leg)          (chance = log 6 = 1.7918)
    Brier     = sum_i (p_i - y_i)^2          (chance = 5/6 = 0.8333)
Significance is a paired-by-event block bootstrap resampling whole DATES
(keeping all four stations together), because adjacent days share weather
regimes and same-day stations share synoptic errors.
"""

import calendar
import json
import math
from collections import defaultdict
from datetime import datetime
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import stats

HERE = Path(__file__).parent
CACHE = HERE / "data" / "cache"
SERIES = {"KXHIGHNY": "KNYC", "KXHIGHMIA": "KMIA",
          "KXHIGHDEN": "KDEN", "KXHIGHAUS": "KAUS"}
# Ruby BucketPricer.cell_for uses (lo, hi]; the Python fit used [lo, hi).
# lead=24 therefore lands in 13-24h in production and 24-42h in the fit.
# "prod" is primary because it is what bin/record_judgments actually emits.
LEAD_BIN = {"prod": "13-24h", "fit": "24-42h"}
SAMPLE_HOURS = [2, 6, 10, 14, 18]
PRIMARY_HOUR = 6
N_BOOT = 5000
RNG = np.random.default_rng(20260805)

PARAMS = json.loads((HERE / "params.json").read_text())["cells"]


# ---------------------------------------------------------------- our model

def t_cdf(z, nu):
    return stats.norm.cdf(z) if nu is None else stats.t.cdf(z, df=nu)


def our_prob(meta, txn, xnd, station, bin_label):
    cell = PARAMS[f"{station}|{bin_label}"]
    mu, sigma, nu = txn + cell["mu"], cell["a"] + cell["b"] * xnd, cell["nu"]
    below = lambda t: t_cdf((t + 0.5 - mu) / sigma, nu)  # noqa: E731  P(H <= t)
    kind = meta["strike_type"]
    if kind == "between":
        return below(int(meta["cap_strike"])) - below(int(meta["floor_strike"]) - 1)
    if kind == "greater":
        return 1.0 - below(int(meta["floor_strike"]))
    if kind == "less":
        return below(int(meta["cap_strike"]) - 1)
    raise ValueError(kind)


# ---------------------------------------------------------------- the book

def quote_at(candles, ts):
    """Last hourly close at or before ts. The book persists between candles;
    Kalshi only emits a candle for hours with activity, so carrying forward is
    the correct read, not an interpolation."""
    best = None
    for c in candles:
        if c["ts"] <= ts and (best is None or c["ts"] > best["ts"]):
            best = c
    if best is None or best["yes_bid"] is None or best["yes_ask"] is None:
        return None
    return float(best["yes_bid"]), float(best["yes_ask"]), best["ts"]


def load_events():
    events = defaultdict(dict)
    for series, station in SERIES.items():
        hist = json.loads((CACHE / f"market_history_{series}.json").read_text())
        for ticker, d in hist.items():
            m = d["meta"]
            date = datetime.strptime(m["event_ticker"].split("-")[1], "%y%b%d").date()
            events[(station, date)][ticker] = d
    return events


def load_forecasts():
    """(station, date) -> (txn, xnd) from the 00Z NBM run on the event date."""
    out = {}
    for station in SERIES.values():
        df = pd.read_csv(HERE / "data" / f"pairs_{station}.csv").drop_duplicates(
            ["local_date", "runtime_utc"])
        for _, r in df.iterrows():
            if r.runtime_utc[11:] != "00:00:00" or r.runtime_utc[:10] != r.local_date:
                continue
            out[(station, pd.Timestamp(r.local_date).date())] = (float(r.txn), float(r.xnd))
    return out


# ---------------------------------------------------------------- assembly

def build(hour, bin_label):
    events, forecasts = load_events(), load_forecasts()
    rows, dropped = [], defaultdict(int)
    for (station, date), legs in sorted(events.items()):
        fc = forecasts.get((station, date))
        if fc is None:
            dropped["no 00Z NBM run"] += 1
            continue
        txn, xnd = fc
        ts = calendar.timegm(datetime(date.year, date.month, date.day, hour).timetuple())

        tickers, ours, bids, asks, prices, y = [], [], [], [], [], []
        ok = True
        for ticker, d in legs.items():
            q = quote_at(d["candles"], ts)
            if q is None:
                ok = False
                break
            bid, ask, _ = q
            tickers.append(ticker)
            bids.append(bid)
            asks.append(ask)
            prices.append((bid + ask) / 2)
            ours.append(our_prob(d["meta"], txn, xnd, station, bin_label))
            y.append(1.0 if d["meta"]["result"] == "yes" else 0.0)
        if not ok:
            dropped["a leg had no quote at or before the sample hour"] += 1
            continue
        if sum(y) != 1:
            dropped["not exactly one YES"] += 1
            continue

        ours = np.array(ours)
        assert abs(ours.sum() - 1) < 1e-6, ours.sum()
        rows.append({
            "station": station, "date": date, "tickers": tickers,
            "txn": txn, "xnd": xnd,
            "ours": ours, "y": np.array(y),
            "mid": np.array(prices), "bid": np.array(bids), "ask": np.array(asks),
            "settled_high": int(float(legs[tickers[0]]["meta"]["expiration_value"])),
        })
    return rows, dropped


def norm(v):
    v = np.clip(np.asarray(v, float), 1e-6, None)
    return v / v.sum()


def metrics(p, y):
    p = np.clip(p, 1e-6, 1 - 1e-6)
    return -math.log(p[y.argmax()]), float(((p - y) ** 2).sum())


def score(rows, market_key):
    out = []
    for r in rows:
        pm = norm(r[market_key])
        lo, bo = metrics(r["ours"], r["y"])
        lm, bm = metrics(pm, r["y"])
        out.append({
            "station": r["station"], "date": r["date"],
            "overround": float(np.sum(r[market_key])),
            "spread": float(np.mean(r["ask"] - r["bid"])),
            "ours_ll": lo, "mkt_ll": lm, "ours_brier": bo, "mkt_brier": bm,
            "ours_modal": float(r["ours"].max()), "mkt_modal": float(pm.max()),
            "ours_p_true": float(r["ours"][r["y"].argmax()]),
            "mkt_p_true": float(pm[r["y"].argmax()]),
        })
    return pd.DataFrame(out)


def block_bootstrap(df, col_a, col_b):
    """Resample whole DATES (all stations for a date move together)."""
    dates = df.date.unique()
    by_date = {d: (g[col_a].values - g[col_b].values) for d, g in df.groupby("date")}
    obs = np.concatenate(list(by_date.values())).mean()
    draws = np.empty(N_BOOT)
    keys = list(by_date)
    for i in range(N_BOOT):
        pick = RNG.integers(0, len(keys), len(keys))
        draws[i] = np.concatenate([by_date[keys[j]] for j in pick]).mean()
    lo, hi = np.percentile(draws, [2.5, 97.5])
    return obs, lo, hi, len(dates)


# ---------------------------------------------------------------- reporting

def fmt(x, n=4):
    return "n/a" if x is None else f"{x:.{n}f}"


def main():
    lines = []

    def say(s=""):
        print(s)
        lines.append(s)

    rows, dropped = build(PRIMARY_HOUR, LEAD_BIN["prod"])
    say(f"# Our distribution vs the market's — {PRIMARY_HOUR:02d}Z sample, "
        f"lead bin {LEAD_BIN['prod']} (production cell)")
    say()
    say(f"paired observations (station-days): {len(rows)}")
    say(f"dates: {len({r['date'] for r in rows})}  "
        f"stations: {sorted({r['station'] for r in rows})}")
    for k, v in dropped.items():
        say(f"dropped {v}: {k}")
    say()

    df = score(rows, "mid")
    say(f"mean strip overround before renormalising: {df.overround.mean():.4f} "
        f"(median {df.overround.median():.4f})")
    say(f"mean per-leg bid/ask spread: {df.spread.mean() * 100:.2f}c")
    say()

    say("## Multiclass scores over the 6-leg strip (lower is better)")
    say()
    say("| slice | n | ours log-loss | market log-loss | ours Brier | market Brier |")
    say("|---|---|---|---|---|---|")
    say(f"| ALL | {len(df)} | {fmt(df.ours_ll.mean())} | {fmt(df.mkt_ll.mean())} | "
        f"{fmt(df.ours_brier.mean())} | {fmt(df.mkt_brier.mean())} |")
    for st, g in df.groupby("station"):
        say(f"| {st} | {len(g)} | {fmt(g.ours_ll.mean())} | {fmt(g.mkt_ll.mean())} | "
            f"{fmt(g.ours_brier.mean())} | {fmt(g.mkt_brier.mean())} |")
    say(f"| chance (1/6) | - | 1.7918 | 1.7918 | 0.8333 | 0.8333 |")
    say()

    say("## Paired difference, ours minus market (negative = we win)")
    say()
    say("| slice | n | d log-loss | 95% CI (date block bootstrap) | d Brier | 95% CI | "
        "days we score better |")
    say("|---|---|---|---|---|---|---|")
    for label, g in [("ALL", df)] + sorted(df.groupby("station"), key=lambda x: x[0]):
        d1, l1, h1, nd = block_bootstrap(g, "ours_ll", "mkt_ll")
        d2, l2, h2, _ = block_bootstrap(g, "ours_brier", "mkt_brier")
        win = (g.ours_ll < g.mkt_ll).mean()
        say(f"| {label} | {len(g)} | {d1:+.4f} | [{l1:+.4f}, {h1:+.4f}] | {d2:+.4f} | "
            f"[{l2:+.4f}, {h2:+.4f}] | {win * 100:.0f}% |")
    say()

    say("## Robustness: which side of the book, and which lead cell")
    say()
    say("| market price used | lead cell | n | ours LL | market LL | d LL | 95% CI |")
    say("|---|---|---|---|---|---|---|")
    for key, label in [("mid", "mid (primary)"), ("bid", "bid side"), ("ask", "ask side")]:
        g = score(rows, key)
        d, lo, hi, _ = block_bootstrap(g, "ours_ll", "mkt_ll")
        say(f"| {label} | {LEAD_BIN['prod']} | {len(g)} | {fmt(g.ours_ll.mean())} | "
            f"{fmt(g.mkt_ll.mean())} | {d:+.4f} | [{lo:+.4f}, {hi:+.4f}] |")
    rows_fit, _ = build(PRIMARY_HOUR, LEAD_BIN["fit"])
    g = score(rows_fit, "mid")
    d, lo, hi, _ = block_bootstrap(g, "ours_ll", "mkt_ll")
    say(f"| mid | {LEAD_BIN['fit']} | {len(g)} | {fmt(g.ours_ll.mean())} | "
        f"{fmt(g.mkt_ll.mean())} | {d:+.4f} | [{lo:+.4f}, {hi:+.4f}] |")
    say()

    say("## Same comparison through the day (market gains intraday info, we do not)")
    say()
    say("| sample hour UTC | n | ours LL | market LL | d LL | 95% CI | ours Brier | market Brier |")
    say("|---|---|---|---|---|---|---|---|")
    for hour in SAMPLE_HOURS:
        rs, _ = build(hour, LEAD_BIN["prod"])
        g = score(rs, "mid")
        d, lo, hi, _ = block_bootstrap(g, "ours_ll", "mkt_ll")
        say(f"| {hour:02d}Z | {len(g)} | {fmt(g.ours_ll.mean())} | {fmt(g.mkt_ll.mean())} | "
            f"{d:+.4f} | [{lo:+.4f}, {hi:+.4f}] | {fmt(g.ours_brier.mean())} | "
            f"{fmt(g.mkt_brier.mean())} |")
    say()

    say("## Calibration of the modal bucket, both sides (settlement check)")
    say()
    say("| slice | n | our mean modal p | our modal hit rate | market mean modal p | "
        "market modal hit rate |")
    say("|---|---|---|---|---|---|")
    for label, idx in [("ALL", df.index)] + [(st, g.index) for st, g in df.groupby("station")]:
        sub = [rows[i] for i in idx]
        om = np.array([r["ours"].max() for r in sub])
        oh = np.array([r["y"][r["ours"].argmax()] for r in sub])
        mm = np.array([norm(r["mid"]).max() for r in sub])
        mh = np.array([r["y"][norm(r["mid"]).argmax()] for r in sub])
        say(f"| {label} | {len(sub)} | {om.mean():.3f} | {oh.mean():.3f} | "
            f"{mm.mean():.3f} | {mh.mean():.3f} |")
    say()

    detail = score(rows, "mid")
    detail.to_csv(HERE / "market_vs_model_scores.csv", index=False)
    (HERE / "MARKET_SCORING.md").write_text("\n".join(lines) + "\n")
    say(f"wrote market_vs_model_scores.csv ({len(detail)} rows) and MARKET_SCORING.md")


if __name__ == "__main__":
    main()
