# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sentiment::GenericRssClient, type: :service do
  def item_for(title, description)
    rss = <<~XML
      <rss><channel><item>
        <title>#{title}</title>
        <link>https://example.com/a</link>
        <pubDate>Mon, 11 Aug 2025 12:00:00 GMT</pubDate>
        <description>#{description}</description>
      </item></channel></rss>
    XML
    REXML::Document.new(rss).elements["rss/channel/item"]
  end

  subject(:client) { described_class.new(url: "https://oilprice.com/rss/main", source_name: "oilprice_rss") }

  it "reports its configured source name" do
    expect(client.source_name).to eq("oilprice_rss")
  end

  it "is always enabled (RSS needs no token)" do
    expect(client).to be_enabled
  end

  it "normalizes an oil article to an OIL-USD event" do
    item = item_for("OPEC output cut lifts crude", "WTI and Brent climb after the decision")

    results = client.send(:normalize_rss_item, item)

    expect(results.map { |r| r[:symbol] }).to include("OIL-USD")
    expect(results.first[:source]).to eq("oilprice_rss")
  end
end
