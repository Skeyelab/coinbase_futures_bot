# frozen_string_literal: true

require "rails_helper"

RSpec.describe Backtest::Engine, type: :service do
  # Deterministic stand-in strategy: emits a scripted signal per as_of.
  def scripted_strategy(&script)
    Class.new do
      attr_reader :calls

      def initialize(script)
        @script = script || ->(_as_of) {}
        @calls = []
      end

      def signal(symbol:, equity_usd:, as_of: nil)
        @calls << as_of
        @script.call(as_of)
      end
    end.new(script)
  end

  let(:t0) { Time.parse("2026-02-01T00:00:00Z") }

  def insert_step_candles(closes, symbol: "TEST-USD", start: t0, step: 5.minutes)
    Candle.insert_all!(closes.each_with_index.map do |close, i|
      {symbol: symbol, timeframe: "5m", timestamp: start + i * step,
       open: close, high: close + 0.5, low: close - 0.5, close: close, volume: 10,
       created_at: Time.current, updated_at: Time.current}
    end)
  end

  # Marks a symbol as a perp (funding applies) via a FundingRate row placed AFTER
  # the test window, so crossed boundaries fall back to the constant knob. Only
  # perps have funding — dated futures (no rows) accrue none.
  def mark_perp(symbol)
    FundingRate.create!(product_id: symbol, funding_time: t0 + 100.days, funding_rate: 0.0002,
      funding_interval_seconds: 3600, observed_at: t0)
  end

  describe "event-driven replay mechanics" do
    it "produces the expected trade and PnL for a known price series (no randomness)" do
      closes = Array.new(10, 100.0) + (1..10).map { |i| 100.0 + i }
      insert_step_candles(closes)
      mark_perp("TEST-USD")

      strategy = scripted_strategy do |as_of|
        if as_of == t0
          {side: :long, price: 100.0, quantity: 1.0, tp: 105.0, sl: 95.0, confidence: 50.0}
        end
      end

      engine = described_class.new(symbol: "TEST-USD", strategy: strategy,
        starting_equity: 10_000.0, fee_rate: 0.001, slippage: 0.0)
      result = engine.run(from: t0, to: t0 + 19 * 5.minutes)

      expect(result).to be_a(Backtest::Result)
      expect(result.trade_count).to eq(1)

      trade = result.trades.first
      # entry 100 (fee 0.1), exit at TP 105 (fee 0.105): pnl = 5 - 0.205 - funding.
      # Held t0 00:00 -> 01:10 crosses one hourly boundary (01:00): funding at the
      # default 2 bps/interval on $100 notional = 0.02, so pnl = 4.795 - 0.02.
      expect(trade[:side]).to eq(:long)
      expect(trade[:pnl]).to be_within(1e-9).of(4.775)
      expect(trade[:fees]).to be_within(1e-9).of(0.205)
      expect(trade[:funding]).to be_within(1e-9).of(0.02)
      expect(trade[:entered_at]).to eq(t0)
      # TP 105 first reachable on the candle whose high (close+0.5) >= 105: close 104.6? closes hit 105 at i=14 (high 105.5); i=14 -> t0 + 14*5min
      expect(trade[:exited_at]).to eq(t0 + 14 * 5.minutes)
      expect(result.final_equity).to be_within(1e-9).of(10_004.775)
    end

    it "drives the strategy once per step candle with as_of, skipping steps while a position is open" do
      closes = Array.new(10, 100.0) + (1..10).map { |i| 100.0 + i }
      insert_step_candles(closes)

      strategy = scripted_strategy do |as_of|
        if as_of == t0
          {side: :long, price: 100.0, quantity: 1.0, tp: 105.0, sl: 95.0, confidence: 50.0}
        end
      end

      engine = described_class.new(symbol: "TEST-USD", strategy: strategy,
        starting_equity: 10_000.0, fee_rate: 0.0, slippage: 0.0)
      engine.run(from: t0, to: t0 + 19 * 5.minutes)

      # Called at t0 (opens trade), silent while position open (steps 1..14),
      # then called again on every flat step (15..19).
      expect(strategy.calls.first).to eq(t0)
      expect(strategy.calls).to eq([t0] + (15..19).map { |i| t0 + i * 5.minutes })
    end

    it "returns an empty result when there are no candles" do
      engine = described_class.new(symbol: "EMPTY-USD", strategy: scripted_strategy,
        starting_equity: 10_000.0)
      result = engine.run(from: t0, to: t0 + 1.hour)

      expect(result.trade_count).to eq(0)
      expect(result.final_equity).to eq(10_000.0)
    end
  end

  describe "per-venue fee default (issue #458)" do
    it "defaults a dated future to the dated fee rate, not perp 3 bps" do
      dated = described_class.new(symbol: "NOL-19AUG26-CDE")
      expect(dated.instance_variable_get(:@fee_rate)).to eq(CostModel.dated_taker_rate)
    end

    it "defaults a perp to the perp taker rate" do
      mark_perp("BIP-PERP")
      perp = described_class.new(symbol: "BIP-PERP")
      expect(perp.instance_variable_get(:@fee_rate)).to eq(CostModel.taker_fee_rate)
    end
  end

  describe "defaults" do
    it "runs the live strategy (MultiTimeframeSignal) with symbol resolution off" do
      engine = described_class.new(symbol: "TEST-USD")
      expect(engine.strategy).to be_a(Strategy::MultiTimeframeSignal)
      expect(engine.strategy.instance_variable_get(:@config)[:resolve_symbols]).to be(false)
    end

    it "builds the default strategy with LIVE config, not class DEFAULTS (drift audit)" do
      engine = described_class.new(symbol: "TEST-USD")
      live = Rails.application.config.real_time_signals[:strategies]["MultiTimeframeSignal"]
      expect(engine.strategy.instance_variable_get(:@config)[:ema_1h_short]).to eq(live[:ema_1h_short])
      expect(engine.strategy.instance_variable_get(:@config)[:ema_1h_long]).to eq(live[:ema_1h_long])
    end
  end

  describe "contract-size-aware units (drift audit: PnL was ~1000x inflated)" do
    # The #606 clamp caps entries at the sizing registry's max_contracts, and
    # TEST-USD falls to the conservative default (2). This example's arithmetic
    # needs 5, so give the synthetic symbol an explicit allowance.
    before do
      allow(Trading::AssetSizing).to receive(:for_product).and_call_original
      allow(Trading::AssetSizing).to receive(:for_product).with("TEST-USD")
        .and_return(Trading::AssetSizing::Params.new(100.0, 10, 1))
    end

    it "converts contract quantity to base units using the strategy's contract_size_usd" do
      insert_step_candles(Array.new(10, 50_000.0) + (1..10).map { |i| 50_000.0 + i * 200 })
      mark_perp("TEST-USD")

      strategy = scripted_strategy do |as_of|
        if as_of == t0
          # 5 contracts at $100 notional each = $500 notional = 0.01 base units
          {side: :long, price: 50_000.0, quantity: 5.0, tp: 51_000.0, sl: 49_000.0, confidence: 50.0}
        end
      end

      engine = described_class.new(symbol: "TEST-USD", strategy: strategy,
        starting_equity: 10_000.0, fee_rate: 0.0, slippage: 0.0, contract_size_usd: 100.0)
      result = engine.run(from: t0, to: t0 + 19 * 5.minutes)

      trade = result.trades.first
      # base qty = 5 * 100 / 50_000 = 0.01; TP at 51_000 -> gross = 1_000 * 0.01 = $10.
      # Held t0 00:00 -> 01:10 crosses one hourly boundary: funding at 2 bps on
      # $500 notional = 0.10, so net pnl = 10 - 0.10.
      expect(trade[:quantity]).to be_within(1e-9).of(0.01)
      expect(trade[:pnl]).to be_within(1e-6).of(9.90)
      expect(trade[:funding]).to be_within(1e-9).of(0.10)
    end
  end

  describe "funding accrual (issue #391)" do
    let(:long_at_t0) do
      scripted_strategy do |as_of|
        if as_of == t0
          {side: :long, price: 100.0, quantity: 1.0, tp: 105.0, sl: 95.0, confidence: 50.0}
        end
      end
    end

    it "charges adverse funding by default for boundaries the hold crosses" do
      insert_step_candles(Array.new(10, 100.0) + (1..10).map { |i| 100.0 + i })
      mark_perp("TEST-USD")
      engine = described_class.new(symbol: "TEST-USD", strategy: long_at_t0,
        starting_equity: 10_000.0, fee_rate: 0.0, slippage: 0.0)

      trade = engine.run(from: t0, to: t0 + 19 * 5.minutes).trades.first
      # Held 00:00 -> 01:10 crosses 01:00 = 1 interval; 2 bps on $100 notional.
      expect(trade[:funding]).to be_within(1e-9).of(1 * 0.0002 * 100.0)
    end

    it "charges NO funding on a dated future (not a perp -> no FundingRate rows)" do
      # Coinbase has no oil/metals perp; NOL/GOL/SLR trade as dated futures with
      # zero funding. Without a FundingRate row the constant fallback is suppressed.
      insert_step_candles(Array.new(10, 100.0) + (1..10).map { |i| 100.0 + i }, symbol: "NOL-19AUG26-CDE")
      engine = described_class.new(symbol: "NOL-19AUG26-CDE", strategy: long_at_t0,
        starting_equity: 10_000.0, fee_rate: 0.0, slippage: 0.0)

      trade = engine.run(from: t0, to: t0 + 19 * 5.minutes).trades.first
      expect(trade[:funding]).to eq(0.0)
    end

    it "can be disabled with funding_bps_per_interval: 0" do
      insert_step_candles(Array.new(10, 100.0) + (1..10).map { |i| 100.0 + i })
      engine = described_class.new(symbol: "TEST-USD", strategy: long_at_t0,
        starting_equity: 10_000.0, fee_rate: 0.0, slippage: 0.0, funding_bps_per_interval: 0)

      trade = engine.run(from: t0, to: t0 + 19 * 5.minutes).trades.first
      expect(trade[:funding]).to eq(0.0)
    end

    # End-to-end: the engine prices accrual from the live FundingRate history via
    # Funding::Schedule, using the OBSERVED rate (not the 2 bps constant) and
    # SIGNED (longs pay, shorts collect) — ADR 0002's "rates snapshotted live".
    it "charges a long the OBSERVED funding rate when a snapshot covers the boundary" do
      insert_step_candles(Array.new(10, 100.0) + (1..10).map { |i| 100.0 + i })
      FundingRate.create!(product_id: "TEST-USD", funding_time: t0 + 1.hour, funding_rate: 0.0005,
        funding_interval_seconds: 3600, observed_at: t0 + 1.hour)
      engine = described_class.new(symbol: "TEST-USD", strategy: long_at_t0,
        starting_equity: 10_000.0, fee_rate: 0.0, slippage: 0.0)

      trade = engine.run(from: t0, to: t0 + 19 * 5.minutes).trades.first
      # 01:00 boundary at the observed 5 bps (not the 2 bps constant) on $100.
      expect(trade[:funding]).to be_within(1e-9).of(0.0005 * 100.0)
    end

    it "credits a short (signed funding) at the observed rate" do
      short_at_t0 = scripted_strategy do |as_of|
        if as_of == t0
          {side: :short, price: 100.0, quantity: 1.0, tp: 95.0, sl: 105.0, confidence: 50.0}
        end
      end
      insert_step_candles(Array.new(10, 100.0) + (1..10).map { |i| 100.0 - i })
      FundingRate.create!(product_id: "TEST-USD", funding_time: t0 + 1.hour, funding_rate: 0.0005,
        funding_interval_seconds: 3600, observed_at: t0 + 1.hour)
      engine = described_class.new(symbol: "TEST-USD", strategy: short_at_t0,
        starting_equity: 10_000.0, fee_rate: 0.0, slippage: 0.0)

      trade = engine.run(from: t0, to: t0 + 19 * 5.minutes).trades.first
      # A short in a positive-funding regime COLLECTS: signed negative cost.
      expect(trade[:funding]).to be_within(1e-9).of(-0.0005 * 100.0)
    end
  end

  describe "liquidation-buffer exit (issue #399, ADR 0003)" do
    # Long entry 100, leverage 10, buffer 0.05 -> buffered exit 90.975. A candle
    # whose low pierces it should force-close at that price with a
    # liquidation_buffer reason, ahead of the fixed SL.
    def liq_engine(buffer:)
      # enter at 100, hold flat, then a candle that dumps to 90 (low 89.5)
      insert_step_candles([100.0, 100.0, 90.0, 90.0])
      strategy = scripted_strategy do |as_of|
        if as_of == t0
          {side: :long, price: 100.0, quantity: 1.0, tp: 200.0, sl: 1.0, confidence: 50.0}
        end
      end
      described_class.new(symbol: "TEST-USD", strategy: strategy, starting_equity: 10_000.0,
        fee_rate: 0.0, slippage: 0.0,
        liquidation_buffer: Trading::LiquidationBuffer.new(buffer: buffer, leverage: 10))
    end

    it "force-closes at the buffered price with a liquidation_buffer reason" do
      result = liq_engine(buffer: 0.05).run(from: t0, to: t0 + 3 * 5.minutes)

      expect(result.trade_count).to eq(1)
      trade = result.trades.first
      expect(trade[:exit_reason]).to eq(:liquidation_buffer)
      expect(trade[:exit_price]).to be_within(1e-9).of(90.975)
      expect(result.exit_reason_breakdown[:liquidation_buffer]).to eq(1)
    end

    it "does not fire when the buffer is disabled" do
      result = liq_engine(buffer: 0.0).run(from: t0, to: t0 + 3 * 5.minutes)
      # sl=1 never hit, no liq buffer -> position rides to end -> no completed trade
      expect(result.trade_count).to eq(0)
    end
  end

  describe "MaxDrawdown parity (issue #401, ADR 0003)" do
    # Saw-tooth losing series; each loss drops equity. A tiny ceiling trips the
    # global drawdown halt after the first loss, so the guarded run makes fewer
    # trades than a disabled run and records the halt.
    def dd_engine(guard)
      strategy = scripted_strategy do |_as_of|
        {side: :long, price: 100.0, quantity: 10.0, tp: 200.0, sl: 99.5, confidence: 50.0}
      end
      described_class.new(symbol: "TEST-USD", strategy: strategy, starting_equity: 10_000.0,
        fee_rate: 0.0, slippage: 0.0, contract_size_usd: 100.0, max_drawdown: guard)
    end

    before { insert_step_candles([100.0, 99.0, 100.0, 99.0, 100.0, 99.0, 100.0, 99.0]) }

    it "halts all entries once equity drawdown exceeds the ceiling, and records it" do
      tripping = Trading::Protections::MaxDrawdown.new(ceiling: 0.0001, lookback_seconds: 100_000, lock_ttl_seconds: 100_000)
      disabled = Trading::Protections::MaxDrawdown.new(ceiling: 0)

      guarded = dd_engine(tripping).run(from: t0, to: t0 + 7 * 5.minutes)
      unguarded = dd_engine(disabled).run(from: t0, to: t0 + 7 * 5.minutes)

      expect(guarded.trade_count).to be < unguarded.trade_count
      expect(guarded.protection_halts.map { |h| h[:source] }).to include("MaxDrawdown")
    end
  end

  describe "StoplossGuard parity (issue #400, ADR 0003)" do
    # A saw-tooth series: enter long at 100, the next candle dips to 99 (low 98.5)
    # and hits the 99.5 stop -> a losing round-trip -> re-enter -> repeat. With the
    # guard tripping at 2 losses, entries halt after the 2nd loss; disabled, it
    # keeps losing across the whole series.
    def sawtooth_engine(guard)
      strategy = scripted_strategy do |_as_of|
        {side: :long, price: 100.0, quantity: 1.0, tp: 200.0, sl: 99.5, confidence: 50.0}
      end
      described_class.new(symbol: "TEST-USD", strategy: strategy, starting_equity: 10_000.0,
        fee_rate: 0.0, slippage: 0.0, stoploss_guard: guard)
    end

    before { insert_step_candles([100.0, 99.0, 100.0, 99.0, 100.0, 99.0, 100.0, 99.0, 100.0, 99.0]) }

    let(:tripping_guard) do
      Trading::Protections::StoplossGuard.new(threshold: 2, lookback_seconds: 100_000,
        only_per_side: true, scope: "symbol", lock_ttl_seconds: 100_000)
    end
    let(:disabled_guard) { Trading::Protections::StoplossGuard.new(threshold: 0, lookback_seconds: 1) }

    it "halts entries after the loss threshold and records the halt" do
      guarded = sawtooth_engine(tripping_guard).run(from: t0, to: t0 + 9 * 5.minutes)
      unguarded = sawtooth_engine(disabled_guard).run(from: t0, to: t0 + 9 * 5.minutes)

      # The guard halts long entries after the 2nd loss, so the guarded run makes
      # strictly fewer (losing) trades than the unguarded run — and records it.
      expect(guarded.trade_count).to be < unguarded.trade_count
      expect(guarded.trade_count).to be <= 3
      expect(guarded.protection_halts).to be_present
      expect(guarded.protection_halts.first).to include(source: "StoplossGuard", side: "long")
    end
  end

  describe "minimum-ROI time-decay exit (issue #398, ADR 0003)" do
    # Flat price, fixed TP unreachable: the position stalls at ~0 profit. With a
    # schedule that decays the bar to break-even at 40m, it should book a
    # time-decay-roi exit; with no schedule it rides to end-of-replay (no trade).
    def flat_stall_engine(min_roi_schedule:)
      insert_step_candles(Array.new(20, 100.0))
      strategy = scripted_strategy do |as_of|
        if as_of == t0
          {side: :long, price: 100.0, quantity: 1.0, tp: 200.0, sl: 1.0, confidence: 50.0}
        end
      end
      described_class.new(symbol: "TEST-USD", strategy: strategy, starting_equity: 10_000.0,
        fee_rate: 0.0, slippage: 0.0, min_roi_schedule: min_roi_schedule)
    end

    it "closes a stalled position with a time_decay_roi exit reason once the bar decays" do
      result = flat_stall_engine(min_roi_schedule: {0 => 0.006, 40 => 0.0})
        .run(from: t0, to: t0 + 19 * 5.minutes)

      expect(result.trade_count).to eq(1)
      trade = result.trades.first
      expect(trade[:exit_reason]).to eq(:time_decay_roi)
      # 40 minutes = 8 * 5m steps -> exits on the candle at t0 + 40 min
      expect(trade[:exited_at]).to eq(t0 + 8 * 5.minutes)
    end

    it "does not force a min-roi exit when no schedule is configured" do
      result = flat_stall_engine(min_roi_schedule: {})
        .run(from: t0, to: t0 + 19 * 5.minutes)

      # Fixed TP never hits, no decay -> position never closes -> no completed trade
      expect(result.trade_count).to eq(0)
    end
  end

  describe "protections parity (issue #397, ADR 0003)" do
    # A flat series that round-trips repeatedly: enter long, TP hits next candle,
    # re-enter, and so on. With no cooldown this yields many trades; with a
    # cooldown spanning the whole series it yields exactly one — proving the
    # protection is evaluated inside the backtest on the simulated clock.
    def flat_scalp_engine(cooldown_seconds:)
      insert_step_candles(Array.new(20, 100.0))
      strategy = scripted_strategy do |_as_of|
        {side: :long, price: 100.0, quantity: 1.0, tp: 100.4, sl: 99.6, confidence: 50.0}
      end
      described_class.new(symbol: "TEST-USD", strategy: strategy, starting_equity: 10_000.0,
        fee_rate: 0.0, slippage: 0.0, protection_cooldown_seconds: cooldown_seconds)
    end

    after { Trading::ProtectionLock.clear! }

    it "re-enters repeatedly with no cooldown" do
      result = flat_scalp_engine(cooldown_seconds: 0).run(from: t0, to: t0 + 19 * 5.minutes)
      expect(result.trade_count).to be >= 2
    end

    it "suppresses re-entry while a cooldown from the prior exit is active" do
      result = flat_scalp_engine(cooldown_seconds: 100_000).run(from: t0, to: t0 + 19 * 5.minutes)
      expect(result.trade_count).to eq(1)
    end

    it "does not write cooldown locks into the live DB store" do
      flat_scalp_engine(cooldown_seconds: 100_000).run(from: t0, to: t0 + 19 * 5.minutes)
      expect(BotRuntimeStat.find_by(key: Trading::ProtectionLock::STORE_KEY)).to be_nil
    end
  end

  describe "engine-level min-confidence filter (issue #580)" do
    # The #497 incumbent is 200/120 @ conf>=30, but the engine traded every
    # signal — the gates could never judge the configuration as frozen. With
    # min_confidence: set, a signal below the bar is NOT traded, only counted.
    def conf_engine(min_confidence:, &script)
      insert_step_candles(Array.new(10, 100.0) + (1..10).map { |i| 100.0 + i })
      described_class.new(symbol: "TEST-USD", strategy: scripted_strategy(&script),
        starting_equity: 10_000.0, fee_rate: 0.0, slippage: 0.0,
        min_confidence: min_confidence)
    end

    it "does not trade a signal below the bar and counts the rejection" do
      engine = conf_engine(min_confidence: 30) do |as_of|
        if as_of == t0
          {side: :long, price: 100.0, quantity: 1.0, tp: 105.0, sl: 95.0, confidence: 20.0}
        end
      end
      result = engine.run(from: t0, to: t0 + 19 * 5.minutes)

      expect(result.trade_count).to eq(0)
      expect(result.rejected_low_confidence).to eq(1)
      expect(result.to_h[:rejected_low_confidence]).to eq(1)
    end

    it "trades a signal AT the bar (inclusive threshold, conf>=30 semantics)" do
      engine = conf_engine(min_confidence: 30) do |as_of|
        if as_of == t0
          {side: :long, price: 100.0, quantity: 1.0, tp: 105.0, sl: 95.0, confidence: 30.0}
        end
      end
      result = engine.run(from: t0, to: t0 + 19 * 5.minutes)

      expect(result.trade_count).to eq(1)
      expect(result.rejected_low_confidence).to eq(0)
    end

    it "rejects a nil-confidence signal when the filter is set (a filter that passes unknowns is not a filter)" do
      engine = conf_engine(min_confidence: 30) do |as_of|
        if as_of == t0
          {side: :long, price: 100.0, quantity: 1.0, tp: 105.0, sl: 95.0}
        end
      end
      result = engine.run(from: t0, to: t0 + 19 * 5.minutes)

      expect(result.trade_count).to eq(0)
      expect(result.rejected_low_confidence).to eq(1)
    end

    it "default nil preserves current behavior exactly: low- and nil-confidence signals trade, counter stays 0" do
      engine = conf_engine(min_confidence: nil) do |as_of|
        if as_of == t0
          {side: :long, price: 100.0, quantity: 1.0, tp: 105.0, sl: 95.0, confidence: 5.0}
        end
      end
      result = engine.run(from: t0, to: t0 + 19 * 5.minutes)

      expect(result.trade_count).to eq(1)
      expect(result.rejected_low_confidence).to eq(0)
      expect(result.to_h[:rejected_low_confidence]).to eq(0)
    end

    it "counts every rejected signal evaluation across the run" do
      # Strategy signals on EVERY flat step at conf 10: all rejected, none
      # traded, so every step stays flat and re-asks — 20 candles, 20 rejections.
      engine = conf_engine(min_confidence: 30) do |_as_of|
        {side: :long, price: 100.0, quantity: 1.0, tp: 105.0, sl: 95.0, confidence: 10.0}
      end
      result = engine.run(from: t0, to: t0 + 19 * 5.minutes)

      expect(result.trade_count).to eq(0)
      expect(result.rejected_low_confidence).to eq(20)
    end
  end

  describe "integration with the live strategy" do
    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("SENTIMENT_ENABLE", anything).and_return("false")
    end

    it "exercises MultiTimeframeSignal via the shared indicators and completes trades on a strong trend" do
      t_end = Time.parse("2026-02-10T00:00:00Z")
      rate_per_min = 0.01
      price_at = ->(ts) { 100.0 + (ts - (t_end - 90.hours)) / 60.0 * rate_per_min }

      candle_data = []
      {"1h" => [95, 1.hour], "15m" => [140, 15.minutes], "5m" => [130, 5.minutes], "1m" => [420, 1.minute]}
        .each do |timeframe, (count, step)|
        count.times do |i|
          ts = t_end - (count - 1 - i) * step
          close = price_at.call(ts)
          candle_data << {
            symbol: "TREND-USD", timeframe: timeframe, timestamp: ts,
            open: close - 0.1, high: close + 0.5, low: close - 0.5, close: close, volume: 10 + i,
            created_at: Time.current, updated_at: Time.current
          }
        end
      end
      Candle.insert_all!(candle_data)

      # Explicit tp/sl so this exercises the ENGINE, not whatever the global
      # default happens to be — #496 widened it to 200/120 bps, which a
      # 300-minute synthetic trend cannot reach inside the window.
      strategy = Trading::StrategyFactory.multi_timeframe(
        resolve_symbols: false, tp_target: 0.006, sl_target: 0.004
      )
      engine = described_class.new(symbol: "TREND-USD", strategy: strategy,
        starting_equity: 10_000.0, fee_rate: 0.0015, slippage: 0.0002)

      allow(engine.strategy).to receive(:signal).and_call_original
      result = engine.run(from: t_end - 300.minutes, to: t_end)

      expect(engine.strategy).to have_received(:signal).at_least(:once) do |symbol:, as_of:, **|
        expect(symbol).to eq("TREND-USD")
        expect(as_of).to be_a(Time)
      end
      expect(result.trade_count).to be >= 1
      expect(result.trades).to all(include(side: :long))
    end
  end

  # Backtest parity for the operator's CURRENT n8n rule, the ATR Chandelier
  # (CB Watcher - Multi Position). Fees are zeroed so net == gross and the
  # dollar arithmetic below is exact.
  describe "ATR chandelier exit" do
    # contract_size_usd 1000 at price 100 -> 10 base units -> $10 of PnL per $1
    # move, on one contract.
    def chandelier_engine(closes:, policy:, hourly: nil, tp: 200.0, sl: 1.0)
      insert_step_candles(closes)
      insert_hourly_candles(hourly) if hourly
      strategy = scripted_strategy do |as_of|
        if as_of == t0
          {side: :long, price: 100.0, quantity: 1.0, tp: tp, sl: sl, confidence: 50.0}
        end
      end
      described_class.new(symbol: "TEST-USD", strategy: strategy, starting_equity: 10_000.0,
        fee_rate: 0.0, per_contract_fee: 0.0, slippage: 0.0, contract_size_usd: 1000.0,
        atr_chandelier: policy, atr_period: 2)
    end

    # Hourly bars reaching back before t0 so an ATR is already readable at entry.
    def insert_hourly_candles(range)
      Candle.insert_all!(range.map do |i, high, low, close|
        {symbol: "TEST-USD", timeframe: "1h", timestamp: t0 + i * 1.hour,
         open: close, high: high, low: low, close: close, volume: 10,
         created_at: Time.current, updated_at: Time.current}
      end)
    end

    let(:policy) { Trading::AtrChandelierExit.new(trail_atr: 2.5, fixed_stop: -75.0) }

    # ATR 1.0 -> atr_pnl = 1.0 * 10 base units = $10 -> trail is $25 below peak.
    let(:calm_hours) { (-4..0).map { |i| [i, 101.0, 100.0, 100.5] } }

    it "trails the peak and closes when price gives back more than 2.5 ATR" do
      # Peak from the 104.0 candle HIGH (104.5) = +$45. Stop = 45 - 25 = $20.
      # The 101.0 candle LOW is 100.5 = +$5, below the stop.
      result = chandelier_engine(closes: [100.0, 104.0, 101.0, 101.0],
        policy: policy, hourly: calm_hours).run(from: t0, to: t0 + 3 * 5.minutes)

      expect(result.trade_count).to eq(1)
      expect(result.trades.first[:exit_reason]).to eq(:atr_trail)
    end

    it "holds while the giveback stays inside the ATR band" do
      # Peak 104.5 -> +$45, stop $20. Low of 103.5 is +$35, still above.
      result = chandelier_engine(closes: [100.0, 104.0, 104.0, 104.0],
        policy: policy, hourly: calm_hours).run(from: t0, to: t0 + 3 * 5.minutes)

      expect(result.trades.first&.dig(:exit_reason)).not_to eq(:atr_trail)
    end

    # Without an hourly series there is no ATR at all, and the rule must fall back
    # to the absolute floor rather than inventing a tight stop from nothing.
    it "falls back to the fixed stop when no ATR is readable" do
      result = chandelier_engine(closes: [100.0, 100.0, 91.0, 91.0],
        policy: policy).run(from: t0, to: t0 + 3 * 5.minutes)

      expect(result.trade_count).to eq(1)
      expect(result.trades.first[:exit_reason]).to eq(:atr_floor)
    end

    it "is inert with no policy configured" do
      result = chandelier_engine(closes: [100.0, 104.0, 101.0, 101.0],
        policy: nil, hourly: calm_hours).run(from: t0, to: t0 + 3 * 5.minutes)

      expect(result.trades.map { |t| t[:exit_reason] }).not_to include(:atr_trail, :atr_floor)
    end

    # Explicit OHLC so a bar can carry a wick far from its close. The default
    # helper uses close +/- 0.5, which is too gentle to tell these apart.
    def insert_wicked_candles(rows, step: 5.minutes)
      Candle.insert_all!(rows.each_with_index.map do |(high, low, close), i|
        {symbol: "TEST-USD", timeframe: "5m", timestamp: t0 + i * step,
         open: close, high: high, low: low, close: close, volume: 10,
         created_at: Time.current, updated_at: Time.current}
      end)
    end

    def wicked_engine(rows:, policy:, hourly:, step: 5.minutes)
      insert_wicked_candles(rows, step: step)
      insert_hourly_candles(hourly)
      strategy = scripted_strategy do |as_of|
        if as_of == t0
          {side: :long, price: 100.0, quantity: 1.0, tp: 200.0, sl: 1.0, confidence: 50.0}
        end
      end
      described_class.new(symbol: "TEST-USD", strategy: strategy, starting_equity: 10_000.0,
        fee_rate: 0.0, per_contract_fee: 0.0, slippage: 0.0, contract_size_usd: 1000.0,
        atr_chandelier: policy, atr_period: 2)
    end

    # The peak must come from the bar's FAVORABLE extreme. A tall wick to 110 is
    # +$100 of peak even though the bar closes flat at 100; taking the peak from
    # the close would see +$0, leave the stop at -$25, and never exit.
    it "takes the peak from the bar's high, not its close" do
      result = wicked_engine(
        rows: [[100.5, 99.5, 100.0], [110.0, 100.0, 100.0], [100.0, 99.0, 99.0], [100.0, 99.0, 99.0]],
        policy: policy, hourly: calm_hours
      ).run(from: t0, to: t0 + 3 * 5.minutes)

      expect(result.trade_count).to eq(1)
      expect(result.trades.first[:exit_reason]).to eq(:atr_trail)
    end

    # The fill is taken at the ADVERSE extreme. Filling at the favorable one
    # would flatter every trailed exit in the whole run.
    #
    # Note the exit lands on the WICK BAR itself: that bar's high sets the peak
    # (+$100, stop $75) and its own low is already back to $0, so a single wide
    # bar can both arm and trigger. Deliberately pessimistic, and the same
    # within-bar ordering the giveback port used.
    it "fills the exit at the bar's adverse extreme" do
      result = wicked_engine(
        rows: [[100.5, 99.5, 100.0], [110.0, 100.0, 100.0], [104.0, 99.0, 99.0], [104.0, 99.0, 99.0]],
        policy: policy, hourly: calm_hours
      ).run(from: t0, to: t0 + 3 * 5.minutes)

      # The wick bar's LOW. The favorable-extreme mutation fills at 110 instead.
      expect(result.trades.first[:exit_price]).to be_within(1e-6).of(100.0)
    end

    # ATR widens from 1.0 to 4.0, so the freshly computed trail (peak - $100)
    # drops BELOW the stop already banked at the tighter ATR (peak - $25).
    # Without persistence the stop loosens and the exit never fires.
    it "ratchets the stop and never lets a widening ATR loosen it" do
      widening = (-4..0).map { |i| [i, 101.0, 100.0, 100.5] } +
        (1..3).map { |i| [i, 108.0, 100.0, 104.0] }

      # Bar 1 peaks at 110 (+$100, stop $75) but its low of 108 is +$80, so it
      # HOLDS -- the position has to survive into the wider ATR for the ratchet
      # to matter at all. By bar 2 the ATR has widened to ~4.5, which would put
      # a freshly computed trail at -$12.5; the banked $75 must win, and the
      # bar's low of 105 (+$50) is below it.
      result = wicked_engine(
        rows: [[100.5, 99.5, 100.0], [110.0, 108.0, 109.0], [106.0, 105.0, 105.0], [106.0, 105.0, 105.0]],
        policy: policy, hourly: widening, step: 1.hour
      ).run(from: t0, to: t0 + 3 * 1.hour)

      expect(result.trade_count).to eq(1)
      expect(result.trades.first[:exit_reason]).to eq(:atr_trail)
    end
  end
end
