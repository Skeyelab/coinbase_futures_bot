# frozen_string_literal: true

require "rails_helper"

# Drift audit finding: strategies gated TP on 5 bps maker while fills, the
# backtest, and the daily gate all charge taker — manufacturing trades the
# scorecard says can't win. Break-even must be priced at taker costs.
#
# Issue #459 extends that: the correct taker cost depends on the VENUE. The rate
# used to be resolved at construction, before the traded symbol was known, so
# every symbol was priced at the global perp rate — while oil trades dated NOL
# at 9 bps with a $0.85/contract floor. That put the TP floor below true
# break-even on the only asset being traded.
RSpec.describe "Strategy fee defaults", type: :service do
  # fee resolution is a pure function of (config, traded symbol); exercising it
  # directly avoids staging a full multi-timeframe signal just to read a rate.
  def rate_for(symbol, **config)
    strategy = Strategy::MultiTimeframeSignal.new(config)
    strategy.instance_variable_set(:@current_symbol, symbol)
    strategy.send(:effective_fee_rate)
  end

  it "prices a dated contract at the dated schedule, not the perp rate" do
    rate = rate_for("NOL-19AUG26-CDE", contract_size_usd: 930.0)

    expect(rate).to be >= CostModel.dated_taker_rate
    expect(rate).to be > CostModel.taker_fee_rate
  end

  it "prices a perp at the perp taker rate" do
    FundingRate.create!(product_id: "BIP-PERP-TEST", funding_time: 1.hour.ago,
      funding_rate: 0.000014, funding_interval_seconds: 3600, observed_at: 1.hour.ago)

    rate = rate_for("BIP-PERP-TEST", contract_size_usd: 10_000.0)

    expect(rate).to be_within(1e-9).of(CostModel.taker_fee_rate)
  end

  # The floor is the dominant cost on a small-notional contract, and
  # break_even_exit reasons in prices — so if it is not folded in as a rate it
  # is simply ignored, and the TP floor lands below true break-even.
  it "folds the per-contract floor into the rate on small-notional contracts" do
    rate = rate_for("NOL-19AUG26-CDE", contract_size_usd: 100.0)

    expect(rate).to be_within(1e-9).of(CostModel.dated_fee_per_contract / 100.0)
    expect(rate).to be > CostModel.dated_taker_rate
  end

  it "honors an explicit fee_rate over the venue model" do
    expect(rate_for("NOL-19AUG26-CDE", fee_rate: 0.002, contract_size_usd: 100.0))
      .to eq(0.002)
  end

  it "honors the legacy maker_fee override key" do
    expect(rate_for("NOL-19AUG26-CDE", maker_fee: 0.0005, contract_size_usd: 100.0))
      .to eq(0.0005)
  end
end
