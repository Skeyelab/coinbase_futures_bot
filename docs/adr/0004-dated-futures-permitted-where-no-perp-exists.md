# ADR 0004: Dated Futures Are Permitted Where No Perpetual Exists

**Date:** 2026-07-27
**Status:** Accepted
**Amends:** [ADR 0002](0002-perpetual-futures-as-primary-venue.md) (venue selection). ADR 0002 otherwise stands — perps remain preferred, spot remains rejected, and every guardrail it attached still applies.

## Context

ADR 0002 made perpetuals the primary venue and demoted dated futures to "(a) legacy during migration and (b) a commodities research tier (gold/silver) revisited at ≥$10k equity". Read literally, that leaves no venue for oil at all.

**Coinbase has no oil perpetual.** Oil trades as dated NOL futures or it does not trade. So the practice has already diverged from the ADR: the only positions this bot has ever opened are three NOL oil trades, on a venue the ADR calls legacy. This amendment ratifies that and gives it a rule, rather than leaving the strategy dependent on an ADR it contradicts.

The absence is specific to oil, not to commodities generally. A live survey of the product catalogue on 2026-07-27 found ~25 perpetuals, including non-crypto ones — index perps (`TEK`, `CHN`, `AIP`, `DEF`) and **`PAU` (PAXG), a gold-linked perp: $4,082 notional, 5.00% intraday margin (20x), ~$5.1M/day**. That matters here because ADR 0002 deferred metals to a ≥$10k tier on the strength of dated metals' mechanics — "$3–4k contract notionals, session hours, overnight margin step-ups, roll risk". `PAU` has none of those: 24/7, no roll, and ~$204 of margin per contract. **ADR 0002's metals deferral was a verdict on dated metals and does not transfer to a metals perp.** Admitting one is still gated on the conditions below and on earning its own enablement; the point is only that "commodities have no perp" is not a true premise.

The more useful observation is *why* ADR 0002 rejected dated futures. Its own table records dated nano futures at "34 bps (floor-bound)" and "measured net-negative" — but that measurement came from **crypto nanos (BIT/ET)**, and the dominant term was the flat per-contract fee floor, not the proportional rate. A fixed dollar floor is a rate that scales inversely with contract notional:

| Contract | Notional/contract | Floor per side | Floor as bps/side |
|---|---|---|---|
| Dated BIT nano | ~$100 | $0.85 | **~85 bps** |
| Oil NOL | ~$930 | $0.85 | **~9 bps** |
| Dated metals (GOL/SLR) | ~$3–4k | $0.85 | ~2–3 bps |

The nano verdict was never a verdict on *dated futures*. It was a verdict on *small-notional contracts*, which happened to be dated. ADR 0002 half-saw this when it kept the floor logic because it "prices dated contracts **and any small-notional product**" — but still drew the venue line at dated-vs-perp.

The live catalogue shows the line is in the wrong place. A perp's $0.15 floor binds below **$500 of contract notional** ($0.15 ÷ 0.0003), and several perps sit well under it:

| Perp | Notional/contract | Floor as bps/side | vs 3 bps schedule |
|---|---|---|---|
| `AVP` (AVAX) | $66 | **22.7** | 7.6x worse |
| `POP` (DOT) | $80 | 18.9 | 6.3x |
| `ADP` (ADA) | $159 | 9.4 | 3.1x |
| `BIP` (BTC) | $647 | 2.3 | floor never binds |
| `PAU` (PAXG) | $4,082 | 0.4 | irrelevant |

`AVP` is more floor-poisoned than the dated nanos ADR 0002 rejected. **Venue type does not predict cost; contract notional does.** Any eligibility rule keyed on dated-vs-perp is keyed on the wrong variable.

