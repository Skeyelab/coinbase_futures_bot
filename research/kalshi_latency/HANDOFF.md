# Handoff — Kalshi settled-fact research

Written 2026-08-04. Read this before touching anything in `research/kalshi_latency/`.

---

## 1. What this project is

We are trying to find contracts on Kalshi whose outcome is **already determined**
by a public, monotone observable, but whose **price has not updated yet**.

Not prediction. Not chart reading. Arithmetic on a ratchet.

Example: a market asks "will LA's high be 82 or below today?" It is 3pm and LA has
already hit 84. A daily maximum cannot fall. The contract is refuted — it will
settle at 0 — and anyone still bidding 12c for YES is paying for a fact that is
already public.

The whole project is: find those, verify the arithmetic is right, and measure
whether they are actually **fillable**.

### Why this is the only shape that survived

The origin was a viral Instagram claim (a Claude-built bot, $250k in 64 days,
Polymarket 5-minute crypto, entering during a 30-90 second news-repricing lag).
We spent a day measuring whether that lag exists anywhere.

**It does not.** Measured repricing on Kalshi:

```
KXTRUMPACT             0.45 -> 0.97 in 338 milliseconds
earnings mentions      0.80 -> 0.99 in 2-4 seconds
sports                 repriced in 1.6 seconds
Reddit DAU             0.31 -> 0.01 in 1.4 seconds
econ releases          market CLOSES 1-5 min BEFORE the data lands
```

So "be faster than the market at reading news" is dead on every category we could
measure. What is NOT dead is "the market is not watching a slow-moving public
number at all," which is what a ratchet is.

**See section 5 for the full elimination list. Do not re-derive it.**

---

## 2. Current state

### Branch and code

```
branch   research/kalshi-repricing-latency
HEAD     7e5b3cd  feat(kalshi): reusable Truth Social post-count ratchet
tests    168 examples, 0 failures, lint clean, every mutation killed
deps     zero gems — stdlib only, standalone from the Rails app
```

### Open PRs (unrelated to Kalshi, both mergeable, both awaiting merge)

```
#613  feat(exits): ATR chandelier — tested, measured, deliberately left disabled
#612  docs(adr): ADR 0008 — venue costs were measured wrong
```

### Running on exo-mini right now

```
unit     kalshi-scan.service   (systemd --user, lingering enabled, ACTIVE)
data     ~/kalshi-data/        300K
scope    28 scopes / 168 markets, weather only
secrets  Doppler at runtime — nothing written to disk
access   GET-only. There is no order path in this code at all.
```

Data as of this writing:

```
cycle-2026-08-04.jsonl        412 cycles
cycle-2026-08-05.jsonl        420 cycles       (UTC has rolled)
opportunity-2026-08-04.jsonl  263 raw candidates
opportunity-2026-08-05.jsonl  419 raw candidates
```

**Do not read the opportunity counts as opportunities.** Those files hold *raw
candidates*. Credibility filtering happens at analysis time in
`bin/analyze_opportunities`, not at write time. The record has no `doubts` field.

The **credible** rate is **0.00/hr over 6.5 hours**. That is gate item #2 and it
is currently failing. See section 7.

---

## 3. Code map

All under `research/kalshi_latency/`.

### The ratchet models — one per shape of observable

| File | Shape | Notes |
|---|---|---|
| `lib/temp_market.rb` | daily **maximum** | rounds to whole degrees first |
| `lib/low_temp_market.rb` | daily **minimum** | mirror; settleable side **flips** |
| `lib/count_market.rb` | cumulative **count** | deliberately does NOT round |
| `lib/touch_market.rb` | one-touch | **DISABLED** — see section 6 |

`lib/ratchet_registry.rb` maps series ticker prefix -> `{kind, observable}`.
**The series is the authority. `strike_type` from the API lies** — `less` means
opposite things on `KXHIGHNY` and `KXBTCMINMON`. Match is `start_with?`, prefix
not substring. Unknown series returns nil rather than guessing.

### Observation sources

```
lib/nws_station.rb        METAR observations. DEFAULT_LIMIT = 400.
lib/daily_extreme.rb      shared extremes + support counting
lib/cities.rb             7 verified highs, 12 unverified highs, 9 unverified lows
lib/truth_social_source.rb  Roll Call trumpstruth.org reader
lib/price_extremes.rb     crypto window extremes (feeding disabled touch family)
```

