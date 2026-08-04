# Kalshi repricing latency

Answers one question before we build anything:

**When a Kalshi market reprices, how long do you have to get in?**

If half the move lands in 5 seconds, news-latency arbitrage on Kalshi is dead
for us and we stop. If it takes 5 minutes, there's a window a slow bot can hit
and it's worth building. Everything else — news parsing, order routing,
sizing — is wasted effort until this number exists.

## Why this and not more Coinbase work

Measured on 2026-08-02: the BTC perp strategy's gross edge is 13.9 bps/trade
against a 20.35 bps round trip. Negative after costs. Moving venues buys maybe
10 bps, which is not the problem — the edge is too thin for any venue.

Kalshi fees are *far worse* in bps terms (~175 bps round trip at a 50c
contract, 17x Coinbase). That is the point. A fee that large only matters if
the edge is small. If news moves a contract 20 cents, fees are noise. This
experiment tests whether that fat, fee-insensitive edge shape exists here.

## Two experiments in here

**1. Settled-fact scan (the sharp one).** `bin/scan`, `bin/collect_weather`,
`bin/analyze_dwell`.

Kalshi's daily-high temperature markets resolve on NWS observations, which are
public and machine-readable. Because a running daily maximum only ever goes up,
each new observation is a one-way ratchet:

- it **refutes** every bucket below it, permanently, worth 0
- it **confirms** every floor market at or under it, worth 100
- it can never confirm a bucket early or refute a floor early

So once Miami hits 90F, the 88-89 bucket is worth exactly zero. Anyone still
bidding for it is paying for a fact the NWS already published. No forecasting,
no judgement, no NLP — compare a number to a number.

Seven cities publish hourly at a known minute past the hour (KNYC :51, KMDW
:25, KMIA/KLAX/KPHL :20). That is roughly 100 scheduled information events per
day, each with a known timestamp. Beating a scheduled public release is a much
easier game than finding breaking news.

**2. Generic move-duration scan (the broad one).** `bin/collect`, `bin/analyze`.
Samples the whole liquid market list plus RSS headlines and measures how long
any repricing takes. Keep it running as the control.

## Observed once, live

On 2026-08-04 at 15:54Z the scanner flagged `KXHIGHMIA-26AUG04-B88.5` bidding
5c while Miami's running high was 89.6F (rounds to 90, above the 88-89 bucket).
By 15:55Z the bid was 0. The market independently converged on the same answer,
which validates the logic — but a single ~70s observation says nothing about
the distribution. That is what `bin/collect_weather` is for.

## Safety

Read-only and GET-only. There is no order path in this code, so a misused key
cannot place a trade through it. No gems, no shared code with the trading bot.

Credentials are OPTIONAL. Without them the collector uses public endpoints and
records top-of-book only. With `KALSHI_KEY_ID` / `KALSHI_KEY` it also records
full order book depth, which is the difference between guessing at capacity
and measuring it:

```bash
doppler run --only-secrets KALSHI_KEY_ID,KALSHI_KEY -p ericdahl-dev -c prd -- bin/collect
```

## Capacity: measured 2026-08-04

Top-of-book is NOT depth, and the gap is not small:

```
median top-of-book         420 contracts
median depth within 5c   31,264 contracts      74x
```

Dollar depth on the busiest books, bid side within 5c:

```
KXGOVFLNOMR-26-BD       97.7/97.8    $144,571
KXSENATEMID-26-AELS     98.2/98.3    $107,113
GOVPARTYTX-26-D         12.0/13.0     $51,841
KXFEDDECISION-26SEP-H0  48.0/49.0     $50,522
```

An earlier read of this repo said capacity was the thing most likely to kill
the idea. That was measured from the public endpoint's top-of-book and was
wrong by roughly two orders of magnitude. Capacity is not the binding
constraint for a small stake. Reaction WINDOW still might be -- that is what
`bin/analyze_dwell` is for, and it has not been run.

Note these are the busiest markets, which are political. The weather markets
that carry hourly scheduled information have not had their depth measured yet.

## The payrolls experiment (Friday 2026-08-07, 08:30:00 ET)

The sharpest test of the whole thesis, because it has all three properties at
once: an exact publication time, a machine-readable primary source, and a deep
book ($22,683 within 5c on the top strike).

```bash
# start ~5 minutes early; runs 10 minutes by default
doppler run --only-secrets KALSHI_KEY_ID,KALSHI_KEY -p ericdahl-dev -c prd -- \
  bin/record_payrolls

bin/analyze_release
```

Records the BLS release page and the Kalshi book on ONE clock at 1s
resolution, because the measurement is a subtraction and two loops with
independent clocks cannot resolve a gap smaller than their jitter.

Measured round trips on 2026-08-04: BLS 97ms, Kalshi order book 55ms, whole
tick ~156ms against a 1s budget.

Reading the result:

- **t_90 <= 2s** - no window. The book absorbed it inside one poll. You would
  be racing machines, and no amount of retail tuning fixes that.
