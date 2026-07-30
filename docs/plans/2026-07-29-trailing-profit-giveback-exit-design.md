# Trailing profit-giveback exit — design

Date: 2026-07-29
Status: designed, not implemented

## Why

The operator's exit rule has never been encoded in this repo. It has been running
in an n8n workflow against the Coinbase CFM API on a 30-second schedule, closing
positions outside the Rails bot entirely.

The rule was initially described as "hold until it makes $10-20 profit, then close
and decide whether to re-enter." Reading the workflow shows that is not the input —
it is the *output*. The actual rule is:

- fixed −$50 stop until unrealized profit reaches $25
- then a trailing stop at 70% of peak profit (give back 30%)

$25 × 0.7 = **$17.50** is the smallest profitable exit that rule can produce, which
is where the remembered "$10-20" comes from.

**Read the historical results with care.** The workflow's loss path is dead (appendix
item 1), so it auto-closed winners at the trail and never auto-closed a loser. Every
losing position was exited by hand. Any win rate, average win, or hold time drawn from
those executions measures the automation on the upside and the operator on the
downside — two different systems, and the aggregate is not a strategy result. The
described "$10-20 target" is simply the only thing the automation was capable of doing.

Two existing pieces of machinery are close but neither fits:

- `Trading::DollarExitPolicy` — a flat dollar target, no peak tracking. Models
  "exit at $X", not "give back Y% of peak".
- `Trading::TrailingStop::Algorithm` — trails a percentage of *price*
  (`market_extreme`, `trailing_stop_price`), not of dollar profit. Also disabled
  (`TRAILING_STOP_ENABLED` unset).

## Decisions

Recorded with reasoning, because each was a live branch during design.

**1. Thresholds are per contract, not per position.**

On dated futures the fee is a flat per-contract charge (~$0.85/side on NOL,
`CostModel.dated_fee_per_contract`), so a fixed *total* dollar target decays
linearly as contracts are added. At a $10 total target: 1 contract nets $8.30,
3 nets $4.90, 5 nets $1.50, and 6 is negative. Per-contract holds fee drag
constant at 17% on NOL regardless of size.

**2. Measured net of round-trip fees, not gross.**

A fee paid is money lost. Netting moves the two thresholds in opposite directions:
take-profit gets further away, stop-loss gets closer. On one NOL contract at
$15/contract, the stop fires at $13.30 of gross price loss because $1.70 of fees
already counts against it.

**3. Arm on a seeded fee estimate rather than staying unarmed.**

`CostModel.fee_for` falls back to a seeded constant when a product has no measured
fills. Failing closed (the `liquidation_buffer` precedent) would leave BIP unarmed,
since zero perp fills exist — and BIP is where the gate-2a paper sample runs. The
approximation costs cents; silence costs the sample.

**4. Track peak gross, derive peak net.**

Round-trip cost is constant while a position is open, so `peak_net = peak_gross − rt`
is exact. Storing gross keeps the new column symmetric with the existing
`max_adverse_excursion` and independently useful as a maximum favorable excursion.

**5. Suppress the strategy's take-profit branch when the trail is enabled.**

See "Precedence" below. Without this the feature is inert.

## The rule

```
rt       = CostModel.round_trip_cost_for(...)   # constant while open
net      = unrealized_pnl          - rt
peak_net = max_favorable_excursion - rt
per      = position.size

armed    = peak_net >= arm_at * per
floor    = armed ? peak_net * (1 - giveback)
                 : -(hard_stop * per)
exit when net <= floor
```

Armed and unarmed are exclusive, matching the workflow's `if (isTrailing) … else`.
Once armed at $25/contract with 30% giveback the floor is $17.50/contract, well
above the hard stop, so nothing is lost by not stacking them.

## Configuration

Inert unless `arm_at` and `giveback` are both set, following the opt-in convention
of `DollarExitPolicy` and `MinimumRoiExit`.

| Variable | Value | Source |
|---|---|---|
| `TRAIL_ARM_PROFIT_PER_CONTRACT_USD` | 25 | n8n `min_profit_to_trail` |
| `TRAIL_GIVEBACK_FRACTION` | 0.30 | n8n `trail_stop_percent` |
| `TRAIL_HARD_STOP_PER_CONTRACT_USD` | 15 | operator, 2026-07-29 |

