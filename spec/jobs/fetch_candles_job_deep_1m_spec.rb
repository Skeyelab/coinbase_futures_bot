# frozen_string_literal: true

require "rails_helper"

# Issue #506: the 3-day rolling 1m window meant a newly ingested contract never
# accrued usable 1m history, and every other timeframe looked healthy while it
# happened. These examples pin the one-time deep backfill that fixes it.
RSpec.describe FetchCandlesJob, "deep 1m backfill (issue #506)", type: :job do
  # Anything reaching further back than the rolling window is a deep call. Using
  # the constant rather than a literal keeps this honest if the window changes.
  def deep_calls
    @chunked_calls.select { |kw| kw[:start_time] < (described_class::DEFAULT_MAX_1M_BACKFILL_DAYS + 1).days.ago }
  end

  def contract(product_id, deep_at: nil, enabled: true)
    Contract.find_or_create_by(product_id: product_id) do |c|
      c.base_currency = "BTC"
      c.quote_currency = "USD"
      c.status = "active"
      c.expiration_date = Date.current + 60
    end.tap { |c| c.update!(enabled: enabled, deep_1m_backfilled_at: deep_at) }
  end

  let(:rest) { instance_double(MarketData::CoinbaseRest) }

  before do
    @chunked_calls = []
    allow(MarketData::CoinbaseRest).to receive(:new).and_return(rest)
    %i[upsert_products upsert_1m_candles upsert_5m_candles upsert_15m_candles
      upsert_30m_candles upsert_1h_candles upsert_1d_candles
      upsert_5m_candles_chunked upsert_15m_candles_chunked
      upsert_1h_candles_chunked].each { |m| allow(rest).to receive(m) }
    allow(rest).to receive(:upsert_1m_candles_chunked) { |**kw| @chunked_calls << kw }
    allow(Rails.logger).to receive(:info)
    # Other contracts in the test DB would otherwise consume the per-run budget.
    Contract.update_all(enabled: false)
  end

  it "reaches past the rolling window for a contract that has never had one" do
    target = contract("BIT-30OCT26-CDE")

    described_class.new.perform(symbols: [target.product_id])

    expect(deep_calls).not_to be_empty,
      "expected a 1m fetch starting further back than the " \
      "#{described_class::DEFAULT_MAX_1M_BACKFILL_DAYS}-day rolling window"
    expect(deep_calls.first[:product_id]).to eq(target.product_id)
    expect(deep_calls.first[:start_time])
      .to be_within(1.hour).of(described_class::DEEP_1M_BACKFILL_DAYS.days.ago)
  end

  it "stamps the contract so the deep walk never repeats" do
    target = contract("BIT-30OCT26-CDE")

    expect { described_class.new.perform(symbols: [target.product_id]) }
      .to change { target.reload.deep_1m_backfilled_at }.from(nil)
  end

  it "skips a contract that has already been deep-backfilled" do
    stamped_at = 2.days.ago
    target = contract("BIT-30OCT26-CDE", deep_at: stamped_at)

    described_class.new.perform(symbols: [target.product_id])

    expect(deep_calls).to be_empty
    expect(target.reload.deep_1m_backfilled_at).to be_within(1.minute).of(stamped_at)
  end

  it "leaves the contract pending when the deep fetch fails, so it retries" do
    target = contract("BIT-30OCT26-CDE")
    allow(rest).to receive(:upsert_1m_candles_chunked) do |**kw|
      @chunked_calls << kw
      raise StandardError, "venue down" if kw[:start_time] < 4.days.ago
    end
    allow(Sentry).to receive(:capture_exception)
    allow(Rails.logger).to receive(:error)

    described_class.new.perform(symbols: [target.product_id])

    expect(deep_calls).not_to be_empty
    expect(target.reload.deep_1m_backfilled_at).to be_nil
    expect(Sentry).to have_received(:capture_exception)
  end

  it "rate-limits how many contracts it drains per run" do
    %w[BIT-30OCT26-CDE ET-30OCT26-CDE NOL-19OCT26-CDE].each { |p| contract(p) }

    described_class.new.perform

    expect(Contract.enabled.where.not(deep_1m_backfilled_at: nil).count)
      .to eq(described_class::DEEP_1M_BACKFILL_PER_RUN)
  end

  it "ignores disabled contracts" do
    target = contract("BIT-30OCT26-CDE", enabled: false)

    described_class.new.perform

    expect(deep_calls).to be_empty
    expect(target.reload.deep_1m_backfilled_at).to be_nil
  end

  describe "drain order (found by running the fix on exo-mini)" do
    def candles!(product_id, count, oldest_ago)
      base = oldest_ago
      count.times do |i|
        Candle.find_or_create_by!(symbol: product_id, timeframe: "1m", timestamp: base + i.minutes) do |c|
          c.open = 1
          c.high = 1
          c.low = 1
          c.close = 1
          c.volume = 1
        end
      end
    end

    it "serves the neediest contract first, not the oldest row" do
      # `healthy` is created FIRST, so ordering by id would serve it first --
      # but `starved` is the one that cannot emit a signal.
      healthy = contract("BIT-31JUL26-CDE")
      starved = contract("BIT-30OCT26-CDE")
      candles!(healthy.product_id, 40, 10.days.ago)
      candles!(starved.product_id, 2, 1.hour.ago)

      described_class.new.perform

      expect(deep_calls.map { |kw| kw[:product_id] }).to eq([starved.product_id])
    end

    it "records depth a contract already has instead of re-walking it" do
      already_deep = contract("BIP-20DEC30-CDE")
      candles!(already_deep.product_id, 3, (described_class::DEEP_1M_BACKFILL_DAYS + 5).days.ago)

      described_class.new.perform

      expect(already_deep.reload.deep_1m_backfilled_at).not_to be_nil
      expect(deep_calls.map { |kw| kw[:product_id] }).not_to include(already_deep.product_id)
    end

    it "still deep-fetches a contract whose history is only recent" do
      shallow = contract("BIT-30OCT26-CDE")
      candles!(shallow.product_id, 5, 2.days.ago)

      described_class.new.perform

      expect(deep_calls.map { |kw| kw[:product_id] }).to eq([shallow.product_id])
      expect(shallow.reload.deep_1m_backfilled_at).not_to be_nil
    end
  end
end
