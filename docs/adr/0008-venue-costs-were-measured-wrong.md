# ADR 0008: Venue Costs Were Measured Wrong, and the Cheap Venues Were Never on the Board

**Date:** 2026-08-04
**Status:** Accepted
**Supersedes the economics of:** [ADR 0002](0002-perpetual-futures-as-primary-venue.md). Its venue *ranking* survives. Its numbers, its projected edge, and its kill criterion do not.

## Context

ADR 0002 moved the strategy from dated nano futures to the BIP perp on a recosting: dated taker/taker −9 bps/trade → **BIP perp +15 bps** → maker-optimized **~+22 bps**. It priced perps at **~3 bps taker / 0% maker** and set a kill criterion: *"if BIP live net expectancy ≤ 0 after 200 trades at ≤9 bps round-trip cost, the signal is dead — there is no cheaper venue left to blame."*

Three of those four numbers were wrong, and the last clause was wrong twice over.

### What the venue actually charges

Measured 2026-08-04 from the live fee schedule and real fills, not from a rate card:

| | ADR 0002 assumed | measured |
|---|---|---|
| BIP taker | ~3 bps | **10.175 bps** |
| BIP maker | 0% | **7.5 bps** |
| BIP round trip | ~6 bps | **20.35 bps** |

The taker fee decomposes exactly as `notional × 0.0008 + $0.14/contract`. Tier is `Advanced 3`. ADR 0002's claim that "on BIP the floor never binds" is therefore false — a flat per-contract component is present at every size, it is simply smaller than on dated contracts.

The 0% maker figure was the most expensive error, because it justified the maker-order work (#374/#377) as worth ~7 bps of recovery. The real maker/taker spread is 2.675 bps, so that lever is worth about a third of what was claimed.

### What the strategy actually earns

Walk-forward on the corrected notional at real fees:

```
gross edge      13.9 bps/trade
round trip      20.35 bps
net             negative
```

Backtested over three months of BIP and six weeks of NOL, the strategy's baseline exit loses money on both: **−$3.51/trade on BIP, −$27.61/trade on NOL**. This is not an exit-tuning problem. Two exit rules ported from the operator's n8n workflows — trailing profit-giveback (2026-07-30) and ATR chandelier (2026-08-04) — were each backtested and each made things worse at every parameter, for the same structural reason: layered onto a strategy with a working take-profit, a trailing exit replaces a good exit with a worse one.

### The clause that was most wrong

*"There is no cheaper venue left to blame."*

There is. The account holder already had access to it.

| venue | round trip | note |
|---|---|---|
| E*TRADE equities/ETFs | ~0 bps + spread | $0 commission, account already open |
| E*TRADE futures (MES) | ~1 bps | $1.50/side on ~$28k notional |
| E*TRADE futures (MCL) | ~4 bps | micro crude — the same oil exposure as NOL |
| Kalshi (tails) | ~2–14 bps | order-level fee, quadratic in price |
| **Coinbase perp (BIP)** | **20.35 bps** | current home instrument |
| Coinbase dated (NOL) | ~24–40 bps | flat per-contract fee dominates at size |

The same $7,500 of crude exposure costs **$30.58 round trip on Coinbase NOL and $3.00 on E*TRADE MCL**. Coinbase's flat $0.85/contract charge barely moves with notional, so it punishes precisely the small-contract instruments the strategy was built around.

ADR 0002 surveyed 99 Coinbase products. It never asked whether Coinbase was the right exchange.

## Decision

1. **ADR 0002's venue ranking stands.** Perps really are cheaper than dated futures, and 20.35 bps really does beat 34–40 bps. The comparison was sound; the absolute numbers were not.

2. **Its economics are void.** +15 bps becomes roughly **+4.65 bps** before the corrected gross edge is applied, and negative after. The maker lever is worth ~1 bps, not ~7. No decision may cite the +15/+22 figures again.

3. **The kill criterion is retired, not met.** It required ≤9 bps round-trip cost. Actual cost is 20.35 bps — 2.3× the ceiling — so the criterion was never evaluable on this venue. It is replaced by: *if the strategy shows no positive gross edge net of a venue's real measured costs, the venue is wrong or the signal is dead, and the cheaper venue must be tried before the signal is declared dead.*

4. **Venue selection precedes strategy work.** A 13.9 bps gross edge is deeply negative at 20 bps and solidly positive at 1–2 bps. Cutting costs by an order of magnitude is a larger lever than any strategy improvement attempted so far, and it does not require being cleverer than the market.

5. **Fee assumptions must be measured, never taken from a rate card.** Every fee number in this repository is now sourced from `Trading::VenueFeeSchedule` (live `/transaction_summary`) or from real fills via `ProductFee`, with a drift detector (#588) that alerts when the model and reality diverge. Hardcoded fee constants are a defect class, not a shortcut.

## Consequences

- The BIP live-trading track is parked on economics, not on machinery. The entry gate (#575) currently refuses BIP on the newest walk-forward verdict, which is correct behaviour.
- Any future "the strategy doesn't work" conclusion drawn from Coinbase results is unsafe. The venue confounds it.
- Porting the walk-forward harness to an instrument with candles on a ~1 bps venue is the highest-value unexplored experiment. It reuses machinery that already exists.
- ADR 0004 (dated futures where no perp exists) is not amended, but the oil case it permits is now known to cost 24–40 bps against ~4 bps for micro crude elsewhere. That permission should be revisited before oil is traded again on Coinbase.

## What would falsify this

Measured fills on E*TRADE or CME micros showing round-trip costs materially above the published schedules — the same mistake this ADR exists to correct, made in the opposite direction. No cost figure above is from a fill; all are from published rates. That is weaker evidence than the Coinbase numbers, which come from real fills, and it should be upgraded before capital moves.
