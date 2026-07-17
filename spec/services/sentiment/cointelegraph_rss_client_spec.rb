# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sentiment::CointelegraphRssClient, type: :service do
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

  it "emits a distinct raw_text_hash per symbol for a multi-symbol article" do
    client = described_class.new
    item = item_for("Bitcoin and crude oil both rally", "BTC and WTI crude climb together")

    results = client.send(:normalize_rss_item, item)

    expect(results.map { |r| r[:symbol] }).to include("BTC-USD", "OIL-USD")
    hashes = results.map { |r| r[:raw_text_hash] }
    expect(hashes.uniq.size).to eq(hashes.size)
  end
end