### Pricing and judgment

```
lib/order_book.rb     normalises Kalshi's TWO BID LADDERS into bid/ask
lib/opportunity.rb    edge, fee, net — returns nil unless net > 0
lib/credibility.rb    four doubt signals; anything with doubts is not tradeable
lib/convergence.rb    measures how long a market took to absorb a release
```

### CLIs (`bin/`)

```
scan                    one-shot scan across all scopes
collect / collect_weather / collect_opportunities   continuous collectors
analyze / analyze_dwell / analyze_opportunities     read the collected data
record_predictions      writes calls BEFORE settlement
score_predictions       scores them AFTER settlement
truth_count             one-shot Truth Social count + contract pricing
ledger                  two-track trade ledger, never summed
```

---

## 4. Traps — things that are wrong until you know them

Every one of these cost real time. They are not obvious from the code.

**Kalshi strike bounds are not uniformly inclusive.**

```
between  B89.5  floor=89 cap=90  "89 to 90"       BOTH INCLUSIVE
greater  T90    floor=90         "91 or above"    floor EXCLUSIVE
less     T83    cap=83           "82 or below"    cap EXCLUSIVE
```

**Which side is settleable early flips between max and min markets.** A daily max
can only rise, so `greater` confirms early and `less` refutes early. A daily min
can only fall, so it is the exact reverse. Copying `TempMarket` into
`LowTempMarket` without inverting produces a model that is confidently backwards.

**Fees are charged per ORDER, not per contract.**

```ruby
ceil(0.07 * contracts * price * (1 - price))
```

Quadratic in price, so near-free at the tails — which is exactly where settled
facts live. A per-contract fee model deletes real opportunities: a 1c edge nets
zero under it. Also `round(6)` before `ceil`, or float error turns 175.0 into
175.00000000000003 and you ceil to 176.

**Kalshi publishes two BID ladders, not a bid and an ask.** `yes_dollars` is what
people pay for YES; `no_dollars` is what people pay for NO. **A NO bid at 62c is a
YES offer at 38c.** Reading `no_dollars` as an ask ladder reports asks below the
bid and inverts every capacity number.

**Sign the path WITHOUT the query string.** Kalshi RSA-PSS signs
`<timestamp_ms><METHOD><path>`. Including `?depth=10` gives a bare 401 that tells
you nothing about which half was wrong.

**Capacity from the public endpoint is wrong by ~74x.** Top-of-book showed 420
contracts. Authenticated depth showed a median of **31,264 contracts within 5c**.
I made a wrong call on this once — do not size off the public book.

**Persistence is a doubt signal, read backwards.** Real settled facts get taken
fast (Miami: 70 seconds). False ones sit there forever (LAX: 2,205s, then
17,299s). **A long-lived "opportunity" is evidence our model is wrong**, not
evidence the market is slow. `MAX_PERSISTENCE_SECONDS = 300` is PROVISIONAL and
rests on a single observed genuine episode.

**"Settles at 05:59Z" is when trading stops**, not when the result posts. Weather
resolves after the NWS Climatological Report publishes, which is materially
later.

**We read METAR; weather settles on the NWS CLI report.** That basis risk is
**unverified**. Same class of risk as crypto's unnamed index. This is the single
most likely way the whole weather track turns out to be fake.

**PortWatch's `start_date`/`end_date` are silently ignored.** Four different days
returned byte-identical output and it looked like working date filtering.

**trumpstruth.org has the same bug** — `start_date`/`end_date` ignored, its own
next-cursor stalls and repeats page 2 forever, and permalinks appear **twice per
post** so a naive scan double-counts. Build cursors yourself:
`base64({status_created_at, _pointsToNextItems: true})`.

---

## 5. Eliminated — do not re-investigate without new information

```
econ releases       market closes 1-5 min BEFORE the data lands
sports              repriced in 1.6s
mentions            2-4s
politics            KXTRUMPACT farmed at 338ms
elections           not monotone, and mostly botted
financials          most-watched number on earth
crypto one-touch    settles on CF Benchmarks RTI, NOT Coinbase spot — DISABLED
Hormuz / shipping   MA 3.86 vs threshold 60, never close.
                    Also: price LEADS shipping data by 1-2 weeks (corr +0.44)
commodities / transportation / world / health / social
                    dead or zero markets
```

