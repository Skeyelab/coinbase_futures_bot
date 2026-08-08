require_relative "../lib/storm_scan"

RSpec.describe StormScan do
  def row(ticker:, floor:, bid: 0.30, ask: 0.35, size: 50)
    {"ticker" => ticker, "strike_type" => "greater",
     "floor_strike" => floor, "cap_strike" => nil,
     "yes_bid_dollars" => bid.to_s, "yes_ask_dollars" => ask.to_s,
     "yes_bid_size_fp" => size.to_s}
  end

  def scan_with(count:, rows:)
    source = double("source", observe!: nil, count: count)
    client = double("client", series_markets: rows)
    described_class.new(source: source, client: client)
  end

  it "buys a season total the count has already confirmed" do
    # 18 named storms already; "more than 17" is settled YES and still offers
    # at 35c. The season count cannot fall, so this is arithmetic.
    scan = scan_with(count: 18, rows: [row(ticker: "KXNAMEDSTORM-26DEC01EPACTOT-17", floor: 17)])

    result = scan.run.first
    expect(result.basin).to eq("EPAC")
    expect(result.observed_count).to eq(18)
    opportunity = result.opportunities.first
    expect(opportunity[:side]).to eq(:buy)
    expect(opportunity[:price_cents]).to eq(35)
  end

  it "leaves a threshold the season has not reached alone" do
    scan = scan_with(count: 12, rows: [row(ticker: "KXNAMEDSTORM-26DEC01EPACTOT-17", floor: 17)])

    expect(scan.run.first.opportunities).to be_empty
  end

  it "groups by basin, which only the ticker carries" do
    rows = [row(ticker: "KXNAMEDSTORM-26DEC01EPACTOT-17", floor: 17),
      row(ticker: "KXNAMEDSTORM-26DEC01ATLTOT-9", floor: 9)]
    scan = scan_with(count: 18, rows: rows)

    basins = scan.run.map(&:basin)
    expect(basins).to include("EPAC", "ATL")
  end

  it "reports NHC as a verified source with no corroboration claim" do
    scan = scan_with(count: 18, rows: [row(ticker: "KXNAMEDSTORM-26DEC01EPACTOT-17", floor: 17)])

    opportunity = scan.run.first.opportunities.first
    expect(opportunity[:verified]).to be true
    expect(opportunity[:peak_support]).to eq(1)
  end

  it "reports a failure as an error class, never a message" do
    client = double("client")
    allow(client).to receive(:series_markets).and_raise(RuntimeError, "secret-bearing text")
    scan = described_class.new(source: double("source", observe!: nil, count: 0), client: client)

    result = scan.run.first
    expect(result.error).to eq("RuntimeError")
    expect(result.opportunities).to eq([])
  end
end
