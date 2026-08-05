require_relative "../lib/move_analysis"

# Builds a price series at a fixed cadence.
# `prices` are cents (0-100); samples are `interval` seconds apart.
def series(prices, interval: 10, start: 1_700_000_000)
  prices.each_with_index.map { |p, i| {at: start + (i * interval), mid: p.to_f} }
end

RSpec.describe MoveAnalysis do
  describe ".detect" do
    it "finds nothing in a series that never moves" do
      flat = series([50, 50, 50, 50, 50, 50])

      expect(described_class.detect(flat, threshold_cents: 5)).to be_empty
    end

    it "reports the size and direction of a move that clears the threshold" do
      ramp = series([30, 35, 40, 45, 50, 50, 50])

      moves = described_class.detect(ramp, threshold_cents: 5)

      expect(moves.size).to eq(1)
      expect(moves.first[:magnitude_cents]).to eq(20.0)
      expect(moves.first[:from_cents]).to eq(30.0)
      expect(moves.first[:to_cents]).to eq(50.0)
    end

    # The whole experiment turns on this. seconds_to_half is how long you had
    # to react before half the move was already priced in.
    it "times how long the move took to get half and nearly all of the way there" do
      ramp = series([30, 35, 40, 45, 50, 50, 50], interval: 10)

      move = described_class.detect(ramp, threshold_cents: 5).first

      expect(move[:seconds_to_half]).to eq(20)   # first sample at or past 40c
      expect(move[:seconds_to_ninety]).to eq(40) # first sample at or past 48c
      expect(move[:duration_seconds]).to eq(40)
    end

    it "gives a one-tick jump no reaction window at all" do
      jump = series([30, 50, 50, 50], interval: 10)

      move = described_class.detect(jump, threshold_cents: 5).first

      expect(move[:seconds_to_half]).to eq(10)
      expect(move[:seconds_to_ninety]).to eq(10)
    end

    it "counts a move that lands exactly on the threshold" do
      exact = series([30, 35, 35, 35])

      expect(described_class.detect(exact, threshold_cents: 5).size).to eq(1)
    end

    it "ignores a move one cent short of the threshold" do
      short = series([30, 34, 34, 34])

      expect(described_class.detect(short, threshold_cents: 5)).to be_empty
    end

    it "measures a sell-off the same way it measures a rally" do
      selloff = series([70, 65, 60, 55, 50, 50], interval: 10)

      move = described_class.detect(selloff, threshold_cents: 5).first

      expect(move[:magnitude_cents]).to eq(20.0)
      expect(move[:from_cents]).to eq(70.0)
      expect(move[:to_cents]).to eq(50.0)
      expect(move[:seconds_to_half]).to eq(20)
    end
  end
end
