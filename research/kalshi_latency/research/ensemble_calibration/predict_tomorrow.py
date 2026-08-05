#!/usr/bin/env python3
"""Produce Kalshi bucket probabilities for a station from the latest NBM NBE run.

Usage: predict_tomorrow.py [KNYC] [KXHIGHNY]

Pulls the latest NBE run from the IEM archive, applies the fitted error model
in params.json, prints P(bucket) for every open Kalshi market in the series,
alongside current market quotes (public endpoint, GET-only, no auth).
"""

import json
import re
import sys
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from scipy import stats

STATION = sys.argv[1] if len(sys.argv) > 1 else "KNYC"
SERIES = sys.argv[2] if len(sys.argv) > 2 else "KXHIGHNY"
TZ = {"KNYC": "America/New_York", "KMIA": "America/New_York",
      "KDEN": "America/Denver", "KAUS": "America/Chicago"}[STATION]

PARAMS = json.loads((Path(__file__).parent / "params.json").read_text())


def get_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "kalshi-calibration-research"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


def latest_nbe():
    now = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    for back in range(0, 30):
        rt = (now - timedelta(hours=back)).strftime("%Y-%m-%dT%H:00:00Z")
        try:
            d = get_json(f"https://mesonet.agron.iastate.edu/api/1/mos.json?station={STATION}&model=NBE&runtime={rt}")
        except urllib.error.HTTPError:
            continue  # archive 404s on runtimes it has not ingested
        if d.get("data"):
            return d["data"]
    raise SystemExit("no recent NBE run found")


def forecast_for(rows, local_date):
    """(txn, xnd, lead_hours) for the daytime max of local_date."""
    tz = ZoneInfo(TZ)
    for r in rows:
        ft = datetime.fromisoformat(r["ftime_utc"]).replace(tzinfo=timezone.utc)
        if ft.hour != 0 or r.get("txn") is None:
            continue
        if ft.astimezone(tz).date().isoformat() == local_date:
            rt = datetime.fromisoformat(r["runtime_utc"]).replace(tzinfo=timezone.utc)
            return r["txn"], r["xnd"], (ft - rt).total_seconds() / 3600, r["runtime_utc"]
    return None


def cell_params(lead_hours):
    for lo, hi, label in PARAMS["lead_bins"]:
        if lo <= lead_hours < hi:
            return PARAMS["cells"][f"{STATION}|{label}"], label
    # outside fitted range: use widest bin
    label = PARAMS["lead_bins"][-1][2]
    return PARAMS["cells"][f"{STATION}|{label}"], f"{label} (extrapolated)"


def pmf(txn, xnd, p):
    dist = stats.norm if p["nu"] is None else stats.t(df=p["nu"])
    mu, sigma = txn + p["mu"], p["a"] + p["b"] * xnd
    def cdf(x):
        return dist.cdf((x - mu) / sigma)
    return {t: cdf(t + 0.5) - cdf(t - 0.5) for t in range(int(txn) - 15, int(txn) + 16)}, sigma


def bucket_prob(ticker, probs):
    """Handoff rules: B{x}.5 floor/cap BOTH inclusive; T greater floor EXCLUSIVE;
    T less cap EXCLUSIVE."""
    m = re.search(r"-(B|T)([\d.]+)$", ticker)
    kind, strike = m.group(1), float(m.group(2))
    if kind == "B":
        lo, hi = int(strike - 0.5), int(strike + 0.5)
        return sum(p for t, p in probs.items() if lo <= t <= hi)
    return None  # T markets disambiguated by title, handled below


def main():
    rows = latest_nbe()
    tz = ZoneInfo(TZ)
    markets = get_json(
        f"https://api.elections.kalshi.com/trade-api/v2/markets?series_ticker={SERIES}&status=open&limit=100"
    )["markets"]
    by_date = {}
    for m in markets:
        d = re.search(r"-(\d\d[A-Z]{3}\d\d)-", m["ticker"]).group(1)
        by_date.setdefault(d, []).append(m)

    for datecode, ms in sorted(by_date.items()):
        local_date = datetime.strptime(datecode, "%y%b%d").date().isoformat()
        fc = forecast_for(rows, local_date)
        if fc is None:
            print(f"\n{local_date}: no NBE daytime-max row in latest run")
            continue
        txn, xnd, lead, runtime = fc
        p, label = cell_params(lead)
        probs, sigma = pmf(txn, xnd, p)
        print(f"\n=== {SERIES} {local_date} | NBE run {runtime}Z lead {lead:.0f}h ({label}) ===")
        print(f"    txn={txn}F xnd={xnd} -> mu={txn + p['mu']:.1f} sigma={sigma:.2f} "
              f"t_df={p['nu'] or 'inf'}")
        print(f"    {'ticker':34s} {'ours':>6s} {'yes_bid':>7s} {'yes_ask':>7s}  title")
        for m in sorted(ms, key=lambda x: x["ticker"]):
            t = m["ticker"]
            pb = bucket_prob(t, probs)
            if pb is None:
                strike = float(re.search(r"-T([\d.]+)$", t).group(1))
                title = (m.get("subtitle") or m.get("title") or "")
                if "below" in title:
                    pb = sum(v for k, v in probs.items() if k <= strike - 1)
                else:
                    pb = sum(v for k, v in probs.items() if k >= strike + 1)
            bid = float(m.get("yes_bid_dollars") or 0) * 100
            ask = float(m.get("yes_ask_dollars") or 0) * 100
            print(f"    {t:34s} {pb*100:5.1f}c {bid:6.0f}c {ask:6.0f}c  "
                  f"{m.get('subtitle') or m.get('title')}")


if __name__ == "__main__":
    main()