**Surviving: weather (19 cities, highs + lows) and Truth Social post count.**

---

## 6. Two things are deliberately switched off

**The touch family is disabled.** `KXBTCMINMON` / `KXBTCMAXY` / `KXETHMINMON` /
`KXETHMAXY` settle on **CF Benchmarks Real Time Index**, not Coinbase spot, which
is what `price_extremes.rb` reads. Different number, unknown divergence. The user
said "disable the touch family until we sort out RTI." **Disabled is treated as a
normal state, not an error** — do not re-enable to "fix" a warning.

**21 of 28 weather stations are prediction-only.** 12 unverified highs and 9
unverified lows are recorded but never traded. They get promoted or dropped based
on scored settlement results, not on looking reasonable.

---

## 7. The funding gate — where we actually stand

Full text in `docs/funding-gate.md`. It was written **before** the evidence
arrived, on purpose, so it cannot be moved to fit the result. The user has said
they would fund **$2-5k from their BTC wallet if we show an edge**. Current
account: **$250**, which is enough to prove one.

```
1. model accuracy      >=30 scored calls, >=95% correct    PENDING  16 recorded
2. opportunity rate    >=1 tradeable/day over 7+ days      FAILING  0.00/hr @ 6.5h
3. fill quality        >=10 orders, >=80% at-or-better     UNBUILT
4. net positive        cumulative PnL > 0 after fees       BLOCKED on #3
5. no single-event dominance                               BLOCKED on #3
```

**Item #3 is the only one polling cannot answer.** A resting quote and a fillable
quote are different things, and every measurement so far has assumed they are the
same. The user has **already approved building the execution layer, dry-run
first**. It is not built.

**Item #2 is what decides whether any of this is real.** The two flagged
candidates so far (LAX, SATX) both persisted ~5 hours at 99% market disagreement,
which per section 4 reads as our model being wrong, not the market being slow.
More scan hours is the only thing that moves it, and that is already running.

Kill criteria are in the gate doc. Respect them — the instruction is *stop and
rework*, not *tune*.

---

## 8. Immediate next actions

**Today / tomorrow morning, on exo-mini:**

```bash
ruby bin/score_predictions predictions/2026-08-04.jsonl        # 34 calls
DATA_DIR=~/kalshi-data ruby bin/analyze_opportunities
```

Scoring is what promotes or drops the 21 unverified stations. Until it runs, we
do not know whether the unverified two-thirds of the station list is signal.

**Through Aug 9 — Truth Social calibration.** The rules say *"Aug 2 to Aug 8"*
with **no timezone**, and it is unclear whether retruths and replies count. Either
ambiguity is worth more than a whole bucket. So: accumulate the count, compare to
actual settlement on Aug 9, and only then decide if it is tradeable. `bin/truth_count`
is currently **one-shot** — folding it into the continuous collector is unstarted.

Last live run reconciled cleanly: our count of **126** refuted exactly the three
buckets the book had already zeroed (`<80`, `80-99`, `100-119`) and no more.

**Approved but unstarted: the execution layer, dry-run first.** This is gate item
#3 and the user listed it explicitly as item 2 of a two-item plan. Item 1
(continuous scanning) is deployed and running.

