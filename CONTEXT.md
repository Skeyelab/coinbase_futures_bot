# Domain Context

## Glossary

### Basis
The price spread between a futures Contract and the underlying spot price. Checked as a pre-entry gate — if basis is unfavorable, the bot skips entry. Threshold is a parameter of the Risk Profile. Not tracked per-Position after entry.

### Confidence
A 0–100 score on a Signal representing combined certainty. Starts as a technical score (EMA alignment across timeframes, pattern clarity), then adjusted up or down by Sentiment. The Risk Profile defines a minimum threshold — Signals below it do not trigger entry.

### Contract
A specific tradeable futures instrument on Coinbase, identified by product ID (e.g. `BIT-27JUN26-CDE` for BTC, `NOL-19JUN26-CDE` for crude oil). Covers both crypto and commodity underlyings. Dated Contracts carry an expiry date and the bot manages rollover before expiration; a Perpetual Future has neither. Maps to the `TradingPair` model (legacy name — industry term is Contract).

### Day Trade
A Position tagged at entry as intraday — must be closed within 24 hours. The bot auto-closes these via `EndOfDayPositionClosureJob` to maintain compliance. A per-Position property; day trades and swing trades can coexist.

### Funding Rate
A periodic payment exchanged between longs and shorts on a Perpetual Future. A position-time cost — charged only when a funding timestamp is crossed while holding a Position, never a fill cost. Not yet modeled; rates are snapshotted live under [#391](https://github.com/Skeyelab/coinbase_futures_bot/issues/391) because funding history is not reconstructible. Must be modeled before the cost gate certifies any perp.

### Order
An instruction sent to Coinbase to buy or sell a Contract. First-class domain concept — stored and tied to the Position it opens or closes. Enables slippage auditing (actual fill price vs Signal target), execution reconstruction after outages, and full trade lifecycle traceability. Currently not modelled in the code; the `Position` model tracks entry/exit prices but not the underlying exchange orders.

### Paper Trading
A whole-bot simulation mode where Signals are evaluated and Positions tracked but no real orders are placed on Coinbase. Used to validate a Strategy or Risk Profile before going live. All Contracts trade in paper mode simultaneously — mixed paper/live operation is not supported.

### Perpetual Future
A Contract with no expiry date and therefore no Rollover; longs and shorts exchange a Funding Rate instead. The adopted primary Venue per ADR 0002 — BIP (nano BTC perp) first, XPP (XRP perp) the designated second seat. Not yet traded live: candidates stay suspended for data collection until they pass their gates (see Suspension-until-gates).

### Position
The open futures exposure held by the bot — either LONG or SHORT. Represents the full round-trip lifecycle: opened when an entry order fills, closed when an exit order fills. Tracks entry price, exit price, side, PnL, stop-loss target, and take-profit target. Industry standard term; maps to the `Position` model.

### Risk Profile
A named, versioned set of capital and risk parameters: take-profit target, stop-loss target, risk fraction, position size limits, confidence thresholds. Answers *how much* to trade and *at what risk*. Only one profile is active at a time; the bot falls back to environment variables if none is active. Maps to the `TradingProfile` model.

### Rollover
The operational process of closing a Position on a near-expiry Contract and switching to the next Contract. Triggered by calendar (N days before expiry) — not a trading decision. Whether a new Position opens on the replacement Contract depends solely on whether the Strategy generates a fresh Signal.

### Sentiment
A scored measure of market mood for a given underlying, derived from news and event feeds. Feeds into Signal confidence as a soft input — does not gate entries independently. Sources are asset-specific: crypto-focused feeds (e.g. CryptoPanic) for crypto contracts; macro/geopolitical feeds (e.g. Reuters, EIA reports) for commodity contracts. Maps to `SentimentEvent` (raw) and `SentimentAggregate` (time-windowed z-score summaries).

### Signal
A candidate trade opportunity produced by a Strategy. Carries a side (LONG/SHORT), signal type (entry/exit/stop-loss/take-profit), confidence percentage, and timeframe. A Signal may expire or be cancelled without ever opening a Position. Maps to the `SignalAlert` model.

### Strategy
The algorithm that analyzes market data and produces Signals. Answers *when* to trade — entry and exit conditions, timeframe logic, confidence scoring. Distinct from Risk Profile. Maps to the `Strategy::*` service classes.

### Suspension-until-gates
The enablement pattern for new symbols (the ETH precedent): a symbol is enabled for data collection but suspended from trading (`Trading::SymbolSuspension` — blocks new entries only) until it passes its own walk-forward calibration and net-of-costs gate. No evidence inheritance — edge measured on one Contract does not transfer to another. Resume is always manual; a symbol re-earns its slot.

### Swing Trade
A Position with no intraday closure requirement. Held across days until stop-loss, take-profit, or manual exit. A per-Position property; contrast with Day Trade.

### Timeframe
The candlestick resolution used by a Strategy. Coinbase futures contracts (`BIT-*`, `ET-*`, `NOL-*`) support **all nine Advanced Trade API granularities**: 1m, 5m, 15m, 30m, 1h, 2h, 4h, 6h, 1d. The constraint is a hard limit of **350 candles per request** — not the granularity itself. Requests exceeding 350 candles return 400. Safe single-request windows: 1m ≤5h50m, 5m ≤1d10h, 15m ≤3d14h. The `FetchCandlesJob` uses chunked fetching (5h for 1m, 24h for 5m, 3d for 15m) to backfill longer periods. The same supported timeframe set applies to all underlyings (BTC, ETH, oil) — there is no per-underlying restriction. Resolved by [#195](https://github.com/Skeyelab/coinbase_futures_bot/issues/195).

### Underlying
The asset a Contract is based on — e.g. BTC, ETH, crude oil. A first-class grouping concept: Contracts sharing the same Underlying share sentiment sources, Strategy configuration, and Risk Profile assignment. Rollover moves between Contracts within the same Underlying. Not currently a model in the code — parsed implicitly from the Contract product ID prefix.

### Venue
The class of instrument the bot trades — spot, dated futures, or perpetual futures. Chosen for cost structure, not signal quality. ADR 0002 makes perpetuals primary, demotes dated futures to legacy plus a commodities research tier (GOL/SLR, revisited at ≥$10k equity), and rejects spot. Live trading today still runs on dated Contracts pending migration.
