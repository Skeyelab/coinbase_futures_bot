#!/usr/bin/env python3
"""Fetch NBM NBE forecasts (IEM MOS archive) + settled CLI highs (IEM CLI archive).

Produces one CSV per station of (forecast, actual) pairs:
    station, local_date, runtime_utc, ftime_utc, lead_hours, txn, xnd, cli_high

Sources (both free, no key):
  https://mesonet.agron.iastate.edu/cgi-bin/request/mos.py   (NBE bulk CSV)
  https://mesonet.agron.iastate.edu/json/cli.py              (parsed CLI reports)

The X/N convention: NBE rows with ftime at 00Z carry the DAYTIME MAX (txn) for
the local calendar date containing that valid time (00Z is late
afternoon/evening local everywhere in CONUS). Rows at 12Z carry the overnight
min — excluded here. xnd is the NBM ensemble standard deviation of txn.

CLI `high` is parsed from the same NWS Climatological Report product that
Kalshi settles on. Zero basis risk on the target.
"""

import csv
import io
import json
import sys
import urllib.request
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
from pathlib import Path

STATIONS = {
    "KNYC": "America/New_York",
    "KMIA": "America/New_York",
    "KDEN": "America/Denver",
    "KAUS": "America/Chicago",
}
START = "2023-01-01"
END = "2026-08-05"
YEARS = range(2023, 2027)

OUT_DIR = Path(__file__).parent / "data"
CACHE = Path(sys.argv[1]) if len(sys.argv) > 1 else OUT_DIR / "cache"


def get(url: str, cache_key: str) -> str:
    CACHE.mkdir(parents=True, exist_ok=True)
    f = CACHE / cache_key
    if f.exists():
        return f.read_text()
    req = urllib.request.Request(url, headers={"User-Agent": "kalshi-calibration-research"})
    with urllib.request.urlopen(req, timeout=180) as r:
        body = r.read().decode()
    f.write_text(body)
    return body


def fetch_cli(station: str) -> dict:
    """local_date -> settled CLI high (int, whole deg F)."""
    highs = {}
    for year in YEARS:
        body = get(
            f"https://mesonet.agron.iastate.edu/json/cli.py?station={station}&year={year}",
            f"cli_{station}_{year}.json",
        )
        for row in json.loads(body)["results"]:
            h = row.get("high")
            if isinstance(h, int):
                highs[row["valid"]] = h
    return highs


def fetch_nbe(station: str) -> list[dict]:
    url = (
        "https://mesonet.agron.iastate.edu/cgi-bin/request/mos.py"
        f"?station={station}&model=NBE&sts={START}T00:00Z&ets={END}T00:00Z&format=csv"
    )
    body = get(url, f"nbe_{station}.csv")
    return list(csv.DictReader(io.StringIO(body)))


def build_pairs(station: str, tz_name: str) -> list[dict]:
    tz = ZoneInfo(tz_name)
    highs = fetch_cli(station)
    pairs = []
    for row in fetch_nbe(station):
        if not row.get("txn"):
            continue
        ftime = datetime.strptime(row["ftime"], "%Y-%m-%d %H:%M:%S").replace(tzinfo=ZoneInfo("UTC"))
        if ftime.hour != 0:
            continue  # 12Z rows are overnight mins
        runtime = datetime.strptime(row["runtime"], "%Y-%m-%d %H:%M:%S").replace(tzinfo=ZoneInfo("UTC"))
        local_date = ftime.astimezone(tz).date().isoformat()
        actual = highs.get(local_date)
        if actual is None:
            continue
        lead = (ftime - runtime).total_seconds() / 3600
        pairs.append({
            "station": station,
            "local_date": local_date,
            "runtime_utc": row["runtime"],
            "ftime_utc": row["ftime"],
            "lead_hours": round(lead),
            "txn": int(float(row["txn"])),
            "xnd": int(float(row["xnd"])) if row.get("xnd") else "",
            "cli_high": actual,
        })
    return pairs


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for station, tz_name in STATIONS.items():
        pairs = build_pairs(station, tz_name)
        out = OUT_DIR / f"pairs_{station}.csv"
        with out.open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(pairs[0].keys()))
            w.writeheader()
            w.writerows(pairs)
        print(f"{station}: {len(pairs)} forecast/actual pairs -> {out}")


if __name__ == "__main__":
    main()
