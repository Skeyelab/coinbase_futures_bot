# ADR 0006: Universe Scope Discipline — A Bounded Instrument Count

**Date:** 2026-07-28
**Status:** Accepted
**Relates to:** [ADR 0002](0002-perpetual-futures-as-primary-venue.md) and [ADR 0004](0004-dated-futures-permitted-where-no-perp-exists.md), which each granted a venue permission. Neither is amended; this bounds the total they can reach.

## Context

ADR 0002 admitted perps and named BIP the home instrument. ADR 0004 amended it to admit dated futures where no perp exists, and observed that a metals perp (PAU) is admissible in principle. Each permission was individually well-reasoned. **Nothing anywhere bounds their sum.**

Verified 2026-07-28: there is no cap on how many instruments may be live. No `max_venue`, `max_instrument`, `max_symbol`, `max_product`, or `max_enabled` exists anywhere in `app/`, `lib/`, `config/`, or `db/`. What does exist bounds different quantities:

- `MAX_CONCURRENT_POSITIONS`, default 3 — open position **count** (`rapid_signal_evaluation_job.rb:258-261`)
- per-asset `max_concurrent` — `config/asset_sizing.yml`, only fixed on commit `9c95169`
- `Trading::NotionalCap` — aggregate open **notional** at 2× equity
- `Trading::LossLimits` — realized **dollars** lost

All four bound what happens *after* an instrument is live. None bounds how many get there.

The growth path is one line. `Contract::PREFIX_TO_BASE_CURRENCY` currently holds six entries (BIT, ET, NOL, BIP, XPP, PAU). Adding a seventh causes `MarketData::CoinbaseRest#upsert_products` to write `enabled: true` for every matching product (`coinbase_rest.rb:92`), `contracts.enabled` defaults to `true` in the schema, and `RealtimeSubscriptionCatalog.futures_product_ids` returns every `Contract.enabled` row. One line of config produces a live subscription, candle collection, indicator computation, fee modelling, and sizing tiers.

**The guardrail that was supposed to stop this is fail-open.** `contract.rb:33` states that PAU "stays `SymbolSuspension`-suspended and earns enablement on its own walk-forward, per ADR 0002 / 0004." But `Trading::SymbolSuspension` is an initially-empty store: nothing is suspended unless something suspends it. Its only automated writer is `SymbolCircuitBreakerJob`, which requires ≥5 closed trades first (`symbol_circuit_breaker_job.rb:16-20`) — and filters `paper: true`, so it never sees live trades at all. **There is no rake task and no CLI verb to suspend a symbol**; the only route is a Rails console call. So the ADR 0002 no-evidence-inheritance rule rests on a mechanism that defaults to permitting everything.

The cost is not the config line. It is that each admitted instrument multiplies machinery that must then be maintained and validated: per-venue fee shapes, funding-vs-dated branching, contract-size resolution, margin rates, roll/expiry handling, and per-asset sizing tiers. Every one of those was built and none has been validated against a real fill on the primary venue — the bot has produced **zero perp fills**, and the only positions it has ever opened are three NOL oil trades (ADR 0004).

The pattern this ADR exists to break: **a permission is granted, machinery grows to serve it, and the assumptions the previous permission's machinery rested on are never rechecked.** The concrete instance: `Trading::LiquidationBuffer` documented an assumed 10× leverage, which was correct for every instrument at the time. ADR 0004 then admitted PAU, printed its 5.00% intraday margin (20×) in its own table, and nothing revisited the constant — leaving a pre-liquidation exit at ~9.0% adverse on an instrument that liquidates at ~4.5%. The safety rail sat behind the cliff for five days, and the ADR that created the hazard also contained the number that disproved it.

## Decision

**The live universe is capped, the cap is enforced in code, and admission is a decision with a gate — not a config line.**

**1. Ingestion and enablement are separate.** Adding a prefix to `PREFIX_TO_BASE_CURRENCY` grants *data collection only*. Ingestion writes `enabled: false` for any product not on the explicit live list. Collecting history is cheap and reversible; trading is neither.

**2. `MAX_LIVE_INSTRUMENTS`, default 1.** The count of simultaneously-tradeable symbols is bounded and enforced at the entry gate, alongside the existing position and notional caps. Default 1 because the current live count that has ever produced a perp fill is zero, and BIP has not yet traded. Raising it is an operator action with a recorded reason.

**3. Admission requires a passed gate, not an absence of objection.** A symbol becomes tradeable only with a recorded walk-forward verdict for that symbol — the ADR 0002 rule, now with a mechanism behind it. `backtest_runs.metrics->>'cost_gate_passed'` already holds the verdict and nothing reads it; the entry gate must.

**4. Suspension fails closed.** A symbol with no recorded enablement is treated as suspended. This inverts today's default and makes `contract.rb:33`'s claim true rather than aspirational.

**5. Suspension gets an operator affordance.** `bin/futuresbot suspend <symbol> --reason` and `resume <symbol>`. A control reachable only from a Rails console is not a control.

**6. One in, one out, until the first fill.** While zero perp fills exist, admitting a new instrument requires retiring another. This is deliberately blunt and expires on its own terms — see below.

## Implementation status

Recorded honestly, because the failure this ADR describes is exactly the one an unimplemented ADR causes. ADR 0002 declared BIP the home instrument on 2026-07-22 and `ASSET_MAPPING` still routes BTC to the dated BIT contract; the decision read as done for five days because nothing tracked the gap.

**As of 2026-07-28, every numbered decision above is UNBUILT.** Nothing in this ADR is enforced by code yet:

| Decision | State |
|---|---|
| 1. Ingestion writes `enabled: false` by default | not built — `coinbase_rest.rb:92` still writes `enabled: true` |
| 2. `MAX_LIVE_INSTRUMENTS` enforced at the entry gate | not built |
| 3. Entry gate reads the recorded walk-forward verdict | not built — `backtest_runs.metrics->>'cost_gate_passed'` still unread |
| 4. Suspension fails closed | not built — `SymbolSuspension` still defaults to permitting |
| 5. `bin/futuresbot suspend` / `resume` | not built |
| 6. One in, one out | policy only; no code |

Until these land, the universe is bounded by operator discipline alone. Do not read this ADR as protection.

## Consequences

- PAU, XPP, and any other collected-but-unvalidated symbol are explicitly not tradeable, which is what the code comments already claim and the code does not currently enforce.
- Issue #389 (silver, XRP) is blocked by this ADR until an instrument has actually traded.
- Issue #505 (per-contract suspension vs per-asset decisions — a monthly roll silently re-enables) becomes a correctness bug against a stated rule rather than an oddity.
- The `paper: true` filter in `SymbolCircuitBreakerJob` is a defect: the breaker cannot see live trades, so with `LIVE_TRADING_CONFIRMED=1` the only automated suspension writer is blind.
- **Rules 2 and 6 are scaffolding, and scaffolding that outlives its purpose becomes its own problem.** Both are tied to a specific condition — zero fills on the primary venue — and both should be revisited by amendment once issue #486 produces measured fills. This ADR is not an argument that one instrument is the right long-run number; it is an argument that the right number must be *chosen* rather than accumulated.
- Adding an instrument becomes slower. That is the point: the current cost of adding one is a single line, and that price is what produced a six-instrument universe in front of a pipeline that has never filled on its home instrument.
