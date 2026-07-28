# frozen_string_literal: true

require "rails_helper"

# Two thirds of ingested articles (136 of 195 in 24h) tagged to NO symbol, so
# the sentiment pipeline was discarding most of what it fetched and reporting
# "undersampled" as a result. These are real headlines that matched nothing.
RSpec.describe Sentiment::SourceConfig, "router recall" do
  let(:keywords) { described_class.default.symbol_keywords }

  def symbols_for(headline)
    keywords.filter_map { |symbol, re| symbol if headline.match?(re) }
  end

  # Observed unmatched on exo-mini, 2026-07-28.
  {
    "Live updates: Crypto climbs off worst levels as stock selloff is contained" => %w[BTC-USD ETH-USD],
    "PayPal expands stablecoin push as crypto assets factor into Q2 results" => %w[BTC-USD ETH-USD],
    "1inch moves to unite DeFi liquidity across 13 chains with Aqua" => %w[BTC-USD ETH-USD],
    "Ondo drops tokenized asset blockchain plans for private trading network" => %w[BTC-USD ETH-USD],
    "Galaxy, MARA Holdings deepen Texas expansion with land acquisitions" => %w[BTC-USD],
    "North America Enters Rig Addition Streak" => %w[OIL-USD]
  }.each do |headline, expected|
    it "routes #{headline[0, 46]}... to #{expected.join(", ")}" do
      expect(symbols_for(headline)).to include(*expected)
    end
  end

  it "still routes headlines that name the asset outright" do
    expect(symbols_for("Bitcoin rallies past resistance")).to include("BTC-USD")
    expect(symbols_for("Ethereum upgrade ships")).to include("ETH-USD")
    expect(symbols_for("OPEC signals a crude supply cut")).to include("OIL-USD")
  end

  # The recall gain must not start tagging politics or unrelated commodities.
  it "leaves genuinely off-topic headlines unmatched" do
    [
      "Lil Wayne Praises Trump for Building White House Ballroom",
      "Trump blasts Jon Ossoff in Georgia speech",
      "New Solar Cell Design Solves A Problem That's Plagued Panels for Decades"
    ].each { |h| expect(symbols_for(h)).to be_empty, "expected no match for #{h.inspect}" }
  end

  it "does not leak crypto terms into oil" do
    expect(symbols_for("Crypto climbs off worst levels")).not_to include("OIL-USD")
  end
end

RSpec.describe Sentiment::BaseNewsClient, ".normalized_hash_input" do
  # Both were ingested as separate events, inflating the inflow rate that
  # decides whether sentiment is "undersampled".
  it "collapses a republish that differs only in capitalisation" do
    a = described_class.normalized_hash_input("http://x/1",
      "Galaxy, MARA Holdings deepen Texas expansion with land acquisitions", "BTC-USD")
    b = described_class.normalized_hash_input("http://x/1",
      "Galaxy, MARA Holdings deepen Texas expansion with land Acquisitions", "BTC-USD")

    expect(a).to eq(b)
  end

  it "collapses re-wrapped whitespace" do
    expect(described_class.normalized_hash_input("http://x/1", "Bitcoin  rallies\n past", nil))
      .to eq(described_class.normalized_hash_input("http://x/1", "Bitcoin rallies past", nil))
  end

  it "still separates genuinely different stories" do
    expect(described_class.normalized_hash_input("http://x/1", "Bitcoin rallies", nil))
      .not_to eq(described_class.normalized_hash_input("http://x/2", "Bitcoin falls", nil))
  end
end
