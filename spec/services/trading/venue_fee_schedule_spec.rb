# frozen_string_literal: true

require "rails_helper"

# Issue #585. The rate was available from the venue the whole time.
#
# freqtrade's `fee` option says it "should normally not be configured, which has
# freqtrade fall back to the exchange default fee" — the default path is to ask
# the exchange. We hardcoded "0.0003" and ran twelve backtests on it, while
# /transaction_summary would have answered 0.0008 on request.
#
# It also answers two things no constant can:
#   1. the tier is volume-based and MOVES (this account paid 2.0 bps on BIP in
#      Aug 2025 and 10.175 bps in Jul 2026, same instrument)
#   2. maker is 0.00075, not the 0% ADR 0002 assumed and our seeded default
#      still claims
RSpec.describe Trading::VenueFeeSchedule do
  # The real response, trimmed to the fields used.
  let(:payload) do
    {"fee_tier" => {
      "pricing_tier" => "Advanced 3", "usd_from" => "10000", "usd_to" => "50000",
      "taker_fee_rate" => "0.0008", "maker_fee_rate" => "0.00075"
    }}
  end

  let(:client) { instance_double(Trading::CoinbasePositions) }
  let(:logger) { instance_spy(Logger) }

  before { BotRuntimeStat.delete_all }

  def responding(body)
    allow(client).to receive(:transaction_summary).and_return(body["fee_tier"] || {})
  end

  describe ".fetch!" do
    # The tracer.
    it "reads the live schedule off the venue and persists it" do
      responding(payload)

      described_class.fetch!(client: client, logger: logger)

      current = described_class.current
      expect(current[:taker_rate]).to be_within(1e-9).of(0.0008)
      expect(current[:maker_rate]).to be_within(1e-9).of(0.00075)
      expect(current[:tier]).to eq("Advanced 3")
    end

    it "asks for the futures schedule, not the spot one" do
      responding(payload)

      described_class.fetch!(client: client, logger: logger)

      expect(client).to have_received(:transaction_summary).with(product_type: "FUTURE")
    end

    # A failed fetch must leave the last known schedule alone. Replacing a real
    # measurement with nothing because the network blipped is worse than stale.
    it "keeps the last known schedule when the venue cannot be reached" do
      responding(payload)
      described_class.fetch!(client: client, logger: logger)

      allow(client).to receive(:transaction_summary).and_raise(Faraday::ConnectionFailed, "boom")
      described_class.fetch!(client: client, logger: logger)

      expect(described_class.current[:taker_rate]).to be_within(1e-9).of(0.0008)
      expect(logger).to have_received(:warn).with(/venue fee schedule/i)
    end

    # A response missing the rates is not a schedule of zero. Asserting only
    # that `current` is nil would pass even if a zero row were written, because
    # `current` has its own positivity guard — the write has to be checked
    # directly or the two guards test each other.
    it "refuses a payload with no usable rates rather than storing zeros" do
      responding({"fee_tier" => {"pricing_tier" => "Advanced 3"}})

      described_class.fetch!(client: client, logger: logger)

      expect(BotRuntimeStat.find_by(key: described_class::STORE_KEY)).to be_nil
      expect(described_class.current).to be_nil
    end

    # And a rateless response must not overwrite a good schedule with junk.
    it "does not overwrite a known schedule with a rateless response" do
      responding(payload)
      described_class.fetch!(client: client, logger: logger)

      responding({"fee_tier" => {"pricing_tier" => "Advanced 3"}})
      described_class.fetch!(client: client, logger: logger)

      expect(described_class.current[:taker_rate]).to be_within(1e-9).of(0.0008)
    end
  end

  describe ".current" do
    # fetch! refuses to write a zero rate, so this guard is unreachable through
    # it — but a row can predate that guard or be written by hand, and reading a
    # zero back would price every trade at free. Worth holding on its own.
    it "treats a stored zero rate as no schedule at all" do
      BotRuntimeStat.create!(key: described_class::STORE_KEY, recorded_at: Time.current.utc,
        value: {"taker_rate" => 0.0, "maker_rate" => 0.0, "tier" => "Advanced 3"})

      expect(described_class.current).to be_nil
    end
  end

  describe "CostModel integration" do
    around do |example|
      originals = ENV.values_at("BACKTEST_TAKER_FEE_RATE", "TAKER_FEE_RATE",
        "BACKTEST_MAKER_FEE_RATE", "MAKER_FEE_RATE")
      %w[BACKTEST_TAKER_FEE_RATE TAKER_FEE_RATE BACKTEST_MAKER_FEE_RATE MAKER_FEE_RATE].each { |k| ENV.delete(k) }
      example.run
      %w[BACKTEST_TAKER_FEE_RATE TAKER_FEE_RATE BACKTEST_MAKER_FEE_RATE MAKER_FEE_RATE]
        .zip(originals) { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end

    it "prices at the venue's rate instead of the seeded constant" do
      responding(payload)
      described_class.fetch!(client: client, logger: logger)

      expect(CostModel.taker_fee_rate).to be_within(1e-9).of(0.0008)
    end

    # The one that mattered most. ADR 0002's "0% maker" justified the whole
    # maker-optimization case (#374/#377); the venue charges 7.5 bps.
    it "stops claiming maker fills are free" do
      responding(payload)
      described_class.fetch!(client: client, logger: logger)

      expect(CostModel.maker_fee_rate).to be_within(1e-9).of(0.00075)
      expect(CostModel.maker_fee_rate).to be > 0
    end

    # An operator pricing a hypothetical is a deliberate act and still wins.
    it "lets an explicit override beat the venue" do
      responding(payload)
      described_class.fetch!(client: client, logger: logger)
      ENV["BACKTEST_TAKER_FEE_RATE"] = "0.0002"

      expect(CostModel.taker_fee_rate).to be_within(1e-9).of(0.0002)
    end

    it "falls back to the seeded constant when the venue has never answered" do
      expect(CostModel.taker_fee_rate).to be_within(1e-9).of(0.0003)
    end

    # Falling back has to be visible. A wrong number nobody questions is exactly
    # how 3 bps survived long enough to price twelve backtests.
    it "reports where the rate came from" do
      expect(CostModel.fee_source).to eq(:seeded)

      responding(payload)
      described_class.fetch!(client: client, logger: logger)

      expect(CostModel.fee_source).to eq(:venue)

      ENV["TAKER_FEE_RATE"] = "0.0002"
      expect(CostModel.fee_source).to eq(:override)
    end
  end
end
