# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::TrailingStop::Algorithm do
  let(:calculator) do
    Trading::TrailingStop::Calculator.new(
      open_price: 10_000.0,
      profit_percent: 1.0,
      t_stop_percent: 0.25,
      stop_percent: 2.0,
      direction: :long
    )
  end

  subject(:algorithm) { described_class.new(calculator: calculator) }

  it "starts with hard stop active" do
    expect(algorithm.profit_made).to be(false)
    expect(algorithm.effective_stop_price).to eq(calculator.stop_price)
  end

  it "returns hold until a stop is triggered" do
    expect(algorithm.tick(spot: 9900.0, sma: 9900.0)).to eq(:hold)
  end

  it "returns stop_loss before profit unlock" do
    expect(algorithm.tick(spot: 9799.0, sma: 9799.0)).to eq(:stop_loss)
  end

  it "unlocks trailing mode and can emit trailing_stop" do
    expect(algorithm.tick(spot: 10_200.0, sma: 10_200.0)).to eq(:hold)
    expect(algorithm.profit_made).to be(true)

    algorithm.tick(spot: 10_500.0, sma: 10_500.0)
    expect(algorithm.tick(spot: 10_450.0, sma: 10_450.0)).to eq(:trailing_stop)
  end

  it "can be restored from persisted state" do
    algorithm.tick(spot: 10_300.0, sma: 10_300.0)
    persisted = algorithm.to_h

    restored = described_class.new(calculator: calculator, **persisted)
    expect(restored.market_extreme).to eq(algorithm.market_extreme)
    expect(restored.trailing_stop_price).to eq(algorithm.trailing_stop_price)
    expect(restored.profit_made).to eq(algorithm.profit_made)
  end
end
