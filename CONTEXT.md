# Domain Context

## Glossary

### Basis
The price spread between a futures Contract and the underlying spot price. Checked as a pre-entry gate — if basis is unfavorable, the bot skips entry. Threshold is a parameter of the Risk Profile. Not tracked per-Position after entry.

### Confidence
A 0–100 score on a Signal representing combined certainty. Starts as a technical score (EMA alignment across timeframes, pattern clarity), then adjusted up or down by Sentiment. The Risk Profile defines a minimum threshold — Signals below it do not trigger entry.

### Contract
A specific tradeable futures instrument on Coinbase, identified by product ID (e.g. `BIT-29AUG25-CDE` for BTC, `NOL-19JUN26-CDE` for crude oil). Covers both crypto and commodity underlyings. Carries an expiry date; the bot manages rollover before expiration. Maps to the `TradingPair` model (legacy name — industry term is Contract).

### Day Trade
A Position tagged at entry as intraday — must be closed within 24 hours. The bot auto-closes these via `EndOfDayPositionClosureJob` to maintain compliance. A per-Position property; day trades and swing trades can coexist.

### Order
An instruction sent to Coinbase to buy or sell a Contract. First-class domain concept — stored and tied to the Position it opens or closes. Enables slippage auditing (actual fill price vs Signal target), execution reconstruction after outages, and full trade lifecycle traceability. Currently not modelled in the code; the `Position` model tracks entry/exit prices but not the underlying exchange orders.

### Paper Trading
A whole-bot simulation mode where Signals are evaluated and Positions tracked but no real orders are placed on Coinbase. Used to validate a Strategy or Risk Profile before going live. All Contracts trade in paper mode simultaneously — mixed paper/live operation is not supported.

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

### Swing Trade
A Position with no intraday closure requirement. Held across days until stop-loss, take-profit, or manual exit. A per-Position property; contrast with Day Trade.

### Timeframe
The candlestick resolution used by a Strategy. Coinbase futures contracts (`BIT-*`, `ET-*`, `NOL-*`) support **15m, 30m, 1h, 2h, 6h, 1d** via the Advanced Trade API. ONE_MINUTE and FIVE_MINUTE are valid API enum values but return 400 for futures product IDs — they only work for spot products (BTC-USD, ETH-USD) on the Exchange API (`api.exchange.coinbase.com`) with integer-second granularity. The same supported timeframe set applies to all underlyings (BTC, ETH, oil) — there is no per-underlying restriction. Timeframe configuration is therefore global, not per-Underlying. Resolved by [#195](https://github.com/Skeyelab/coinbase_futures_bot/issues/195).

### Underlying
The asset a Contract is based on — e.g. BTC, ETH, crude oil. A first-class grouping concept: Contracts sharing the same Underlying share sentiment sources, Strategy configuration, and Risk Profile assignment. Rollover moves between Contracts within the same Underlying. Not currently a model in the code — parsed implicitly from the Contract product ID prefix.
