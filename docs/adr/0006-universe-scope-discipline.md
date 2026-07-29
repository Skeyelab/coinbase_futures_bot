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

Recorded honestly, because the failure this ADR describes is exactly the one an unimplemented ADR causes. ADR 0002 declared BIP the home instrument on 2026-07-22 and `ASSET_MAPPING` still routed BTC to the dated BIT contract; the decision read as done for six days because nothing tracked the gap. **Closed 2026-07-28 (#390):** venue selection now reads `Contract::PRODUCT_PREFIXES`, which records a venue per prefix, and `Contract.best_available_for_asset` prefers an enabled perp over the dated month windows — so BTC resolves to BIP, OIL keeps resolving to the front-month NOL (ADR 0004), and an asset with a perp is never silently rerouted to a dated contract.

**As of 2026-07-29, decisions 1, 2, 3, 4 and 5 are enforced by code. Decision 6 is not.**

Decision 3 landing has an immediate consequence worth stating rather than discovering: **no currently-enabled symbol clears it.** NOL-19AUG26-CDE has no recorded walk-forward at all, and BIP-20DEC30-CDE's latest verdicts (2026-07-29) all failed the cost gate on 1,225–4,644 trades. That is the gate working — neither symbol has current evidence — and it means the bot will refuse entries until a walk-forward passes. Admitting a symbol is now an act of producing evidence, not of recording a judgement.

| Decision | State |
|---|---|
| 1. Ingestion writes `enabled: false` by default | **built, with a deviation — see the note below.** `upsert_products` no longer writes `enabled` on rows that already exist, and `FuturesContractManager#discover_*_month_contract` no longer does either. `contracts.enabled` keeps its schema default of `true` and keeps meaning *in the data pipeline*; what a newly-ingested product can no longer do is trade. |
| 2. `MAX_LIVE_INSTRUMENTS` enforced at the entry gate | **built.** Default 1, in `RapidSignalEvaluationJob#should_execute_signal?`, rejection reason `live_instrument_cap`, alongside `global_position_cap` / `asset_position_cap` / `account_notional_cap`. Two arms: distinct instruments holding open positions, and more symbols enabled than may ever be live at once. |
| 3. Entry gate reads the recorded walk-forward verdict | **built.** `RapidSignalEvaluationJob.cost_gate_verdict` reads the MOST RECENT succeeded walk-forward for the resolved contract; the entry gate refuses with reason `cost_gate_unproven` unless it cleared the cost gate on at least `COST_GATE_MIN_TRADES` trades (default 100, the #376 gate-2 bar). Latest-wins, not best-ever: a later run with a worse result supersedes an earlier pass, so the gate cannot be satisfied by the friendliest number ever produced. **The sample-size floor is load-bearing** — recorded BIP runs on 2026-07-29 had every PASS resting on `trade_count` 2 (expectancy +$48.64, +$29.15, +$1.71) and every FAIL on 1,225–4,644 trades agreeing within a dollar (−$2.65 to −$3.45); reading `cost_gate_passed` alone would have admitted the symbol on two trades. |
| 4. Suspension fails closed | **built.** `Trading::SymbolSuspension` now holds two facts — enablement and suspension — and `suspended?` is the absence of the first or the presence of the second. An explicit suspension stays authoritative over a stale enablement, so a breaker trip cannot be undone by a leftover record. `LIVE_INSTRUMENTS` seeds the list declaratively so a fresh database is not an outage only a Rails console can end. |
| 5. `bin/futuresbot suspend` / `resume` | **built.** `suspend SYMBOL --reason` (no confirmation — friction on the brake is friction during an incident), `resume SYMBOL` (money-touching, so `--yes` per ADR 0005), and `universe` to show what is live and why the rest is not. All three support `--json`. Every block message names the exact command that ends it. |
| 6. One in, one out | policy only; no code. Partly subsumed by decision 2, whose default of 1 makes admitting a second instrument require suspending the first. |

**The deviation in decision 1.** The decision text says ingestion writes `enabled: false` for anything not on the live list. Implementing that literally would have stopped *data collection*, because `contracts.enabled` is what drives `RealtimeSubscriptionCatalog`, `FetchCandlesJob`, sentiment and calibration — the very thing this ADR wanted to keep cheap and reversible. Ingestion and enablement are separated instead by moving tradeability entirely into the fail-closed suspension store, and by making ingestion non-authoritative over `enabled` for rows that already exist. The property the decision was reaching for holds: adding a prefix to `PREFIX_TO_BASE_CURRENCY` now grants data collection and nothing else. The mechanism differs from the one written above, and that is recorded here rather than by editing the decision.

**Two paths granted enablement with no decision behind them; both are now closed.** `upsert_products` wrote `enabled: true` on every run, so an operator's explicit disable was reverted on the next ingestion cycle with no log line saying so — the pipeline out-voted the human, every time. `FuturesContractManager#discover_*_month_contract` did the same, and is reached from a lookup scoped to `Contract.enabled`: disabling a contract made the lookup miss, which called discovery, which re-enabled the row that had just been turned off.

**A related data defect, fixed.** `ingestible_product_id?` gated *refresh* as well as *creation*, so any `Contract` row whose prefix is absent from `PREFIX_TO_BASE_CURRENCY` could never receive the margin-rate columns that shipped on 2026-07-27 — leaving `Trading::LiquidationBuffer` unarmed on four enabled futures (`GOL-*`, `SLR-*`, `SLP-*`, `ETP-*`). The prefix map now gates what we start collecting, not whether a row we already hold gets the number the liquidation rail depends on. `BTC-USD` and `ETH-USD` are spot reference feeds created by `rake real_time:setup_pairs`; they carry no `future_product_details` and never will, and under the separation above their `enabled` flag is a data-pipeline statement rather than a licence to trade.

**And one in the circuit breaker.** `SymbolCircuitBreakerJob` filtered `paper: true`, so with `LIVE_TRADING_CONFIRMED=1` the only automated writer of `SymbolSuspension` queried an empty set; it is now scoped to the mode in force, as `Trading::LossLimits` already was. Its `MIN_TRADES` sample also counted rows, and since #509 a partial reduce creates its own `CLOSED` row — five reduces of one position satisfied a five-trade minimum, so the breaker could suspend a symbol on the evidence of a single position. Positions now carry `parent_position_id` and the sample counts positions.

## Consequences

- PAU, XPP, and any other collected-but-unvalidated symbol are explicitly not tradeable, which is what the code comments already claim and the code does not currently enforce.
- Issue #389 (silver, XRP) is blocked by this ADR until an instrument has actually traded.
- Issue #505 (per-contract suspension vs per-asset decisions — a monthly roll silently re-enables) becomes a correctness bug against a stated rule rather than an oddity.
- The `paper: true` filter in `SymbolCircuitBreakerJob` is a defect: the breaker cannot see live trades, so with `LIVE_TRADING_CONFIRMED=1` the only automated suspension writer is blind.
- **Rules 2 and 6 are scaffolding, and scaffolding that outlives its purpose becomes its own problem.** Both are tied to a specific condition — zero fills on the primary venue — and both should be revisited by amendment once issue #486 produces measured fills. This ADR is not an argument that one instrument is the right long-run number; it is an argument that the right number must be *chosen* rather than accumulated.
- Adding an instrument becomes slower. That is the point: the current cost of adding one is a single line, and that price is what produced a six-instrument universe in front of a pipeline that has never filled on its home instrument.
