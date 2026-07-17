# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sentiment::BaseNewsClient do
  # Exercise the protected tagging/hashing helpers the way a concrete news
  # client subclass consumes them.
  let(:client_class) do
    Class.new(described_class) do
      def enabled? = true

      def source_name = "test"

      def symbols_in(text) = extract_crypto_symbols(text)

      def hash_for(url, title, symbol = nil) = generate_content_hash(url, title, symbol)

      def parsed_at(str) = parse_timestamp(str)
    end
  end

  subject(:client) { client_class.new }

  describe "#parse_timestamp" do
    it "treats a timezone-less feed date as UTC, regardless of the server's local timezone" do
      # The bug: Time.parse reads a TZ-less string in the SERVER local zone, so on
      # a non-UTC machine (e.g. Eastern) news gets shifted hours into the future and
      # never lands in AggregateSentimentJob's UTC windows.
      ClimateControl.modify(TZ: "America/New_York") do
        expect(client.parsed_at("2026-07-17 19:42:48")).to eq(Time.utc(2026, 7, 17, 19, 42, 48))
      end
    end

    it "honors an explicit timezone offset in the feed date" do
      expect(client.parsed_at("2026-07-17 19:42:48 -0400")).to eq(Time.utc(2026, 7, 17, 23, 42, 48))
    end

    it "falls back to the current time for an unparseable date" do
      expect(client.parsed_at("not a date")).to be_within(5).of(Time.now.utc)
    end
  end

  describe "#extract_crypto_symbols" do
    it "tags oil articles with OIL-USD" do
      expect(client.symbols_in("OPEC output cut lifts crude oil prices")).to include("OIL-USD")
    end

    it "still tags bitcoin articles" do
      expect(client.symbols_in("Bitcoin rallies to new high")).to include("BTC-USD")
    end
  end

  describe "#generate_content_hash" do
    it "differs per symbol so a multi-symbol article does not collide on upsert" do
      btc = client.hash_for("http://x", "title", "BTC-USD")
      oil = client.hash_for("http://x", "title", "OIL-USD")
      expect(btc).not_to eq(oil)
    end

    it "is stable for the same url, title, and symbol" do
      a = client.hash_for("http://x", "title", "BTC-USD")
      b = client.hash_for("http://x", "title", "BTC-USD")
      expect(a).to eq(b)
    end
  end
end
