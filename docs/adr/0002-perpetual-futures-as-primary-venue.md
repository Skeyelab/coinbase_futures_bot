# ADR 0002: Perpetual Futures as the Primary Trading Venue

**Date:** 2026-07-22
**Status:** Accepted

## Context

Stage-2 validation (shared indicators #297, event-driven backtest #298, net-of-costs gate #353) produced the first honest unit economics for the live strategy on our original venue, Coinbase CDE **dated nano futures** (BIT/ET monthlies): a real gross edge on BTC (~25 bps/trade, ~60% win rate) that taker costs fully consumed (**−9 bps/trade net**; 0/10 profitable walk-forward windows across BTC+ETH).

Two cost-structure findings drove a venue re-examination:

1. Coinbase US futures fees are **~0.02%/contract with a $0.15/contract minimum per side** — a flat floor, not proportional bps. On a $100-notional nano contract the floor is 15 bps/side; small-notional contracts are structurally expensive (nano ETH catastrophically so).
2. All execution is taker (market entries, tick-triggered market TP/SL exits; `post_only` was hard-coded false), and on dated CDE futures a maker discount is unconfirmed.

A survey of all 99 Coinbase futures products (real per-product margin rates) showed the liquidity and the fee relief live elsewhere: **US perpetual futures** (BIP/XPP/SLP/ETP…) — $300M/day on the BTC perp vs single-digit millions on our dated contracts — at **~3 bps taker / 0% maker**, 24/7, with no contract rolls. Dated metals (gold $102M/day at 2 bps, 20× intraday margin; silver similar) are the cheapest round trips on the board but carry session hours, overnight margin step-ups, roll risk, and contract notionals ($3–4k) unsuitable for small accounts. Spot was re-eliminated: retail spot fees (40–60 bps/side) are 10–30× perp costs and spot is long-only, contradicting the long/short strategy.

Recosting the **unchanged** strategy (CFO + FinOps agents, 2026-07-22): dated BIT taker/taker −9 bps/trade → **BIP perp taker/taker +15 bps** → maker-optimized ~+22 bps. Perp funding (the one new cost stream) is ~0.1–0.5 bps/trade at our minutes-to-hours holds — material only for holds ≥2h or |funding| >5 bps/interval; the existing 6h day-trade limit bounds worst-case exposure.

## Decision

**Perpetual futures are the primary trading venue.**

- **BIP (nano BTC perp)** becomes the home instrument for the live strategy (#390). Migration is a routing/config change — the existing market-order machinery works unmodified; maker-order levers (#374/#377) target perps, where 0% maker makes them fully real.
- **XPP (XRP perp)** is the designated second seat — admitted only by passing the same gates.
- **Dated futures** are demoted to (a) legacy during migration and (b) a commodities research tier (gold/silver) revisited at ≥$10k equity, where their contract sizes and margin step-ups are tolerable.
- **Spot is rejected** (fees 10–30× perps; long-only).

Guardrails attached to the decision:

- **No evidence inheritance.** Edge measured on dated BTC does not transfer; each perp re-earns signal enablement via per-symbol walk-forward + net-of-costs gate on its own data (symbols stay `Trading::SymbolSuspension`-suspended for data collection until then — the ETH precedent).
- **Funding must be modeled before the cost gate certifies any perp** (#391): funding is position-time cost (funding timestamps crossed), never fill cost; rates are snapshotted live because funding history is not reconstructible.
- **Live capital starts under the $1k safety pack** (#392): BIP only, 1 contract, intraday-only, hard daily/weekly stops and a cumulative tuition cap with auto-halt, per-symbol `min_position_size` = 1, account-notional cap, parity checkpoints, and the #376 gate framework re-run on BIP data.

## Consequences

- Expected economics flip from negative to positive at identical signal quality; the fee-driven pressure to widen TP/SL targets becomes optional rather than existential (the wide calibration grid remains as search space, not necessity).
- New work: #390 (venue migration incl. generalizing the realtime subscription catalog beyond BIT/ET/NOL), #391 (funding snapshot + CostModel/simulator/gate modeling), #392 ($1k live-start pack). The universe-expansion registry (#340/#389) targets perp product IDs first.
- The `$0.15/contract` floor logic in `CostModel` stays (it prices dated contracts and any small-notional product); on BIP the floor never binds ($659 × 3 bps > $0.15).
- Monthly roll handling (expired-contract auto-disable, contract resolution) remains for the dated tier but exits the critical path.
- Kill criterion sharpens: if BIP live net expectancy ≤ 0 after 200 trades at ≤9 bps round-trip cost, the **signal** is dead — there is no cheaper venue left to blame.

## Alternatives considered

| Venue | Round trip | Verdict |
|---|---|---|
| Spot | 80–120 bps, long-only | Rejected — costs 3–5× the gross edge before leverage/shorting even enter |
| Dated nano futures (status quo) | 34 bps (floor-bound) | Demoted — measured net-negative; rolls; thin books |
| Dated metals (GOL/SLR) | 6–10 bps | Deferred to ≥$10k tier — cheapest costs, wrong contract size and session mechanics for now |
| **Perpetuals (BIP first)** | **~10 bps taker / 2–5 maker** | **Adopted** |
