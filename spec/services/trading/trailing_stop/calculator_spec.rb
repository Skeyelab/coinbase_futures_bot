# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trading::TrailingStop::Calculator do
  describe "long direction" do
    subject(:calculator) do
      described_class.new(
        open_price: 10_000.0,
        profit_percent: 1.0,
        t_stop_percent: 0.25,
        stop_percent: 2.0,
        direction: :long
      )
    end

    it "computes long stop and profit targets" do
      expect(calculator.stop_price).to eq(9800.0)
      expect(calculator.profit_goal_price).to eq(10_100.0)
      expect(calculator.initial_t_stop_price).to eq(10_074.75)
    end

    it "moves trailing stop with higher highs" do
      expect(calculator.t_stop_price_for(10_500.0)).to eq(10_473.75)
    end

    it "uses long trigger semantics" do
      expect(calculator.profit_goal_reached?(10_100.0)).to be(true)
      expect(calculator.stop_loss_triggered?(9790.0, 9800.0)).to be(true)
      expect(calculator.stop_loss_triggered?(9800.0, 9800.0)).to be(true)
    end
  end

  describe "short direction" do
    subject(:calculator) do
      described_class.new(
        open_price: 10_000.0,
        profit_percent: 1.0,
        t_stop_percent: 0.25,
        stop_percent: 2.0,
        direction: :short
      )
    end

    it "computes short stop and profit targets" do
      expect(calculator.stop_price).to eq(10_200.0)
      expect(calculator.profit_goal_price).to eq(9900.0)
      expect(calculator.initial_t_stop_price).to eq(9924.75)
    end

    it "moves trailing stop with lower lows" do
      expect(calculator.t_stop_price_for(9500.0)).to eq(9523.75)
    end

    it "uses short trigger semantics" do
      expect(calculator.profit_goal_reached?(9890.0)).to be(true)
      expect(calculator.stop_loss_triggered?(10_250.0, 10_200.0)).to be(true)
      expect(calculator.stop_loss_triggered?(10_200.0, 10_200.0)).to be(true)
    end
  end
end
