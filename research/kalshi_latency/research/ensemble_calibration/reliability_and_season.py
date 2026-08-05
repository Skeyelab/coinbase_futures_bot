#!/usr/bin/env python3
"""Two follow-ups to the market comparison.

A. RELIABILITY. 292 station-days x 6 legs = 1752 binary legs. Bin them by the
   probability each side assigned and compare to how often the leg actually
   settled YES. This is the direct test of the report's thesis: if the market
   really starves the tails, its low-probability bins should settle YES more
   often than it charged.

B. IS THE GAP JUST SEASONALITY? Report limitation #2 predicted a pooled
   year-round sigma would be over-dispersed in summer, and the comparison
   window is 24 May - 4 Aug. So refit the SAME model on summer months only
   (May-Aug, still train<2026 so the window stays out of sample) and rescore.
   This is a diagnostic on the size of the known defect, not a proposal.
"""

import json
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import optimize, stats

from score_vs_market import (LEAD_BIN, PRIMARY_HOUR, block_bootstrap, build,
                             metrics, norm, our_prob)

HERE = Path(__file__).parent
SERIES = {"KXHIGHNY": "KNYC", "KXHIGHMIA": "KMIA",
          "KXHIGHDEN": "KDEN", "KXHIGHAUS": "KAUS"}
DF_GRID = [3, 5, 8, 15, np.inf]
SUMMER = {5, 6, 7, 8}


def logscore(e, mu, sigma, nu):
    d = stats.norm if np.isinf(nu) else stats.t(df=nu)
    p = d.cdf((e + 0.5 - mu) / sigma) - d.cdf((e - 0.5 - mu) / sigma)
    return np.log(np.clip(p, 1e-12, None))


def fit(e, xnd):
    def nll(par, nu):
        mu, a, b = par
        s = a + b * xnd
        return 1e9 if np.any(s <= 0.05) else -logscore(e, mu, s, nu).sum()

    best = None
    for nu in DF_GRID:
        for x0 in ([e.mean(), e.std() + 0.5, 0.0], [e.mean(), 1.0, 0.8]):
            r = optimize.minimize(nll, x0, args=(nu,), method="Nelder-Mead",
                                  options={"xatol": 1e-4, "fatol": 1e-6, "maxiter": 4000})
            c = {"mu": r.x[0], "a": r.x[1], "b": r.x[2],
                 "nu": None if np.isinf(nu) else nu, "nll": r.fun}
            if best is None or c["nll"] < best["nll"]:
                best = c
    return best


def summer_params():
    """Refit the production lead cell (13 < lead <= 24) on May-Aug, pre-2026."""
    out = {}
    for station in SERIES.values():
        df = pd.read_csv(HERE / "data" / f"pairs_{station}.csv").drop_duplicates(
            ["local_date", "runtime_utc"])
        cell = df[(df.lead_hours > 13) & (df.lead_hours <= 24)]
        cell = cell.sort_values("runtime_utc").groupby("local_date").tail(1)
        month = pd.to_datetime(cell.local_date).dt.month
        train = cell[(cell.local_date < "2026-01-01") & month.isin(SUMMER).values]
        p = fit((train.cli_high - train.txn).values.astype(float),
                train.xnd.values.astype(float))
        p["n_train"] = len(train)
        out[f"{station}|{LEAD_BIN['prod']}"] = p
    return out


