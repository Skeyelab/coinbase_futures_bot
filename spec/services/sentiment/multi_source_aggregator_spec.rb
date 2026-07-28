# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sentiment::MultiSourceAggregator, type: :service do
  describe "#source_status" do
    subject(:names) { described_class.new.source_status.map { |s| s[:name] } }

    it "includes the crypto sources" do
      expect(names).to include("coindesk_rss", "cointelegraph_rss")
    end

    it "does not include cryptopanic (removed in #550 — dead API, zero events ever)" do
      expect(names).not_to include("cryptopanic")
    end

    it "includes an oil news source" do
      expect(names).to include("oilprice_rss")
    end

    it "includes the EIA inventory source" do
      expect(names).to include("eia_inventory")
    end
  end
end
