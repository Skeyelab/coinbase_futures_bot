require_relative "../lib/truth_scan"

RSpec.describe TruthScan do
  def market_row(ticker:, bid: 0.12, ask: 0.14)
    {"ticker" => ticker, "strike_type" => "between",
     "floor_strike" => 100, "cap_strike" => 119,
     "yes_bid_dollars" => bid.to_s, "yes_ask_dollars" => ask.to_s,
     "yes_bid_size_fp" => "40"}
  end

  def fake_source(count)
    ids = (1..count).map { |i| 9000 + i }
    double("source", ids_since: {ids: ids, boundary: 9000})
  end

  def fake_client(rows)
    double("client", series_markets: rows)
  end

  it "counts the week and flags a refuted bucket the book still bids" do
    # 126 posts: the 100-119 bucket is refuted (count already above cap) and
    # someone still bids 12c for YES on it.
    scan = described_class.new(
      source: fake_source(126),
      client: fake_client([market_row(ticker: "KXTRUTHSOCIAL-26AUG08-B109")]),
      week_start: "2026-08-02 00:00:00"
    )

    results = scan.run
    expect(results.size).to eq(1)
    result = results.first
    expect(result.observed_count).to eq(126)
    expect(result.markets).to eq(1)
    expect(result.opportunities.size).to eq(1)
    opportunity = result.opportunities.first
    expect(opportunity[:side]).to eq(:sell)
    expect(opportunity[:ticker]).to eq("KXTRUTHSOCIAL-26AUG08-B109")
  end

  it "finds nothing when the count settles no bucket" do
    scan = described_class.new(
      source: fake_source(50),
      client: fake_client([market_row(ticker: "KXTRUTHSOCIAL-26AUG08-B109")]),
      week_start: "2026-08-02 00:00:00"
    )

    expect(scan.run.first.opportunities).to be_empty
  end

  it "carries the book's own price so credibility can doubt us" do
    scan = described_class.new(
      source: fake_source(126),
      client: fake_client([market_row(ticker: "KXTRUTHSOCIAL-26AUG08-B109", bid: 0.78, ask: 0.80)]),
      week_start: "2026-08-02 00:00:00"
    )

    opportunity = scan.run.first.opportunities.first
    expect(opportunity[:market_pct]).to eq(78)
  end

  it "reuses the counted week within the cache window instead of re-paging Roll Call" do
    source = fake_source(126)
    scan = described_class.new(
      source: source,
      client: fake_client([market_row(ticker: "KXTRUTHSOCIAL-26AUG08-B109")]),
      week_start: "2026-08-02 00:00:00",
      count_ttl: 3600,
      clock: -> { @now || 1000 }
    )

    scan.run
    @now = 1500
    scan.run
    expect(source).to have_received(:ids_since).once

    @now = 1000 + 3601
    scan.run
    expect(source).to have_received(:ids_since).twice
  end

  it "reports a failed count as an error, not as zero posts" do
    source = double("source", ids_since: nil)
    scan = described_class.new(
      source: source,
      client: fake_client([]),
      week_start: "2026-08-02 00:00:00"
    )

    result = scan.run.first
    expect(result.error).to match(/boundary/)
    expect(result.opportunities).to eq([])
  end
end
