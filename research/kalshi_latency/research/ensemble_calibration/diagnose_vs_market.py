#!/usr/bin/env python3
"""Where the loss to the market comes from, and whether the tail hypothesis holds.

Companion to score_vs_market.py. Same 292 station-days, same 06Z sample.
Four questions:

  1. LOCATION vs DISPERSION. Is our distribution centred wrong, or is it the
     right centre with the wrong width? Compares the mean/sd implied by each
     distribution against the settled high.
  2. THE TAIL HYPOTHESIS. The report's thesis was that the market piles onto
     the point-forecast bucket and starves the tails. That is testable: how
     often did the two outer legs actually settle YES, and what did each side
     charge for them?
  3. THE SPREAD FEATURE. The edge, if it exists, should be concentrated on
     high-xnd days where the ensemble disagrees. Scored by xnd tercile.
  4. WOULD IT HAVE LOST MONEY? The paper trade `Judgment.paper_trade` would
     have taken -- buy the ask when our fair exceeds it, sell the bid when
     ours is below -- with the per-ORDER fee ceil(0.07*n*p*(1-p)), settled
     against the real result. Secondary to the scoring, but it is the number
     the funding gate actually cares about.
"""

import math
from pathlib import Path

import numpy as np
import pandas as pd

from score_vs_market import build, norm, LEAD_BIN, PRIMARY_HOUR

HERE = Path(__file__).parent
CONTRACTS = 100


def moments(p, centres):
    m = float((p * centres).sum())
    return m, math.sqrt(float((p * (centres - m) ** 2).sum()))


def leg_centres(tickers, metas):
    """Representative degree for each leg, for mean/sd bookkeeping only."""
    out = []
    for t in tickers:
        m = metas[t]
        if m["strike_type"] == "between":
            out.append((int(m["floor_strike"]) + int(m["cap_strike"])) / 2)
        elif m["strike_type"] == "greater":
            out.append(int(m["floor_strike"]) + 2.0)
        else:
            out.append(int(m["cap_strike"]) - 2.0)
    return np.array(out)


def fee_cents(price_cents, contracts):
    """Kalshi's per-ORDER fee: ceil(0.07 * n * p * (1-p)), p in dollars.
    round(6) before ceil or float error turns 175.0 into 175.0000000000003."""
    p = price_cents / 100.0
    return math.ceil(round(0.07 * contracts * p * (1 - p), 6))


def paper_trade(prob, bid_c, ask_c, contracts):
    fair = prob * 100
    if fair > ask_c:
        side, price, edge = "buy", ask_c, fair - ask_c
    elif fair < bid_c:
        side, price, edge = "sell", bid_c, bid_c - fair
    else:
        return None
    ev = round(edge * contracts) - fee_cents(price, contracts)
    return None if ev <= 0 else (side, price, ev)


def settle(side, price, contracts, settled_yes):
    fee = fee_cents(price, contracts)
    won = (side == "buy") == settled_yes
    if side == "buy":
        gross = (100 - price) * contracts if won else -price * contracts
    else:
        gross = price * contracts if won else -(100 - price) * contracts
    return gross - fee