**Open side thread — verifying the Instagram claim.** Offered to the user, not yet
answered. Free checks needing nothing: does Polymarket even run 5-minute
BTC/ETH/SOL markets (shortest known is hourly); the public leaderboard ("#1
GLOBAL, beating 8,447 traders" is directly checkable);
`data-api.polymarket.com/value?user=0x...` is public and needs no auth. Blocked on
the **full 42-char address** — the screenshot shows two conflicting partials
(`0x9f5f...605528` and `0x9f5f...671a008`) and neither is complete. Also note the
image claims 64 days at $250,248 while the earlier post claimed 64 days at
$220,000, and the `VERIFIED` badge is rendered by their own dashboard.

---

## 9. Standing instructions from the user

**Style: `/caveman`.** Terse. Technical substance stays, fluff dies. Drop
articles, filler, pleasantries, hedging. Suspend it for security warnings and
irreversible-action confirmations.

**Method: `/tdd`, strictly.** Vertical slices only — one test, then one
implementation, then repeat. **Never** write all tests then all code; that is
horizontal slicing and it produces tests that verify imagined behavior.

**Mutation-test every fix.** The standard here is proving the spec
*discriminates*, not that it passes. Two ways this has gone wrong:

- A constant fixture cannot detect lookahead. `bars[0..i]` -> `bars` survived
  because every range in the fixture was 2.0. Fix: vary the data (calm 1, storm 20).
- A spec helper doing `peak || net_pnl` turns an explicit `nil` into a value, so
  the nil case is never tested. Fix: an `unset` sentinel.
- Deleting a line breaks leading-dot method chains, and the syntax error reads as
  "SURVIVED." Use no-op mutations like `.reject { |o| false }` and run `ruby -c`.

**Open a PR per fix, with automerge.**

**Use the `/browse` skill for all web browsing.** Never call
`mcp__claude-in-chrome__*` directly.

**Ruby is 3.2.4 via RVM gemset `3.2.4@coinbase_futures_bot`.** tzinfo lives in the
gemset, not in the bare ruby.

**`gh auth switch --user Skeyelab`** before any issue or PR write. The default EMU
account is blocked.

---

## 10. Security constraints — these are not optional

**All Kalshi research code is GET-only. There is no order path.** This is
deliberate and stated in the README and the commits: *a misused key cannot place a
trade through it.* When you build the execution layer, keep the read path
separate rather than adding a write method to the existing client.

**Never ask the user to paste a secret into the chat.** Doppler only. Earlier in
this project a Coinbase private key was leaked into a transcript by printing an
object's `inspect`. That is why `RedactedInspect` exists.

**On exo-mini, print exception CLASSES only, never messages.** `RedactedInspect`
is **not deployed there**, and a `NoMethodError` message embeds the receiver's
`inspect` — which is how a key ends up in a log.

**Secrets come from Doppler at runtime** (`doppler run --only-secrets ...`) and are
never written to disk on exo-mini. The systemd unit comment records why: *there
are already four .env.bak files here holding private keys; this does not add a
fifth.*

**Outstanding, flagged, not acted on:** four `.env.bak-*` files on exo-mini hold
plaintext private keys. Deleting them is destructive and is the user's call.

**Outstanding, unexplained:** a credential `4842caa7` under org `cf2ba8a1` still
authenticates and the user does not recognise it. The bot had been authenticating
against that unknown org for an entire session before it was caught. Ask the app
directly (`source=env, in_use_key=...`) rather than grepping config — that is how
it was found.

---

## 11. Other open threads

- **`DEPLOYED_SHA` is the authority on exo-mini**, not the git checkout there. The
  checkout is not what runs.
- **NOL long 2 on Coinbase**, expiring Aug 19, cash-settles. User chose "leave it,
  flag the expiry." Auto-roll is opt-in and not guaranteed.
- **`posthog-setup-report.md`** and **`.claude/worktrees/`** are untracked in the
  working tree.

---

# Handoff — 2026-08-05

Everything above was written 2026-08-04 and is still broadly right about the
*thesis*. Sections 2 (current state), 7 (gate status) and 8 (next actions) are
superseded by this. Read this part second, not instead.

## The one-line summary

The track now lives on main with CI, the write path is proven live against
real money, and three separate edge claims were killed by measurement. Nothing
was promoted. That is a good day by this project's own standard.

## What changed

**The track is on main.** `research/kalshi_latency/` merged in #634, with a CI
job running its 271 specs on every PR. Until today it lived only on
`research/kalshi-repricing-latency`, which had never had a PR to main.

**`research/**` PRs had been running ZERO CI.** The workflow filter was
`[main, feat/**]`, so a PR into a research branch matched no workflow, sat at a
clean status and merged the instant automerge was requested. That is how an
order-placing execution layer shipped unchecked (#618), on a branch also
pinning a Rails with a published RCE advisory. Fixed on main in #621 and on the
branch in #619.

**The write path was aimed at a retired endpoint.** `POST /portfolio/orders`
returns `410 deprecated_v1_order_endpoint`. Ported in #622:

```
api.elections.kalshi.com  ->  external-api.kalshi.com
/portfolio/orders         ->  /portfolio/events/orders   (create + cancel)
                          ->  /portfolio/orders/{id}     (read -- no "events")
action + side: yes|no     ->  side: bid|ask
yes_price: 12             ->  price: "0.1200"  (fixed-point dollars, STRING)
count: 25                 ->  count: "25.00"   (STRING)
                          ->  time_in_force, self_trade_prevention_type required
{"order":{...}}           ->  flat 201 body, order_id at top level
```

**v2 quotes every order from the YES leg.** There is no yes/no field any more,
so exiting a NO holding is a BID, not a sell. Getting that backwards doubles a
position instead of closing it.

Every dry-run test passed through all of this, because dry-run never touches
the network. The fakes faithfully reproduced an API that no longer existed.

## Live execution now works, and cost about 1c to prove

Open, watch, cancel and close all verified against the real venue. Three
fill-quality probes (1 contract, limit at the bid, 60s window):

```
NY  B82.5 @ 57c   unfilled, cancelled
CHI B83.5 @ 27c   FILLED at 27c -- is_taker: true, we CROSSED
MIA B90.5 @ 43c   unfilled, cancelled
close: sold 1 @ 26c. Round trip -1c + fees. Flat.
```

**Nothing rested and got hit inside 60 seconds** on 1c-spread books. The one
fill was us taking an offer. That is the distinction gate item 3 exists to
make and no amount of polling would have shown it. See #631 — `is_taker` must
be recorded or ten crossed orders would satisfy the gate's wording while
answering none of its question.

Two defects in the gate-3 metric, both found only by trading: the venue
reports fill cost in COLLATERAL, so a sale at 26c was logged as 74c and
`at_or_better` compared `74 >= 26` and passed trivially; and `at_or_better`
keyed off `intent[:action]`, which the v2 port deleted, so nil never equalled
"buy" and every order was scored with the sell rule.

## Station verification: built, day 1 of 3 done

21 stations could never have been promoted, for two independent reasons.
Scoring persisted nothing, and the stated test could not discriminate — nearly
every bucket settles NO, so every candidate agrees and none is distinguished.
2026-08-04 reproduced that exactly: 34 scored markets, all refutations.

`StationEvidence` now counts only days where rivals DISAGREE, settlement
referees, and promotion needs **zero misses across >= 3 separate such days** —
stated before the evidence, funding-gate style. `StationCandidates` supplies 3
rivals per series, all 45 ids verified live against api.weather.gov.

First real day, after fixing a mapping bug that had scored half the board
backwards (#632):

```
8 discriminating markets on 2026-08-04
incumbents: 8 wins, 0 losses     promotable: []  (correctly -- needs 3 days)
KMSP over KFCM   KMSY over KHUM   KSFO over KHWD   KATL over KFTY+KPDK
KMDW over KPWK   KOKC over KPWA+KTIK   KLAS over KVGT   KPHL over KPNE+KILG
```

Every station cities.rb guessed has been right every time a rival disagreed.

**A daily cron now runs this on exo-mini at 13:00 UTC for the previous day**,
writing to `~/kalshi-data/`. Day 2 lands 2026-08-06, day 3 on the 7th.

## Gate status — item 1 FAILS, and the old number was a rounding artifact

```
1 model accuracy    FAILS    32/34 = 94.12% vs a >=95% bar
2 opportunity rate  FAILS    0.00 credible/hr
3 fill quality      PARTIAL  3 orders live, 1 fill, is_taker gap (#631)
4 net positive      BLOCKED on 3
5 no single-event dominance   BLOCKED on 3
```

The collector rewrites a ticker every cycle it still looks callable, so
2026-08-04's "79 calls" were **34 distinct markets** — a 2.3x inflated
denominator. `bin/score_predictions` now counts markets and persists them.

Accuracy split perfectly by whether the book agreed: **32/32 correct where it
agreed, 0/2 where it disagreed.** The model is wrong exactly where it already
refuses to trade. Whether gate 1 should therefore score tradeable calls only is
#628 — and per the gate's own rules that must be declared prospectively, never
applied backwards.

## The ensemble pricer lost. Hypothesis falsified, not merely unproven

The NBM ensemble model was scored against real market prices over 292
station-days / 73 dates (#639):

```
                ours      market
log loss       1.4015    1.1039     delta +0.2976, CI [+0.2288, +0.3727]
Brier          0.7032    0.5966
we win         71/292 days (24%)
```

The thesis was "the market prices off the point forecast and misprices the
tails". It does not: the market is better centred (1.29F vs 1.74F) AND sharper
(implied sd 1.83 vs 2.43). Our distribution is calibrated but WIDE, and mushy
loses to sharp under every proper scoring rule. We *overprice* tails by more
than the market underprices them.

**The line to remember:** sorted by how far we disagree with the market, our
deficit GROWS — +0.13 low tercile, +0.27 mid, +0.49 high. Our disagreement
measures our error, not the market's slowness. That is section 4's doubt signal
generalised from the ratchet to the pricer.

Do not build section 8 of that report. REPORT.md is corrected in place with the
error left legible.

## New capabilities and facts found today

- **Kalshi publishes a rolling ~73 days of public price history**:
  `GET /markets?status=settled` plus
  `GET /series/{s}/markets/{t}/candlesticks` (hourly yes_bid/yes_ask),
  unauthenticated. That answered in a day what 30 days of forward recording
  would have, with 4x the sample. General backtesting capability; bears on
  gate 2. The window rolls and cannot be recovered retroactively.
- **Settlement basis verified 292/292 exact** — `expiration_value` equals the
  IEM CLI high on every event. For a CLI-targeted model the METAR-vs-CLI basis
  risk in section 4 does NOT apply. (It still applies to METAR-driven models.)
- **Kalshi perps are live on this account** — 16 crypto perps, 2-6x leverage,
  funding rates, separate margin wallet (currently $0). Promo fees taker
  0.040% / maker 0.020%; launch rate taker 0.120%, which is WORSE than
  Coinbase's observed ~0.102%. See #630.
- **15-minute commodities settle on Pyth** 1-minute candle closes — a public,
  readable feed, so the CF-Benchmarks trap that disabled the touch family does
  not apply. But the shape is wrong: close-at-T+15 vs close-at-T is terminal
  value, not monotone, so nothing is ever already-determined. See #629.

## Traps learned today, in addition to section 4

- **`strike_type` lies, and so does the ticker prefix.** `T84` on KXHIGHTSEA is
  a CAP ("83 or below"), not a floor. Misreading it made a correct METAR
  observation look like a 4-5F basis divergence. The series is the authority.
- **`:open` at end of day is not one answer.** It depends on the market: a high
  that never got there refutes "reach this level" and CONFIRMS "stay below it".
  A blanket rule scores half the board backwards.
- **exo-mini's scanner runs from `~/kalshi-scan/`, NOT
  `~/coinbase_futures_bot/`.** The unit in `deploy/` is wrong about both the
  path and DATA_DIR. That checkout is 15 commits behind with 41 uncommitted
  files, so nothing describes what runs there. See #642.

## Open issues

```
#624  write promoted stations back into cities.rb   <- next, after day 3
#625  halt switch (before anything trades unattended)
#626  Executor dedup must survive a restart
#627  fill-quality probe protocol
#628  gate 1 denominator + tradeable-only question   <- operator decision
#629  does the book lag Pyth on 15-min commodities?
#630  Kalshi perps vs Coinbase venue comparison
#631  record is_taker per fill                       <- gate 3 unmeasurable without
#637  ensemble pricer (closed against us, kept for the record)
#638  lead-bin boundary off-by-one, Ruby vs Python
#642  exo-mini unreproducible checkout
```

## What to do next

**Friday 2026-08-07** is the decision point. Three days of evidence either
promotes stations or does not. If it does, the `station unverified` doubt
disappears from 7 of every 11 daily refusals — and that is the first time this
system would have something credible to trade. The cron runs itself; just read
`~/kalshi-data/candidates-*.jsonl` and run the tally.

Do NOT trade the flagged candidates in the meantime. Both current ones carry
`market disagrees` — the exact shape the model went 0/2 on.

## Standing instructions unchanged

Section 9 above still holds: caveman style, strict TDD with vertical slices,
mutation-test every fix, PR per fix, `/browse` for web, RVM 3.2.4 gemset,
`gh auth switch --user Skeyelab`. Section 10's security constraints still hold
— note the read/write split survived the v2 port: `KalshiClient` is still
GET-only and all ordering lives in `Execution::OrderClient`.
