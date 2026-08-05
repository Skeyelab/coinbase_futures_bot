#!/usr/bin/env python3
"""Fit per-station forecast-error distributions for NBM daily-high forecasts.

Model (deliberately small, portable to stdlib Ruby):

    error e = cli_high - txn                    (whole degrees F)
    e ~ mu(station, lead_bin) + sigma_i * T_nu
    sigma_i = a(station, lead_bin) + b(station, lead_bin) * xnd_i

  - mu: additive bias, fit as the mean error
  - sigma_i: scale, linear in the NBM ensemble spread (xnd); b=0 recovers a
    constant-sigma model
  - T_nu: Student-t with fixed df from a small grid (heavier tails than
    normal; nu=inf is normal). Chosen by held-out log score, not in-sample.

Probability of an integer high t:  F((t+0.5-txn-mu)/sigma) - F((t-0.5-txn-mu)/sigma)

Evaluation: train on local_date < 2026-01-01, test on 2026. Score = mean log
probability assigned to the settled integer high (discrete log score). Compared
against a "market proxy" strawman: a normal centered on txn with sigma = 3.

Outputs params.json consumed by predict_tomorrow.py.
"""

import json
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import stats, optimize

DATA = Path(__file__).parent / "data"
LEAD_BINS = [(13, 24, "13-24h"), (24, 42, "24-42h"), (42, 66, "42-66h")]
DF_GRID = [3, 5, 8, 15, np.inf]
TRAIN_END = "2026-01-01"


def tdist(nu):
    return stats.norm if np.isinf(nu) else stats.t(df=nu)


def discrete_logscore(e, mu, sigma, nu):
    d = tdist(nu)
    p = d.cdf((e + 0.5 - mu) / sigma) - d.cdf((e - 0.5 - mu) / sigma)
    return np.log(np.clip(p, 1e-12, None))


def neg_ll(params, e, xnd, nu):
    mu, a, b = params
    sigma = a + b * xnd
    if np.any(sigma <= 0.05):
        return 1e9
    return -discrete_logscore(e, mu, sigma, nu).sum()


def fit_cell(train):
    e = train.err.values.astype(float)
    xnd = train.xnd.values.astype(float)
    best = None
    for nu in DF_GRID:
        # constant sigma (b=0) and spread-scaled starts
        for x0 in ([e.mean(), e.std() + 0.5, 0.0], [e.mean(), 1.0, 0.8]):
            r = optimize.minimize(neg_ll, x0, args=(e, xnd, nu), method="Nelder-Mead",
                                  options={"xatol": 1e-4, "fatol": 1e-6, "maxiter": 4000})
            cand = {"mu": r.x[0], "a": r.x[1], "b": r.x[2], "nu": None if np.isinf(nu) else nu,
                    "train_nll": r.fun}
            if best is None or cand["train_nll"] < best["train_nll"]:
                best = cand
    return best


def cell_scores(test, p):
    nu = np.inf if p["nu"] is None else p["nu"]
    e = test.err.values.astype(float)
    xnd = test.xnd.values.astype(float)
    model = discrete_logscore(e, p["mu"], p["a"] + p["b"] * xnd, nu).mean()
    strawman = discrete_logscore(e, 0.0, np.full_like(e, 3.0), np.inf).mean()
    return model, strawman


def main():
    out = {}
    rows = []
    for f in sorted(DATA.glob("pairs_*.csv")):
        station = f.stem.split("_")[1]
        df = pd.read_csv(f)
        df["err"] = df.cli_high - df.txn
        for lo, hi, label in LEAD_BINS:
            cell = df[(df.lead_hours >= lo) & (df.lead_hours < hi)]
            # dedupe: one run per day per bin (latest runtime) — hourly runs of
            # the same cycle are near-duplicates and would fake a larger n
            cell = (cell.sort_values("runtime_utc")
                        .groupby("local_date").tail(1))
            train = cell[cell.local_date < TRAIN_END]
            test = cell[cell.local_date >= TRAIN_END]
            p = fit_cell(train)
            m, s = cell_scores(test, p)
            stats_row = {
                "station": station, "lead": label,
                "n_train": len(train), "n_test": len(test),
                "bias_mu": round(p["mu"], 2), "sigma_a": round(p["a"], 2),
                "sigma_b_xnd": round(p["b"], 2), "t_df": p["nu"],
                "err_mean": round(train.err.mean(), 2), "err_sd": round(train.err.std(), 2),
                "err_p05": train.err.quantile(0.05), "err_p95": train.err.quantile(0.95),
                "abs_err_le1_pct": round((train.err.abs() <= 1).mean() * 100, 1),
                "xnd_abs_err_corr": round(np.corrcoef(train.xnd, train.err.abs())[0, 1], 3),
                "test_logscore_model": round(m, 4), "test_logscore_sigma3_normal": round(s, 4),
            }
            rows.append(stats_row)
            out[f"{station}|{label}"] = {k: p[k] for k in ("mu", "a", "b", "nu")}
    table = pd.DataFrame(rows)
    print(table.to_string(index=False))
    (Path(__file__).parent / "params.json").write_text(json.dumps(
        {"lead_bins": [[lo, hi, lb] for lo, hi, lb in LEAD_BINS], "cells": out}, indent=2))
    table.to_csv(Path(__file__).parent / "fit_stats.csv", index=False)
    print("\nwrote params.json, fit_stats.csv")


if __name__ == "__main__":
    main()
