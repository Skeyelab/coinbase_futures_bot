# ADR 0003: Adopt freqtrade Risk & Exit Machinery (Port Logic, Not Framework)

**Date:** 2026-07-22
**Status:** Accepted

## Context

The live path is a single strategy — `Strategy::MultiTimeframeSignal`, a 1h-trend → 15m/5m/1m-aligned EMA trend-follower with fixed-bps TP/SL, a risk-fraction sizer, a trailing-stop calculator, a durable `TradingHalt`, and a per-symbol *cost* circuit breaker (`SymbolCircuitBreakerJob`). We also carry an event-driven backtester, walk-forward, and a grid-search `CalibrationJob` (objectives `total_pnl` / `drawdown_penalized`). A second engine — `MarketAnalysisService` (RSI/MACD/Bollinger multi-factor scoring) — exists but is wired only to chat/AI advice, **not** to order placement.

We surveyed [freqtrade](https://github.com/freqtrade/freqtrade) (docs + the `freqtrade-strategies` and `technical` repos) for strategies and analysis algorithms worth reusing. Findings:

- Freqtrade is Python, vectorized (signal-at-close / execute-next-open), and **Coinbase perps are not a first-class freqtrade futures venue** — so there is no adapter or strategy to copy-paste. The transferable value is *logic and risk framework*, reimplemented natively in Ruby.
- Its **strategy library** is mostly mean-reversion (`BbandRsi`, `BinHV45`/Cluc squeeze-bounce) and confirmed-momentum (`ADXMomentum`, `Supertrend`) — different regime exposure from our lone trend-follower, and each is trivially expressible in our existing backtester.
- Its highest-value assets are **engine-level, strategy-agnostic risk mechanisms** we do not have: a **protections** layer (`CooldownPeriod`, `StoplossGuard` with `only_per_side`, `MaxDrawdown` on the equity curve), a **minimal-ROI time-decay** exit table, a `custom_stoploss` adaptive-stop callback, a **liquidation-buffer** pre-exit for leveraged positions, pluggable **risk-adjusted hyperopt loss** (Sortino/Calmar), and DCA/`adjust_trade_position` scaling.
- Its backtester models **no slippage** and may lack historical funding — areas where our cost-aware simulator (ADR 0002) is already stronger. We should not import its fidelity gaps.

The gap analysis is unambiguous: we are well-covered on *signal structure, backtesting, and cost accounting*, and thin on *portfolio-level protections, adaptive exits, and leverage-aware safety* — precisely the machinery that matters most for a leveraged perpetual-futures bot (ADR 0002).

## Decision

**Adopt freqtrade's risk/exit/money-management patterns by porting the logic into our Ruby engine, prioritized by safety-per-unit-effort. Defer its ML and strategy-ensemble complexity. Import none of its backtester fidelity gaps.**

Everything below is measured through the existing backtester + walk-forward before any live enablement — no evidence inheritance (the ADR 0002 rule holds).

**Tier 1 — adopt now (cheap, safe, leverage-relevant):**

1. **Protections layer.** A composable set of trade-blocking guards evaluated before entry:
   - `CooldownPeriod` — block re-entry on a symbol for N minutes after any exit.
   - `StoplossGuard` with **`only_per_side`** — halt (per-symbol or global) after ≥K stop-outs in a lookback window; per-side matters because long and short failures are different regimes on perps.
   - `MaxDrawdown` (**equity-curve** mode) — halt when equity drawdown over a lookback exceeds a ceiling.
   This complements — does not replace — the existing *cost*-based `SymbolCircuitBreakerJob` and durable `TradingHalt`; those remain the substrate the protections write to.
2. **Minimal-ROI time-decay exit table.** A `{minutes_held → profit_target}` schedule that lowers the take-profit bar as a position ages, exiting stale winners our fixed-bps TP currently rides back toward break-even. Additive to existing TP/SL: the earlier of the two triggers.
3. **Liquidation-buffer pre-exit.** Exit at `liq_price ± buffer·|entry − liq_price|` before real liquidation, computed from Coinbase isolated-margin math. Non-negotiable safety for a leveraged bot; must be modeled in the simulator too.

**Tier 2 — adopt after Tier 1 lands and measures positive:**

4. **Adaptive `custom_stoploss`** — ATR/SAR-driven trailing that only ever ratchets tighter, upgrading the current trailing-stop calculator.
5. **Risk-adjusted calibration objectives** — add **Sortino** and **Calmar** loss functions to `CalibrationJob` alongside the existing objectives; prefer them for leveraged symbols.
6. **Alternate strategies as backtest-only candidates** — implement `BbandRsi` (RSI<30 + close<lower Bollinger, MR) and an `ADXMomentum`-style trend filter (ADX>25 + DI alignment) as A/B candidates against the trend-follower. Wire the already-coded RSI/MACD/Bollinger math out of `MarketAnalysisService` into shared `Signals::Indicators` first.

**Tier 3 — deferred, explicitly out of scope for now:**

7. **FreqAI (ML regressors / RL).** Wrong altitude while paper-first on 3 symbols. **One idea extracted without the ML:** a Dissimilarity-Index-style **regime gate** — suppress trading when live feature vectors look unlike the calibration window — revisited as a Tier-2+ safety item, not an ML project.
8. **DCA / `adjust_trade_position` position scaling.** Powerful but dangerous under leverage; revisit only after the protections layer is proven.
9. **Dynamic pairlists.** Irrelevant to a fixed BTC/ETH/OIL universe; the `SpreadFilter`/`VolatilityFilter` entry-quality gates may return as entry filters later.

## Consequences

- Protections, minimal-ROI, and the liquidation buffer must be modeled in `PaperTrading::ExchangeSimulator` / `Backtest::Engine` as well as live, or backtest and live diverge. This is new simulator surface area.
- The protections layer needs a small persistence model (active locks with TTL, per-symbol and per-side scope) that the evaluator consults in `valid_signal?`; it reuses the `TradingHalt` durability pattern rather than inventing a new one.
- Tier-1 items require **no new market data and no ML** — they run entirely on candles and trade history we already store, so they are shippable against the current stack.
- Alternate strategies (Tier 2) must earn live enablement independently via per-symbol walk-forward + net-of-costs gate — the ADR 0002 no-inheritance rule applies per strategy, not just per symbol.
- We deliberately do **not** adopt freqtrade's zero-slippage / missing-funding backtest assumptions; our simulator's cost realism (ADR 0002) is the floor, not something to regress toward.
- Kill criterion for the effort: if Tier-1 protections do not improve risk-adjusted walk-forward metrics (max drawdown, Sortino) at equal or better expectancy on BIP/ETH data, they ship as safety rails only and Tier 2 signal work is reprioritized.

## Alternatives considered

| Option | Verdict |
|---|---|
| Port freqtrade wholesale (framework + strategies) | Rejected — Python, no Coinbase-perp adapter, and its backtester is *less* cost-realistic than ours; we'd inherit its gaps |
| Adopt FreqAI (ML/RL) first | Rejected — wrong altitude for a paper-first 3-symbol bot; extract only the regime-gate idea, deferred |
| Adopt DCA/position-scaling for money management | Deferred — high blow-up risk under leverage before protections exist |
| Build nothing; keep the single trend-follower | Rejected — leaves the biggest leverage-safety gaps (per-side stop clustering, equity drawdown, liquidation proximity) unaddressed |
| **Port Tier-1 risk machinery now, Tier-2 signals next, defer ML** | **Adopted** — maximal safety-per-effort, measured through the existing backtester, no new data or ML |
