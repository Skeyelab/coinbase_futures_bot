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
