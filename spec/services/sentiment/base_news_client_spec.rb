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
    end
  end

  subject(:client) { client_class.new }

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
