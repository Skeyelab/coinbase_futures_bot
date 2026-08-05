require_relative "../lib/bucket_pricer"
require_relative "../lib/temp_market"

RSpec.describe BucketPricer do
  # The 2026-08-05 live example from the calibration report: KNYC, NBE 00Z,
  # txn=82 xnd=3, lead 24h -> model said B82.5=26.7c, T80=17.3c, T87=5.2c.
  # Matching the Python model here proves the Ruby port computes the same
  # distribution, not a plausible different one.
  def price(market)
    described_class.probability(
      market: market, txn: 82, xnd: 3, station: "KNYC", lead_hours: 24
    )
  end

  it "prices the modal bucket like the fitted Python model" do
    bucket = TempMarket.new(ticker: "KXHIGHNY-26AUG05-B82.5", kind: :between, floor: 82, cap: 83)
    expect(price(bucket)).to be_within(0.02).of(0.267)
  end

  it "prices the cold tail (cap-exclusive less market)" do
    cold = TempMarket.new(ticker: "KXHIGHNY-26AUG05-T80", kind: :less, floor: nil, cap: 80)
    expect(price(cold)).to be_within(0.02).of(0.173)
  end

  it "prices the warm tail (floor-exclusive greater market)" do
    warm = TempMarket.new(ticker: "KXHIGHNY-26AUG05-T87", kind: :greater, floor: 87, cap: nil)
    expect(price(warm)).to be_within(0.02).of(0.052)
  end

  it "sums a full ladder to one" do
    ladder = [
      TempMarket.new(ticker: "T", kind: :less, floor: nil, cap: 80),
      TempMarket.new(ticker: "B1", kind: :between, floor: 80, cap: 81),
      TempMarket.new(ticker: "B2", kind: :between, floor: 82, cap: 83),
      TempMarket.new(ticker: "B3", kind: :between, floor: 84, cap: 85),
      TempMarket.new(ticker: "B4", kind: :between, floor: 86, cap: 87),
      TempMarket.new(ticker: "G", kind: :greater, floor: 87, cap: nil)
    ]
    expect(ladder.sum { |m| price(m) }).to be_within(0.001).of(1.0)
  end

  it "returns nil for a station or lead the fit does not cover" do
    bucket = TempMarket.new(ticker: "X", kind: :between, floor: 82, cap: 83)
    expect(described_class.probability(market: bucket, txn: 82, xnd: 3, station: "KLAX", lead_hours: 24)).to be_nil
    expect(described_class.probability(market: bucket, txn: 82, xnd: 3, station: "KNYC", lead_hours: 80)).to be_nil
  end
end