def main():
    rows, _ = build(PRIMARY_HOUR, LEAD_BIN["prod"])
    import json
    metas = {}
    for series in ["KXHIGHNY", "KXHIGHMIA", "KXHIGHDEN", "KXHIGHAUS"]:
        h = json.loads((HERE / "data" / "cache" / f"market_history_{series}.json").read_text())
        for t, d in h.items():
            metas[t] = d["meta"]

    recs = []
    for r in rows:
        c = leg_centres(r["tickers"], metas)
        pm = norm(r["mid"])
        om, osd = moments(r["ours"], c)
        mm, msd = moments(pm, c)
        truth = float(c[r["y"].argmax()])
        # which legs are the outer tails
        kinds = [metas[t]["strike_type"] for t in r["tickers"]]
        tail = np.array([k in ("greater", "less") for k in kinds])
        recs.append({
            "station": r["station"], "date": r["date"], "xnd": r["xnd"],
            "settled_high": r["settled_high"],
            "our_mean": om, "our_sd": osd, "mkt_mean": mm, "mkt_sd": msd,
            "truth_centre": truth,
            "our_loc_err": om - truth, "mkt_loc_err": mm - truth,
            "our_tail_p": float(r["ours"][tail].sum()),
            "mkt_tail_p": float(pm[tail].sum()),
            "tail_settled": float(r["y"][tail].sum()),
            "our_modal": int(r["ours"].argmax()), "mkt_modal": int(pm.argmax()),
            "true_leg": int(r["y"].argmax()),
        })
    d = pd.DataFrame(recs)

    lines = []

    def say(s=""):
        print(s)
        lines.append(s)

    say(f"# Diagnostics — why the market wins ({len(d)} station-days, {PRIMARY_HOUR:02d}Z)")
    say()
    say("## 1. Location vs dispersion")
    say()
    say("Both distributions summarised by the mean and sd they imply over the 6 legs "
        "(legs represented by their centre degree; the two tails by centre+/-2, so the "
        "sd is a floor, not exact).")
    say()
    say("| slice | n | our mean err | market mean err | our |err| | market |err| | "
        "our implied sd | market implied sd |")
    say("|---|---|---|---|---|---|---|---|")
    for label, g in [("ALL", d)] + sorted(d.groupby("station"), key=lambda x: x[0]):
        say(f"| {label} | {len(g)} | {g.our_loc_err.mean():+.2f} | {g.mkt_loc_err.mean():+.2f} | "
            f"{g.our_loc_err.abs().mean():.2f} | {g.mkt_loc_err.abs().mean():.2f} | "
            f"{g.our_sd.mean():.2f} | {g.mkt_sd.mean():.2f} |")
    say()
    say(f"modal bucket agreement: {(d.our_modal == d.mkt_modal).mean() * 100:.0f}% of days")
    say(f"our modal correct {(d.our_modal == d.true_leg).mean() * 100:.0f}%, "
        f"market modal correct {(d.mkt_modal == d.true_leg).mean() * 100:.0f}%")
    say()

    say("## 2. The tail hypothesis")
    say()
    say("The report's thesis: the market piles onto the point-forecast bucket and "
        "starves both tails, so the tails are cheap. The two outer legs "
        "(`less` and `greater`) settled YES this often:")
    say()
    say("| slice | n | our mean P(tail) | market mean P(tail) | actual tail frequency |")
    say("|---|---|---|---|---|")
    for label, g in [("ALL", d)] + sorted(d.groupby("station"), key=lambda x: x[0]):
        say(f"| {label} | {len(g)} | {g.our_tail_p.mean():.3f} | {g.mkt_tail_p.mean():.3f} | "
            f"{g.tail_settled.mean():.3f} |")
    say()

    say("## 3. Does the edge live on high-spread (high xnd) days?")
    say()
    from score_vs_market import score, block_bootstrap
    s = score(rows, "mid")
    s["xnd"] = [r["xnd"] for r in rows]
    qs = s.xnd.quantile([1 / 3, 2 / 3]).values
    s["tercile"] = np.where(s.xnd <= qs[0], "low xnd",
                            np.where(s.xnd <= qs[1], "mid xnd", "high xnd"))
    say("| xnd tercile | n | ours LL | market LL | d LL | 95% CI |")
    say("|---|---|---|---|---|---|")
    for label in ["low xnd", "mid xnd", "high xnd"]:
        g = s[s.tercile == label]
        if g.empty:
            continue
        diff, lo, hi, _ = block_bootstrap(g, "ours_ll", "mkt_ll")
        say(f"| {label} (xnd {g.xnd.min():.0f}-{g.xnd.max():.0f}) | {len(g)} | "
            f"{g.ours_ll.mean():.4f} | {g.mkt_ll.mean():.4f} | {diff:+.4f} | "
            f"[{lo:+.4f}, {hi:+.4f}] |")
    say()

    say("## 4. Paper PnL of the trades our probabilities imply")
    say()
    say(f"Top-of-book only, {CONTRACTS} contracts per signal, Kalshi's per-order fee, "
        "settled against the real result. Assumes a fill at the touch, which "
        "funding-gate item #3 says is exactly the assumption that has never been "
        "measured -- so read this as an upper bound.")
    say()
    trades = []
    for r in rows:
        pm_bid = (r["bid"] * 100).round().astype(int)
        pm_ask = (r["ask"] * 100).round().astype(int)
        for i, t in enumerate(r["tickers"]):
            tr = paper_trade(r["ours"][i], int(pm_bid[i]), int(pm_ask[i]), CONTRACTS)
            if tr is None:
                continue
            side, price, ev = tr
            pnl = settle(side, price, CONTRACTS, bool(r["y"][i]))
            trades.append({"station": r["station"], "date": r["date"], "ticker": t,
                           "side": side, "price": price, "ev_cents": ev, "pnl_cents": pnl})
    td = pd.DataFrame(trades)
    say("| slice | trades | signalled EV ($) | realised PnL ($) | win rate | PnL per trade ($) |")
    say("|---|---|---|---|---|---|")
    for label, g in [("ALL", td)] + sorted(td.groupby("station"), key=lambda x: x[0]):
        say(f"| {label} | {len(g)} | {g.ev_cents.sum() / 100:+.2f} | "
            f"{g.pnl_cents.sum() / 100:+.2f} | {(g.pnl_cents > 0).mean() * 100:.0f}% | "
            f"{g.pnl_cents.mean() / 100:+.2f} |")
    say()
    for side, g in td.groupby("side"):
        say(f"  {side}: {len(g)} trades, realised {g.pnl_cents.sum() / 100:+.2f}, "
            f"mean price {g.price.mean():.1f}c")
    say()
    td.to_csv(HERE / "market_vs_model_paper_trades.csv", index=False)
    d.to_csv(HERE / "market_vs_model_diagnostics.csv", index=False)
    (HERE / "MARKET_SCORING_DIAGNOSTICS.md").write_text("\n".join(lines) + "\n")
    say("wrote market_vs_model_paper_trades.csv, market_vs_model_diagnostics.csv, "
        "MARKET_SCORING_DIAGNOSTICS.md")


if __name__ == "__main__":
    main()