- **2-15s** - real but tight. Needs a pre-armed order, not a decision.
- **>15s** - reactable by a script that was already watching.

Two honest limits. Publication detection is a LATE bound: the figure was public
up to one poll interval before we saw it, so every window is a floor. And BLS
serves through a CDN, so our observation is when *this client* could see it,
not when it hit the wire.

## Run

```bash
bin/scan                     # one-shot: anything mispriced right now?
bin/collect_weather          # continuous settled-fact logging
bin/analyze_dwell            # how long do mispricings last?

bin/collect                  # broad control: all liquid markets + RSS
bin/analyze                  # generic move-duration verdict
```

Config via env: `DATA_DIR`, `QUOTE_INTERVAL` (5s), `NEWS_INTERVAL` (30s),
`MIN_VOLUME_24H` (1000), `WATCHLIST_SIZE` (150), `REDISCOVER_EVERY` (3600s),
`THRESHOLD_CENTS` (5, analyze only).

Let it run at least a week. Two is better — the interesting moves are rare and
event-driven, and a quiet week proves nothing.

## Long run on exo-mini

```bash
cp deploy/kalshi-latency.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now kalshi-latency
journalctl --user -u kalshi-latency -f
```

## What it writes

`data/` gets three JSONL streams, one file per UTC day:

- `quotes-*.jsonl` — top of book per market per tick: `mid`, `bid`, `ask`,
  `bid_size`, `volume_24h`
- `news-*.jsonl` — headlines with our `first_seen_at`
- `watchlist-*.jsonl` — which markets were being sampled and why

News is **not** matched to markets during collection. Matching is a judgement
call that will change once we see the data, and baking it in would mean
discarding weeks of samples every time we revise it.

## Reading the output

`bin/analyze` reports the reaction window, move sizes, book depth at the moment
each move started, and how many moves clear Kalshi's fee.

Three things to look at, in order:

1. **Median seconds-to-half.** Under ~10s, stop; there is nothing to react to.
2. **Capacity.** Depth at top of book when moves start. A 6-minute window on a
   book that holds $200 is a hobby, not a business. This is the number most
   likely to kill the idea — prediction market books are thin, and the viral
   $220k claim is hard to reconcile with them.
3. **Share of moves clearing fees.** At 175 bps round trip, small moves lose.

## Known bias

RSS is slow. A headline can be minutes old before it hits a feed, so our
`first_seen_at` is a **late** bound on when news actually broke. That biases
every news-paired measurement *against* finding an edge — markets will look
like they moved before we knew.

So: a positive result is trustworthy, a negative result is inconclusive. If the
windows look long even with RSS, a real low-latency feed only widens them.

The primary metric (move duration) does not depend on news matching at all,
which is why it's the one the verdict is built on.

## API notes

Two things cost an afternoon to discover:

- `GET /markets` is useless for discovery. It returns tens of thousands of
  auto-generated `KXMVE*` combination markets before any real one — 25,000
  markets deep and still only 11 non-combos. Real markets come from
  `GET /events?with_nested_markets=true`.
- Every numeric field is a **string**, and prices are in **dollars**
  (`"0.4200"`), not cents. `Watchlist.normalize` converts.

Public endpoints, no auth needed. An API key would unlock the WebSocket feed,
which would sample far faster than 5s polling — worth doing if the first pass
looks promising.

Daily-high markets are **buckets**, not thresholds:

```
B83.5   strike_type=between   floor=83  cap=84   "83° to 84°"
T88     strike_type=greater   floor=88           "89° or above"
T81     strike_type=less                cap=81   "80° or below"
```

## Settlement risk to respect

- **Whole degrees.** Kalshi settles on the NWS *Climatological Report (Daily)*,
  which publishes whole degrees. 89.4F is an 89 degree day. `TempMarket`
  rounds before comparing; doing otherwise invents an edge in every
  half-degree band. This was a real bug caught by a test, not theory.
- **CLI vs METAR basis.** We read hourly METAR observations, but settlement is
  the daily climate report from the local forecast office. They usually agree.
  Usually is not always, and the gap is unhedged.
- **Station identity.** Every station in `lib/cities.rb` was read out of the
  market's own rules text. Chicago is Midway, not O'Hare. Denver's rules say
  only "Denver, CO"; KDEN is the official climate site but that one is an
  inference, not a quote.

## Tests

```bash
BUNDLE_GEMFILE=../../Gemfile bundle exec rspec
```

`MoveAnalysis`, `Watchlist`, `TempMarket`, `DailyHigh` and `Opportunity` are
unit tested (42 examples) and mutation tested — 28 mutations, all killed. Two
survivors along the way were real spec gaps (a masked one-sided-quote guard, a
missing nil running high) and one was genuinely dead code that got deleted.

The HTTP and file plumbing is not unit tested; it was smoke tested live against
the real APIs instead.
