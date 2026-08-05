# frozen_string_literal: true

require "rails_helper"

RSpec.describe Signals::Indicators, ".atr" do
  # Matches the n8n Market Data Populator exactly: Wilder's TRUE RANGE, then a
  # SIMPLE MEAN of the last `period` ranges -- not Wilder's smoothing. The live
  # rule is measured against that number, so a textbook Wilder EMA here would
  # quietly compare the backtest to a rule nobody is running.
  def bar(high, low, close)
    {high: high, low: low, close: close}
  end

  it "measures a single true range as the bar's own span when there is no gap" do
    # prev close 10 sits inside [10, 12], so high-low is the widest of the three.
    candles = [bar(10, 10, 10), bar(12, 10, 11)]

    expect(described_class.atr(candles, 1)).to be_within(1e-9).of(2.0)
  end

  it "counts a gap up from the previous close, not just the bar's own span" do
    # Bar spans [30, 32] but the previous close was 10, so the real exposure is
    # 32 - 10 = 22. Ignoring the gap would report 2.
    candles = [bar(10, 10, 10), bar(32, 30, 31)]

    expect(described_class.atr(candles, 1)).to be_within(1e-9).of(22.0)
  end

  it "counts a gap down the same way" do
    candles = [bar(50, 50, 50), bar(32, 30, 31)]

    expect(described_class.atr(candles, 1)).to be_within(1e-9).of(20.0)
  end

  it "averages only the last `period` ranges, not the whole series" do
    # Ranges: 10, 1, 1. With period 2 the early spike must fall outside.
    candles = [bar(10, 10, 10), bar(20, 10, 20), bar(21, 20, 21), bar(22, 21, 22)]

    expect(described_class.atr(candles, 2)).to be_within(1e-9).of(1.0)
    expect(described_class.atr(candles, 3)).to be_within(1e-9).of(4.0)
  end

  it "uses every range it has when asked for more than exist" do
    candles = [bar(10, 10, 10), bar(12, 10, 11), bar(14, 12, 13)]

    # Ranges are 2 and 3; a period of 14 must average those two, not return nil.
    expect(described_class.atr(candles, 14)).to be_within(1e-9).of(2.5)
  end

  it "has no answer from a single bar" do
    expect(described_class.atr([bar(10, 10, 10)], 14)).to be_nil
    expect(described_class.atr([], 14)).to be_nil
    expect(described_class.atr(nil, 14)).to be_nil
  end

  it "refuses a non-positive period rather than guessing" do
    candles = [bar(10, 10, 10), bar(12, 10, 11)]

    expect(described_class.atr(candles, 0)).to be_nil
    expect(described_class.atr(candles, -1)).to be_nil
  end

  # Parity anchor. The live n8n populator reported atr=1.29857142857143 for
  # NOL-19AUG26-CDE on ONE_HOUR/period 14 at 2026-08-04T18:05Z. That is a simple
  # mean, so the 14 ranges must sum to 14x that value. This pins the convention:
  # if someone swaps in Wilder smoothing, this fails.
  it "reproduces a simple mean, matching the live populator's convention" do
    tr = 1.29857142857143
    total = tr * 14
    # 13 ranges of exactly `tr`, one carrying the rounding remainder.
    ranges = Array.new(13, tr) + [total - (tr * 13)]

    close = 100.0
    candles = [bar(close, close, close)]
    ranges.each do |r|
      candles << bar(close + r, close, close)
      close += 0
    end

    expect(described_class.atr(candles, 14)).to be_within(1e-9).of(tr)
  end
end