The hard stop is deliberately *not* the workflow's $50: that was per position, and
per contract it would sit far above the live daily loss cap. $15/contract still
exceeds the $10 live daily cap (`LossLimits.live_daily_cap`), so on live money a
single stop-out ends the trading day. That is a caps conversation, tracked
separately — it does not block this work.

Applies to all open positions. `check_dollar_pnl_exit` gates on
`position.day_trading?`; the workflow made no such distinction, so the trail does
not inherit that gate.

## State

One new column:

```ruby
add_column :positions, :max_favorable_excursion, :decimal
```

Written by `Position#track_favorable_excursion!`, mirroring the existing
`track_adverse_excursion!` exactly — running maximum, `update_column` to skip
callbacks, writes only on a new high so it is not a DB write per tick. Called from
`check_position_alerts` alongside the MAE tracker (`tick_handler.rb:65`).

No backfill. A nil value seeds from the current gross PnL on first tick, which is
the workflow's "Calculate Trailing Stop - New" path.

## Precedence

Placement in `RealtimeMonitoring::TickHandler#check_position_alerts`: after the
liquidation buffer, which stays highest, and before everything else. The trailing
policy carries its own stop, so it cannot sit below other take-profits.

That is not sufficient on its own. `check_take_profit_stop_loss` closes on
`position.take_profit`, a price level set at entry from the strategy's
`tp_target: 0.006`. In per-contract dollars:

| | 60bps take-profit | arm threshold |
|---|---|---|
| NOL | $5.58/contract | $25 |
| BIP | $3.95/contract | $25 |

The strategy's take-profit fires roughly 5x sooner than the trail can arm, so
`max_favorable_excursion` would never reach $25 and the trail would never fire
once — enabled, plausible, and completely inert.

Therefore: when the trailing policy is enabled for a position,
`check_take_profit_stop_loss` skips the take-profit branch and keeps `stop_loss`.
The trail owns all upside exits; the strategy's stop remains as a second backstop
alongside the trail's hard stop, whichever is tighter. This requires no change to
entry-time target setting.

## Per-tick cost

`CostModel.round_trip_cost_for` reaches `fee_for`, which performs two DB hits
(`FundingRate.for_product(...).exists?` and `ProductFee.measured_per_contract`).
At ~85 ticks/min that is significant. Entry price, size and symbol are fixed while
a position is open, so the cost is memoized per position id — the same shape as the
existing `@min_roi_policies` cache, keyed by `position.id` instead of symbol.

Both sides are priced at entry notional, matching the convention in
`PaperPnlSummary#round_trip_cost_for` and `SymbolCircuitBreakerJob`. Slippage is
left at zero: this is a fee question, and the exit is evaluated against a live tick
rather than a modeled fill.

## Failure modes

Every uncertain input holds rather than closing.

| Condition | Behavior |
|---|---|
| `unrealized_pnl_at` nil (closed, no price) | hold |
| `size` nil or zero | hold |
| `round_trip_cost_for` raises | log, hold this tick |
| `giveback` outside `(0,1)` | policy reports disabled, logs once |
| `max_favorable_excursion` nil | seed from current gross PnL |

Holding on fee-lookup failure is why the strategy's `stop_loss` branch is kept: if
the lookup breaks persistently the trail goes quiet, and the position is still
covered by a stop rather than running naked.

A `giveback` of 1.0 would place the exit at $0 and hand back every dollar of peak,
which is why the bound is validated rather than clamped.

## Tests

**Pure policy** (no DB, mirroring `dollar_exit_policy_spec`): not armed below
threshold; armed at exactly threshold; giveback floor math; hard stop at
−$15/contract; per-contract scaling verified at 1 and 3 contracts; nil and zero
guards; giveback bounds.

**Model**: `track_favorable_excursion!` writes only on a new high, ignores adverse
ticks, no write when unchanged — the same assertions the MAE method carries.

