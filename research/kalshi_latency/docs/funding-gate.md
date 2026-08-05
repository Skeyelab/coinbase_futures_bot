# Funding gate: what "we have an edge" has to mean

Written 2026-08-04, BEFORE the evidence arrived, so it cannot be moved to fit
the result. $2-5k of real capital is conditional on every item below.

The project already works this way — the walk-forward verdict, the pessimistic
cost gate, the n8n Gate-3 sample. This is the same idea applied to Kalshi.

## Why not fund now

$250 is sufficient to PROVE an edge. Capital only changes how much you can
exploit one, not how well you can measure it. Funding before proof buys
nothing except a larger loss if the edge is imaginary.

It also moves the target: at $250 the tradeable markets are weather (median
$62 of depth within 5c). At $5k weather is irrelevant and the money goes to
crypto one-touch and econ releases — which have NO evidence behind them yet.
So funding early would fund the unmeasured half.

## The bar — all five, no exceptions

1. **Model accuracy.** At least 30 scored settled-fact calls, at least 95%
   correct at settlement. 16 are recorded as of 2026-08-04; tonight scores
   them. A model that is 90% right is not doing arithmetic, it is guessing
   with extra steps.

2. **Opportunity rate.** At least 1 tradeable opportunity per day, averaged
   over 7+ consecutive days of continuous scanning. Tradeable means net edge
   >= 2c after order-level fees at >= 50 contracts. Anything thinner cannot
   reach $5/day however well it works.

3. **Fill quality.** At least 10 real orders placed. At least 80% fill at or
   better than the quoted price, with slippage recorded per order. THIS IS THE
   ONE NO AMOUNT OF POLLING ANSWERS — a resting quote and a fillable quote are
   different things, and every measurement so far has assumed they are the
   same.

4. **Net positive after fees.** Cumulative realised PnL positive across those
   10+ trades. Gross does not count; the whole project's history is edges that
   died to fees.

5. **No single-event dominance.** Remove the single best trade. Still positive.
   One lucky settlement is not a strategy.

## Amendments — operator-ruled, dated, never retro-fitted

**2026-08-05, gate #1 denominator (issue #628).** First scoring pass: 75/79
all calls (94.9%), 75/75 on credible-only. Ruling: BOTH are reported, and
the credible-only number DECIDES — a doubted call can never become an order,
so it cannot decide whether orders are safe. The all-calls number stays in
every report so the filtered misses never disappear. The four misses (LAX
x2, SATX x2) were all doubt-flagged before settlement and none would have
traded.

**2026-08-05, gate #3 scoring (issue #631).** Ten real probe orders: resting
(maker) fills 1/7 in 60s windows; every fill that occurred — 1 maker, 1
taker — executed at exactly the quoted price, zero slippage. The original
wording imagined slippage risk and instead measured fill-rate risk. Ruling:
gate #3 scores the TAKER path — the strategy's real order shape is crossing
a stale quote — on fills executing at-or-better with slippage recorded per
order. Maker fill-rate remains an informational line, not a pass/fail input.
As of this ruling: 2/2 at-or-better, 0 slippage, n small.

## Kill criteria — stop and rework, do not tune

- Model accuracy below 90% on 30+ calls
- Fill rate below 50%
- Cumulative PnL negative after 20 trades
- Any settlement that contradicts the model's arithmetic rather than its
  inputs (that means the mechanism is wrong, not the data)

## Known unknowns that could invalidate all of it

- **Settlement basis.** Weather settles on the NWS Climatological Report, and
  we read METAR. Crypto one-touch settles on an index the rules do not name.
  Both are the same class of risk and neither has been verified.
- **Corroboration.** Peak support predicts market agreement; margin does not
  (measured 2026-08-04). Whether it predicts SETTLEMENT is untested.
- **Reflexivity.** Every opportunity observed so far vanished within ~70s.
  Whether that is competition or stale quotes being pulled is unknown.
