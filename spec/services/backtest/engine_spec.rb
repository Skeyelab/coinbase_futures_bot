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

  describe "event-driven replay mechanics" do
    it "produces the expected trade and PnL for a known price series (no randomness)" do
      closes = Array.new(10, 100.0) + (1..10).map { |i| 100.0 + i }
      insert_step_candles(closes)

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
    it "converts contract quantity to base units using the strategy's contract_size_usd" do
      insert_step_candles(Array.new(10, 50_000.0) + (1..10).map { |i| 50_000.0 + i * 200 })

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
      engine = described_class.new(symbol: "TEST-USD", strategy: long_at_t0,
        starting_equity: 10_000.0, fee_rate: 0.0, slippage: 0.0)

      trade = engine.run(from: t0, to: t0 + 19 * 5.minutes).trades.first
      # Held 00:00 -> 01:10 crosses 01:00 = 1 interval; 2 bps on $100 notional.
      expect(trade[:funding]).to be_within(1e-9).of(1 * 0.0002 * 100.0)
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

      engine = described_class.new(symbol: "TREND-USD", starting_equity: 10_000.0,
        fee_rate: 0.0015, slippage: 0.0002)

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
end
