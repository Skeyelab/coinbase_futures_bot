require "rails_helper"

RSpec.describe Signals::Indicators do
  describe ".ema" do
    it "seeds with the SMA of the first `period` values (TA-Lib/TradingView convention)" do
      # period 5, k = 2/6 = 1/3, seed = SMA(1..5) = 3.0
      # 6 -> 4.0, 7 -> 5.0, 8 -> 6.0, 9 -> 7.0, 10 -> 8.0 (exact)
      values = (1..10).map(&:to_f)
      expect(described_class.ema(values, 5)).to be_within(1e-9).of(8.0)
    end

    it "equals the SMA when given exactly `period` values" do
      values = [10.0, 11.0, 12.0, 13.0]
      expect(described_class.ema(values, 4)).to be_within(1e-9).of(11.5)
    end

    it "returns the constant for a constant series" do
      expect(described_class.ema([42.0] * 30, 12)).to be_within(1e-9).of(42.0)
    end

    it "returns the last value for period 1" do
      expect(described_class.ema([100.0, 102.0, 101.0], 1)).to eq(101.0)
    end

    it "accepts BigDecimal and integer inputs" do
      values = [BigDecimal(1), BigDecimal(2), 3, 4, 5]
      expect(described_class.ema(values, 5)).to be_within(1e-9).of(3.0)
    end

    it "is deterministic: same input series produces the same output" do
      values = Array.new(50) { |i| 100.0 + Math.sin(i * 0.3) * 5 }
      expect(described_class.ema(values, 13)).to eq(described_class.ema(values, 13))
    end

    it "returns nil when there are fewer values than the period" do
      expect(described_class.ema([1.0, 2.0], 10)).to be_nil
    end

    it "returns nil for an empty series" do
      expect(described_class.ema([], 5)).to be_nil
    end

    it "returns nil for a non-positive period" do
      expect(described_class.ema([1.0, 2.0], 0)).to be_nil
      expect(described_class.ema([1.0, 2.0], -3)).to be_nil
    end
  end

  describe ".sma" do
    it "averages the last `period` values" do
      expect(described_class.sma([1.0, 2.0, 3.0, 4.0, 5.0], 3)).to be_within(1e-9).of(4.0)
    end

    it "averages the whole series when it is exactly `period` long" do
      expect(described_class.sma([2.0, 4.0, 6.0], 3)).to be_within(1e-9).of(4.0)
    end

    it "accepts BigDecimal inputs" do
      expect(described_class.sma([BigDecimal(2), BigDecimal(4)], 2)).to be_within(1e-9).of(3.0)
    end

    it "returns nil when there are fewer values than the period" do
      expect(described_class.sma([1.0], 2)).to be_nil
    end

    it "returns nil for a non-positive period" do
      expect(described_class.sma([1.0, 2.0], 0)).to be_nil
    end
  end
end
