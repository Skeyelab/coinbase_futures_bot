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

## Safety

Read-only. No credentials, no order placement, no gems, no shared code with
the trading bot. It cannot touch a position even if it crashes.

## Run

```bash
bin/collect                  # samples into ./data, Ctrl-C to stop
bin/analyze                  # prints the verdict
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

## Tests

```bash
BUNDLE_GEMFILE=../../Gemfile bundle exec rspec
```

`MoveAnalysis` and `Watchlist` are unit tested and mutation tested (13
mutations, all killed). The HTTP and file plumbing is not — it was smoke
tested live instead.
