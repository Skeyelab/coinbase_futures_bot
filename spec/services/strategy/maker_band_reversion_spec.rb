# frozen_string_literal: true

require "rails_helper"

# Issue #568, memo candidate B: maker-only volatility-band mean reversion.
# Band = band_k x (sample stddev of 5m simple returns over vol_period bars),
# priced around an EMA anchor of 5m closes. One resting limit per evaluation,
# on the band nearer to the last close; TP at the anchor, hard stop
# stop_m x sigma beyond the entry limit.
RSpec.describe Strategy::MakerBandReversion, type: :service do
  # Serves a fixed close series regardless of as_of — the strategy under unit
  # test only ever asks for the trailing window.
  def fake_candle_source(closes)
    candle = Struct.new(:close)
    candles = closes.map { |c| candle.new(c) }
    Class.new do
      define_method(:recent) do |symbol:, timeframe:, limit:, as_of: nil|
        candles.last(limit)
      end
    end.new
  end

  def strategy_for(closes, **config)
    strategy = described_class.new({anchor_period: 3, vol_period: 2, band_k: 1.0,
                                    stop_m: 1.5, min_band_bps: 5.0}.merge(config))
    strategy.candle_source = fake_candle_source(closes)
    strategy
  end

  describe "band computation (hand-verified)" do
    # closes [102, 101, 103]: anchor = EMA(3) = SMA = 102.
    # returns: 101/102-1, 103/101-1; sample stddev over the 2 returns.
    let(:closes) { [102.0, 101.0, 103.0] }
    let(:r1) { 101.0 / 102.0 - 1.0 }
    let(:r2) { 103.0 / 101.0 - 1.0 }
    let(:sigma) do
      mean = (r1 + r2) / 2.0
      Math.sqrt(((r1 - mean)**2 + (r2 - mean)**2) / 1.0)
    end
    let(:sigma_price) { sigma * 102.0 }

    it "rests a SHORT limit at anchor + k*sigma when the close is above the anchor" do
      sig = strategy_for(closes).signal(symbol: "BIP-20DEC30-CDE")

      expect(sig[:side]).to eq(:short)
      expect(sig[:price]).to be_within(1e-9).of(102.0 + sigma_price)
    end

    it "targets the anchor (mean touch)" do
      sig = strategy_for(closes).signal(symbol: "BIP-20DEC30-CDE")
      expect(sig[:tp]).to be_within(1e-9).of(102.0)
    end

    it "stops stop_m * sigma beyond the entry limit" do
      sig = strategy_for(closes).signal(symbol: "BIP-20DEC30-CDE")
      expect(sig[:sl]).to be_within(1e-9).of(102.0 + sigma_price + 1.5 * sigma_price)
    end

    it "scales the band with band_k" do
      sig = strategy_for(closes, band_k: 2.0).signal(symbol: "BIP-20DEC30-CDE")
      expect(sig[:price]).to be_within(1e-9).of(102.0 + 2.0 * sigma_price)
    end
  end

  describe "side selection" do
    it "rests a LONG limit at anchor - k*sigma when the close is below the anchor" do
      # closes [102, 103, 101]: anchor = 102, last close 101 below it.
      sig = strategy_for([102.0, 103.0, 101.0]).signal(symbol: "BIP-20DEC30-CDE")

      expect(sig[:side]).to eq(:long)
      expect(sig[:price]).to be < 102.0
      expect(sig[:tp]).to be_within(1e-9).of(102.0)
      expect(sig[:sl]).to be < sig[:price]
    end
  end

  describe "rejections" do
    it "returns nil with :insufficient_5m_candles when history is short" do
      strategy = strategy_for([100.0, 101.0])
      expect(strategy.signal(symbol: "BIP-20DEC30-CDE")).to be_nil
      expect(strategy.last_rejection).to eq(:insufficient_5m_candles)
    end

    it "goes flat on a constant-slope trend: zero return variance means no band" do
      # 0.1%/bar exactly: every return identical, sigma = 0. A pure trend gives
      # this strategy nothing to quote — the documented flat failure mode.
      closes = (0..5).map { |i| 100.0 * 1.001**i }
      strategy = strategy_for(closes, anchor_period: 3, vol_period: 4)
      expect(strategy.signal(symbol: "BIP-20DEC30-CDE")).to be_nil
      expect(strategy.last_rejection).to eq(:band_too_narrow)
    end

    it "refuses a quote that would cross the market: maker-only means passive or nothing" do
      # Strong trend: anchor (104) lags the last close (108), so the short band
      # sits BELOW the market. Resting there would execute as taker flow, which
      # this strategy is not allowed to model. This is the documented
      # trend failure mode: the strategy goes flat, it does not chase.
      strategy = strategy_for([100.0, 104.0, 108.0])
      expect(strategy.signal(symbol: "BIP-20DEC30-CDE")).to be_nil
      expect(strategy.last_rejection).to eq(:not_passive)
    end

    it "returns nil when the band is narrower than min_band_bps" do
      # sigma_price here is ~2% of anchor; a 500 bps floor rejects it.
      strategy = strategy_for([102.0, 101.0, 103.0], min_band_bps: 500.0)
      expect(strategy.signal(symbol: "BIP-20DEC30-CDE")).to be_nil
      expect(strategy.last_rejection).to eq(:band_too_narrow)
    end
  end

  describe "sizing and confidence" do
    it "sizes in whole contracts from config" do
      sig = strategy_for([102.0, 101.0, 103.0], contracts: 2).signal(symbol: "BIP-20DEC30-CDE")
      expect(sig[:quantity]).to eq(2)
    end

    it "returns nil when contracts is zero" do
      expect(strategy_for([102.0, 101.0, 103.0], contracts: 0).signal(symbol: "BIP-20DEC30-CDE")).to be_nil
    end

    it "reports a bounded confidence" do
      sig = strategy_for([102.0, 101.0, 103.0]).signal(symbol: "BIP-20DEC30-CDE")
      expect(sig[:confidence]).to be_between(0.0, 100.0)
    end
  end

  describe "backtest support surface" do
    it "declares its 5m warm-up for the preloading candle source" do
      strategy = described_class.new(anchor_period: 20, vol_period: 20)
      expect(strategy.warmup_candles).to eq({five_minute: 21})
    end

    it "defaults the candle source to the database (live path)" do
      expect(described_class.new.candle_source).to be_a(Signals::CandleSource::Database)
    end
  end
end
