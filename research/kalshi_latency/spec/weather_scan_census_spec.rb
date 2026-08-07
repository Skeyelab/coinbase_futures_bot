require "date"
require_relative "../lib/weather_scan"

# The counterparty census (2026-08-06/07). Opportunity.find returns nil when
# nothing rests on the other side, so a bucket the arithmetic has KILLED but
# nobody bids on is invisible in the opportunity stream -- indistinguishable
# from a bucket that is still alive. Two days of zero opportunities turned out
# to be 12 dead buckets with zero bids, and finding that out took a hand-rolled
# census both times. The scan should say it itself.
RSpec.describe WeatherScan, "counterparty census" do
  def market_row(ticker:, floor:, cap:, bid:, bid_size: 50)
    {"ticker" => ticker, "strike_type" => "between",
     "floor_strike" => floor, "cap_strike" => cap,
     "yes_bid_dollars" => format("%.4f", bid / 100.0),
     "yes_ask_dollars" => format("%.4f", (bid + 1) / 100.0),
     "yes_bid_size_fp" => bid_size.to_s}
  end

  def scan_for(rows, high_f)
    observations = [{at: Time.utc(2026, 8, 7, 18, 0, 0), temp_f: high_f}]
    station = double("station", observations: observations)
    client = double("client", temp_markets: rows)
    described_class.new(client: client, now: Time.utc(2026, 8, 7, 20, 0, 0),
      station_source: ->(_city) { station })
  end

  it "counts a refuted bucket nobody bids on" do
    rows = [market_row(ticker: "KXHIGHNY-26AUG07-B79.5", floor: 79, cap: 80, bid: 0, bid_size: 0)]
    result = scan_for(rows, 85.0).run.find { |r| r.markets.positive? }

    expect(result.dead_buckets).to eq(1)
    expect(result.dead_with_bid).to eq(0)
  end

  it "counts a refuted bucket that still has a bid" do
    rows = [market_row(ticker: "KXHIGHNY-26AUG07-B79.5", floor: 79, cap: 80, bid: 3)]
    result = scan_for(rows, 85.0).run.find { |r| r.markets.positive? }

    expect(result.dead_buckets).to eq(1)
    expect(result.dead_with_bid).to eq(1)
  end

  it "does not count a bucket the day has not decided" do
    rows = [market_row(ticker: "KXHIGHNY-26AUG07-B89.5", floor: 89, cap: 90, bid: 40)]
    result = scan_for(rows, 85.0).run.find { |r| r.markets.positive? }

    expect(result.dead_buckets).to eq(0)
  end
end