**Integration** (`tick_handler`): the trail fires ahead of the bps take-profit; the
take-profit branch is skipped when the policy is enabled and still runs when it is
not; `stop_loss` stays live either way; the fee lookup is hit once across N ticks.

**Regression, on real numbers**: NOL at $25 arm / 30% giveback, peak $30 → floor
$21. And the inertness guard: with the take-profit branch left in,
`max_favorable_excursion` never passes $5.58 and the trail never arms.

## Appendix — defects found in the n8n workflow

Recorded because they change how the historical results should be read. Sorted by
consequence.

**1. The loss path is dead, so losses were never automated.** `Approval Already
Pending?` carries `"disabled": true`, and its output-0 connection list is empty:

```json
"Approval Already Pending?": { "main": [ [], [ {"node": "Set Approval Pending"} ] ] }
```

n8n handles a disabled node in `workflow-execute.ts` via `handleDisabledNode`, which
returns the first main input. Whether that terminates the branch or routes the
passed-through data to output index 0, the outcome here is identical, because output 0
has no connections. Nothing downstream of that node has ever run.

Tracing the two branches out of `Hit Stop Loss?`: profit goes straight to
`Close Position` with no approval, and loss goes to the disabled node and stops. So the
workflow books winners automatically and never closes a loser — the −$50 stop has never
fired once. This is the finding that biases every historical number; see "Why" above.

The fix is one toggle. Re-enabling the node reconnects
`Set Approval Pending → Alert via Slack → User Confirmed? → Close Position`, and its
empty true-branch is correct by design (the "do not re-alert" case). Worth establishing
why it was disabled before flipping it back.

Decisive empirical check: filter the n8n execution list for any run that reached
`Alert via Slack`. If this is right, there are zero, ever.

**2. `contract_multiplier` is always 1.** The expression tests
`product_id.includes('BTC')`, but CFM product IDs are `BIT-19AUG26-CDE`,
`BIP-…`, `NOL-…` (`app/models/contract.rb:38`). `"BIT-19AUG26-CDE".includes('BTC')`
is false, and `'ET-'` matches only literal `ET-…`. Every BTC contract falls to the
`1` branch:

| | workflow notional | true notional | fee error |
|---|---|---|---|
| BIT (nano BTC) | price × N ≈ $100,000 | $1,000 | 100x over → `total_fees` ≈ $80 |
| NOL (oil) | price × N ≈ $93 | $930 | 23x under → $0.07 vs $1.70 |

On BTC this alone keeps `current_pnl` roughly $80 negative, so the $25 trail arm is
unreachable. On oil, `current_pnl` was effectively gross. The formula also *divides*
by the multiplier, which cannot express oil at all — NOL is contract_size 10 and
needs a multiply.

**3. The time-based creep does not creep.** `previousStop` is read from state and
never referenced. `stopLoss` is recomputed from `highest_pnl` every run, so the
10%-of-gap adjustment applies to a fresh base and never accumulates. Because
`gap = currentPnL − stopLoss` shrinks as P/L falls, the adjustment shrinks with it:
at highest $100 the stop reads $72 at P/L $90, $70.50 at $75, $70.10 at $71. It
converges downward to the base rather than ratcheting up.

**4. Account PnL attributed to a single position.** `unrealized_pnl` comes from
`balance_summary` (the whole CFM account) while `product_id` and `contracts` come
from `positions[0]`. With two positions open it trails the aggregate and closes only
the first.

**5. Unexecuted-node references in the close path.** `Close Position`,
`Clear Position State` and `Clear Approval Pending` all read

```
$('Calculate Trailing Stop - Update').first().json.product_id
  || $('Calculate Trailing Stop - New').first().json.product_id
```

Those two nodes are the branches of `State Exists?`, so exactly one runs per execution.
Referencing an unexecuted node in n8n **throws** rather than returning undefined, so the
`||` never falls through — it only works when the left-hand node is the one that ran.
Masked today because a state row exists by the time any close fires, but it breaks on a
position that closes on its first evaluation.

**6. `× 4` on `per_trade_fee`** stands in for a round trip, where a true per-side
rate wants ×2.

**7. The −$50 stop is 5x the Rails live daily loss cap** of $10.