Since ADR 0002 was written, the fee model became measurable rather than assumed: fees are now resolved per venue (#458), applied to backtests including the floor (#471), used by the live cost gates (#459), and **measured from real fills per product** (#462). Cost viability is now something the system observes rather than something an ADR asserts.

## Decision

**Perpetuals are preferred. A dated future is permitted when no perpetual exists for the underlying AND the contract clears cost and size tests.**

A contract is eligible when all three hold:

1. **No perpetual exists for the underlying.** If a perp exists, the perp is the venue — there is no discretion. BTC trades BIP, not BIT.
2. **Round-trip cost clears the net-of-costs gate on its own measured fees.** Not on a seeded constant, and not inherited from a sibling contract: the measured per-contract commission for *that product* (#462), including the floor, against that contract's notional. A contract whose floor-driven cost swamps the expected edge is rejected regardless of availability.
3. **Contract notional is appropriate to account equity.** Retained from ADR 0002's reasoning and #392's: a contract whose single stop-out is a large fraction of equity is inadmissible at that account size, however cheap its fees. This is what keeps gold and silver out at $1k, and it is a function of equity — so it is re-evaluated as equity changes, not decided once.

Condition 1 alone would have readmitted small-notional dated contracts, which is precisely what ADR 0002 correctly rejected. Conditions 2 and 3 are what make "dated is permitted" safe rather than a reversal.

**Oil (NOL) is admitted under this rule** — no oil perp exists, its measured ~$0.85/contract fee against ~$930 notional is ~9 bps/side, and its contract size is workable at small account sizes.

Unchanged from ADR 0002 and still binding:

- **No evidence inheritance.** A dated contract earns enablement on its own walk-forward and net-of-costs gate, exactly as a perp does. Oil trades do not count toward enabling BIP, and BIP evidence does not transfer to oil.
- **Perp-first for anything with a perp.** This amendment does not reopen the BTC venue question.
- **Spot stays rejected.**
- **The #392 safety pack and the #376 gate framework apply per symbol**, on whichever venue it trades.

## Consequences

- **Oil work is on the critical path, not the research tier.** The dated machinery ADR 0002 moved off the critical path — monthly roll handling, expiry auto-disable, contract resolution — is load-bearing again for any commodity underlying.
- **Two venues must be supported concurrently, permanently.** Not "legacy during migration". Funding applies to perps only (#457), fees differ per venue (#459), and both paths need to stay correct. That is now a standing requirement rather than a transitional one.
- **Condition 2 depends on measurement that only exists for products with fill history.** Oil has fills; most products do not, and perps have none at all. Until a product has been measured, its eligibility rests on a seeded constant — which is an assumption, and should be treated as one when admitting anything new.
- **Dated metals remain excluded at current equity by condition 3**, not by condition 1 — so they become admissible on equity growth without needing another ADR. `PAU` (PAXG perp) is a separate case: it passes condition 1 as a perp and its notional is tractable, so it is eligible to be *considered*, subject to earning enablement like anything else.
- **Condition 2 applies to perps as readily as to dated contracts.** Several perps are more floor-poisoned than the nanos ADR 0002 rejected, so "it's a perp" is not a cost argument and must not be used as one.
- ADR 0002's kill criterion is unaffected: if BIP live net expectancy ≤ 0 after 200 trades at ≤9 bps round-trip, the signal is dead. Admitting oil does not give a failing signal somewhere to hide.

## Alternatives considered

| Option | Verdict |
|---|---|
| Leave ADR 0002 as written | Rejected — it forbids the only venue oil has, while oil is what the bot actually trades. An ADR the practice contradicts is worse than no ADR. |
| Permit dated futures wherever no perp exists, with no further test | Rejected — readmits small-notional dated contracts on availability alone, which is the exact case ADR 0002 measured at −9 bps/trade. |
| Drop the venue hierarchy; treat all venues equally on measured cost | Rejected — perps are structurally cheaper (0% maker, lower floor, no rolls) and the preference encodes that without needing to re-measure it each time. |
| Trade oil via spot or an ETF proxy | Rejected — spot economics were settled in ADR 0002; a proxy breaks the shared contract/rollover machinery for no cost benefit. |