def main():
    rows, _ = build(PRIMARY_HOUR, LEAD_BIN["prod"])
    lines = []

    def say(s=""):
        print(s)
        lines.append(s)

    # ---------------------------------------------------------------- A
    legs = []
    for r in rows:
        pm = norm(r["mid"])
        for i in range(len(r["tickers"])):
            legs.append({"station": r["station"], "ours": r["ours"][i],
                         "mkt": pm[i], "y": r["y"][i]})
    L = pd.DataFrame(legs)
    edges = [0, 0.02, 0.05, 0.10, 0.20, 0.35, 0.50, 0.70, 1.01]

    say(f"# Reliability and seasonality ({len(rows)} station-days, "
        f"{len(L)} legs, {PRIMARY_HOUR:02d}Z)")
    say()
    say("## A. Reliability by assigned probability")
    say()
    say("Every leg of every strip, binned by the probability each side gave it, "
        "against how often that leg actually settled YES. Perfect calibration is "
        "`settled` equal to `mean p` inside every bin.")
    say()
    say("| p bin | our legs | our mean p | our settled | market legs | "
        "market mean p | market settled |")
    say("|---|---|---|---|---|---|---|")
    for lo, hi in zip(edges, edges[1:]):
        a = L[(L.ours >= lo) & (L.ours < hi)]
        b = L[(L.mkt >= lo) & (L.mkt < hi)]
        say(f"| {lo:.2f}-{min(hi, 1.0):.2f} | {len(a)} | "
            f"{a.ours.mean():.3f} | {a.y.mean():.3f} | {len(b)} | "
            f"{b.mkt.mean():.3f} | {b.y.mean():.3f} |"
            if len(a) and len(b) else
            f"| {lo:.2f}-{min(hi, 1.0):.2f} | {len(a)} | - | - | {len(b)} | - | - |")
    say()
    say("Aggregate leg Brier (binary, lower is better): "
        f"ours {((L.ours - L.y) ** 2).mean():.4f}, market {((L.mkt - L.y) ** 2).mean():.4f}")
    say()

    # ---------------------------------------------------------------- B
    sp = summer_params()
    say("## B. Refit on summer only (May-Aug, train < 2026) — is the gap seasonal?")
    say()
    say("| station | n_train | pooled mu / a / b / df | summer mu / a / b / df |")
    say("|---|---|---|---|")
    pooled = json.loads((HERE / "params.json").read_text())["cells"]
    for station in sorted(SERIES.values()):
        k = f"{station}|{LEAD_BIN['prod']}"
        p, q = pooled[k], sp[k]
        say(f"| {station} | {q['n_train']} | {p['mu']:+.2f} / {p['a']:.2f} / "
            f"{p['b']:.2f} / {p['nu'] or 'norm'} | {q['mu']:+.2f} / {q['a']:.2f} / "
            f"{q['b']:.2f} / {q['nu'] or 'norm'} |")
    say()

    # Rebuild with the summer cells swapped in, so the bucket-bound rules and
    # every other step stay byte-identical between the two runs.
    import score_vs_market as S
    saved = dict(S.PARAMS)
    S.PARAMS.update({k: {kk: v[kk] for kk in ("mu", "a", "b", "nu")} for k, v in sp.items()})
    rows_s, _ = build(PRIMARY_HOUR, LEAD_BIN["prod"])
    S.PARAMS.clear()
    S.PARAMS.update(saved)

    g0 = S.score(rows, "mid")
    g1 = S.score(rows_s, "mid")
    d0, l0, h0, _ = block_bootstrap(g0, "ours_ll", "mkt_ll")
    d1, l1, h1, _ = block_bootstrap(g1, "ours_ll", "mkt_ll")
    say("| model | n | ours LL | market LL | d LL | 95% CI | ours Brier | market Brier |")
    say("|---|---|---|---|---|---|---|---|")
    say(f"| pooled year-round (shipped) | {len(g0)} | {g0.ours_ll.mean():.4f} | "
        f"{g0.mkt_ll.mean():.4f} | {d0:+.4f} | [{l0:+.4f}, {h0:+.4f}] | "
        f"{g0.ours_brier.mean():.4f} | {g0.mkt_brier.mean():.4f} |")
    say(f"| summer-only refit | {len(g1)} | {g1.ours_ll.mean():.4f} | "
        f"{g1.mkt_ll.mean():.4f} | {d1:+.4f} | [{l1:+.4f}, {h1:+.4f}] | "
        f"{g1.ours_brier.mean():.4f} | {g1.mkt_brier.mean():.4f} |")
    say()
    (HERE / "MARKET_SCORING_RELIABILITY.md").write_text("\n".join(lines) + "\n")
    say("wrote MARKET_SCORING_RELIABILITY.md")


if __name__ == "__main__":
    main()
