#!/usr/bin/env python3
"""Pull Kalshi's own settled history for the four fitted daily-high series.

Two public GET endpoints, no credentials, no order path:

  GET /markets?series_ticker=..&status=settled   -> the settled bucket strips,
      with strike bounds, `result` (yes/no) and `expiration_value` (the settled
      high Kalshi used). Retention is a rolling window: at the time of writing
      it reaches back 73 days, no further. Older event tickers still resolve
      but return zero markets.

  GET /series/{s}/markets/{t}/candlesticks       -> hourly yes_bid / yes_ask
      closes for the whole life of each market. This is what lets us read the
      book at a FIXED hour on the event day rather than at settlement.

On the bid-ladder trap: Kalshi's raw book has two BID ladders (yes and no).
The `yes_ask` these endpoints report is the derived YES offer, i.e. 1 - no_bid.
Verified on live markets: yes_ask_dollars + no_bid_dollars == 1.0000 exactly on
every quote checked. So `yes_ask` here is a real offer, not a NO bid misread as
one, and (yes_bid, yes_ask) is a genuine two-sided YES quote.

Writes data/cache/market_history_<SERIES>.json:
    {ticker: {"meta": {...}, "candles": [{ts, yes_bid, yes_ask, price, volume}]}}
data/ is gitignored; this is a cache, re-runnable.
"""

import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

BASE = "https://api.elections.kalshi.com/trade-api/v2"
SERIES = ["KXHIGHNY", "KXHIGHMIA", "KXHIGHDEN", "KXHIGHAUS"]
CACHE = Path(__file__).parent / "data" / "cache"

META_KEYS = ("ticker", "event_ticker", "status", "result", "expiration_value",
             "strike_type", "floor_strike", "cap_strike", "subtitle",
             "open_time", "close_time", "volume_fp", "last_price_dollars")


def get(path, **params):
    url = BASE + path + ("?" + urllib.parse.urlencode(params) if params else "")
    for attempt in range(6):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "kalshi-calibration-research"})
            with urllib.request.urlopen(req, timeout=45) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(2 ** attempt)
                continue
            raise
        except Exception:
            if attempt == 5:
                raise
            time.sleep(2 ** attempt)


def settled_markets(series):
    rows, cursor, pages = [], None, 0
    while True:
        p = dict(series_ticker=series, status="settled", limit=1000)
        if cursor:
            p["cursor"] = cursor
        body = get("/markets", **p)
        ms = body.get("markets") or []
        rows.extend({k: m.get(k) for k in META_KEYS} for m in ms)
        cursor, pages = body.get("cursor"), pages + 1
        if not cursor or not ms or pages > 50:
            break
    return rows


def epoch(iso):
    return int(datetime.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S")
               .replace(tzinfo=timezone.utc).timestamp())


def candles(series, meta):
    body = get(f"/series/{series}/markets/{meta['ticker']}/candlesticks",
               start_ts=epoch(meta["open_time"]) - 3600,
               end_ts=epoch(meta["close_time"]) + 3600,
               period_interval=60)
    out = []
    for c in body.get("candlesticks") or []:
        yb, ya = c.get("yes_bid") or {}, c.get("yes_ask") or {}
        out.append({
            "ts": c["end_period_ts"],
            "yes_bid": yb.get("close_dollars"),
            "yes_ask": ya.get("close_dollars"),
            "price": (c.get("price") or {}).get("close_dollars"),
            "volume": c.get("volume_fp"),
        })
    return out


def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    for series in SERIES:
        out_path = CACHE / f"market_history_{series}.json"
        have = json.loads(out_path.read_text()) if out_path.exists() else {}
        metas = settled_markets(series)
        print(f"{series}: {len(metas)} settled markets ({len(have)} cached)", flush=True)
        for i, meta in enumerate(metas, 1):
            t = meta["ticker"]
            if t in have and have[t].get("candles"):
                continue
            have[t] = {"meta": meta, "candles": candles(series, meta)}
            if i % 50 == 0:
                out_path.write_text(json.dumps(have))
                print(f"  {i}/{len(metas)}", flush=True)
            time.sleep(0.12)
        out_path.write_text(json.dumps(have))
        print(f"  wrote {out_path} ({len(have)} markets)", flush=True)


if __name__ == "__main__":
    sys.exit(main())
