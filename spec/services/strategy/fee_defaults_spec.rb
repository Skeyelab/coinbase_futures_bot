# frozen_string_literal: true

require "rails_helper"

# Drift audit finding: strategies gated TP on 5 bps maker while fills, the
# backtest, and the daily gate all charge 15 bps taker — manufacturing trades
# the scorecard says can't win. Break-even must be priced at taker costs.
RSpec.describe "Strategy fee defaults", type: :service do
  it "MultiTimeframeSignal prices break-even at taker costs by default" do
    config = Strategy::MultiTimeframeSignal.new.instance_variable_get(:@config)
    expect(config[:fee_rate]).to eq(CostModel.taker_fee_rate)
  end

  it "honors the legacy maker_fee override key" do
    config = Strategy::MultiTimeframeSignal.new(maker_fee: 0.0005).instance_variable_get(:@config)
    expect(config[:fee_rate]).to eq(0.0005)
  end
end
