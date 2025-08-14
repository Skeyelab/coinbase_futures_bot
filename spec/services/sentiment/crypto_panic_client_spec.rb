require "rails_helper"

RSpec.describe Sentiment::CryptoPanicClient, type: :service do
  it "maps currencies to symbols and normalizes items" do
    client = described_class.new(token: "x")
    item = {
      "title" => "BTC rallies on ETF news",
      "url" => "https://example.com/etf",
      "published_at" => Time.now.utc.iso8601,
      "votes" => { "important" => 5 },
      "currencies" => [ { "code" => "BTC" } ],
      "id" => 123,
      "kind" => "news"
    }

    results = client.send(:normalize_item, item)
    expect(results.size).to eq(1)
    r = results.first
    expect(r[:symbol]).to eq("BTC-USD-PERP")
    expect(r[:source]).to eq("cryptopanic")
    expect(r[:url]).to eq("https://example.com/etf")
    expect(r[:title]).to include("ETF")
    expect(r[:published_at]).to be_a(Time)
    expect(r[:raw_text_hash]).to be_present
  end
end